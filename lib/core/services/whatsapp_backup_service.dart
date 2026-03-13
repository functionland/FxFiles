import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/app_models.dart';
import 'package:fula_files/core/services/app_store_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';

/// Progress of an ongoing backup or restore operation.
class BackupProgress {
  final int completedFiles;
  final int totalFiles;
  final int completedBytes;
  final int totalBytes;
  final String? currentFile;

  const BackupProgress({
    this.completedFiles = 0,
    this.totalFiles = 0,
    this.completedBytes = 0,
    this.totalBytes = 0,
    this.currentFile,
  });

  double get fraction => totalFiles > 0 ? completedFiles / totalFiles : 0;
}

/// Result of an incremental scan.
class ScanResult {
  final List<_FileInfo> newFiles;
  final List<_FileInfo> changedFiles;
  final int unchangedCount;
  final int totalSize;

  ScanResult({
    required this.newFiles,
    required this.changedFiles,
    required this.unchangedCount,
    required this.totalSize,
  });

  int get filesToUpload => newFiles.length + changedFiles.length;
}

class _FileInfo {
  final String relativePath;
  final File file;
  final int size;
  final DateTime modified;
  final String hash;
  final BackupCategory category;

  _FileInfo({
    required this.relativePath,
    required this.file,
    required this.size,
    required this.modified,
    required this.hash,
    required this.category,
  });
}

class WhatsAppBackupService {
  WhatsAppBackupService._();
  static final WhatsAppBackupService instance = WhatsAppBackupService._();

  static const _uuid = Uuid();
  static const String _backupBucket = 'app-backups';
  static const int _largeFileThreshold = 100 * 1024 * 1024; // 100 MB
  static const int _hashChunkSize = 64 * 1024; // 64 KB for quick hash

  bool _backupBucketChecked = false;
  bool _backupBucketExists = false;
  bool _cancelled = false;

  // Manifest sync state
  bool _manifestSyncScheduled = false;
  static const Duration _manifestSyncDebounce = Duration(seconds: 5);

  final _progressController = StreamController<BackupProgress>.broadcast();
  Stream<BackupProgress> get progressStream => _progressController.stream;

  Future<void> init() async {
    // AppStoreService handles Hive init for all app models
    await AppStoreService.instance.init();
  }

  // ============================================================================
  // DIRECTORY DISCOVERY
  // ============================================================================

  /// Find the WhatsApp data directory for a given app definition.
  /// Returns null on iOS (caller must provide iosFolderPath) or if not found.
  Directory? findDataDirectory(AppDefinition app) {
    if (Platform.isIOS) return null;

    if (app.dataPathAndroid != null) {
      final dir = Directory(app.dataPathAndroid!);
      if (dir.existsSync()) return dir;
    }

    if (app.dataPathAndroidLegacy != null) {
      final dir = Directory(app.dataPathAndroidLegacy!);
      if (dir.existsSync()) return dir;
    }

    return null;
  }

  // ============================================================================
  // CATEGORY MAPPING
  // ============================================================================

  BackupCategory categorizeFile(String relativePath) {
    final lower = relativePath.toLowerCase();

    if (lower.startsWith('databases/')) return BackupCategory.messages;
    if (lower.startsWith('media/whatsapp images/')) return BackupCategory.images;
    if (lower.startsWith('media/whatsapp video/')) return BackupCategory.videos;
    if (lower.startsWith('media/whatsapp audio/')) return BackupCategory.audio;
    if (lower.startsWith('media/whatsapp voice notes/')) return BackupCategory.voiceNotes;
    if (lower.startsWith('media/whatsapp documents/')) return BackupCategory.documents;
    if (lower.startsWith('media/whatsapp stickers/') ||
        lower.startsWith('media/whatsapp animated gifs/')) {
      return BackupCategory.stickers;
    }

    return BackupCategory.other;
  }

  // ============================================================================
  // INCREMENTAL SCAN
  // ============================================================================

  /// Compute a quick hash: SHA-256(first 64KB + 8-byte big-endian fileSize).
  Future<String> _computeQuickHash(File file, int fileSize) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      final chunkSize = fileSize < _hashChunkSize ? fileSize : _hashChunkSize;
      final chunk = await raf.read(chunkSize);

      // Append file size as 8-byte big-endian
      final sizeBytes = ByteData(8)..setInt64(0, fileSize, Endian.big);
      final combined = Uint8List.fromList([...chunk, ...sizeBytes.buffer.asUint8List()]);

      return sha256.convert(combined).toString();
    } finally {
      await raf.close();
    }
  }

  /// Scan a directory for new/changed files compared to the file index.
  Future<ScanResult> scanForChanges(Directory dir) async {
    final newFiles = <_FileInfo>[];
    final changedFiles = <_FileInfo>[];
    var unchangedCount = 0;
    var totalSize = 0;

    final basePath = dir.path;
    final entities = dir.listSync(recursive: true, followLinks: false);

    for (final entity in entities) {
      if (entity is! File) continue;
      if (_cancelled) break;

      try {
        final stat = entity.statSync();
        final size = stat.size;
        final modified = stat.modified;
        final relativePath = entity.path.substring(basePath.length + 1);
        final hash = await _computeQuickHash(entity, size);
        final category = categorizeFile(relativePath);

        totalSize += size;

        final existing = AppStoreService.instance.getFileEntry(relativePath);
        if (existing == null) {
          newFiles.add(_FileInfo(
            relativePath: relativePath,
            file: entity,
            size: size,
            modified: modified,
            hash: hash,
            category: category,
          ));
        } else if (existing.contentHash != hash || existing.sizeBytes != size) {
          changedFiles.add(_FileInfo(
            relativePath: relativePath,
            file: entity,
            size: size,
            modified: modified,
            hash: hash,
            category: category,
          ));
        } else {
          unchangedCount++;
        }
      } catch (e) {
        debugPrint('WhatsAppBackup: scan error for ${entity.path}: $e');
      }
    }

    return ScanResult(
      newFiles: newFiles,
      changedFiles: changedFiles,
      unchangedCount: unchangedCount,
      totalSize: totalSize,
    );
  }

  // ============================================================================
  // BACKUP
  // ============================================================================

  /// Run a backup for the given appId.
  /// [password] if set, adds AES-256-GCM encryption on top of fula_client's.
  /// [overrideDir] used on iOS where user selects folder manually.
  Future<BackupRecord?> runBackup({
    String appId = 'whatsapp',
    String? password,
    Directory? overrideDir,
    void Function(BackupProgress)? onProgress,
  }) async {
    _cancelled = false;

    // Check network
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) {
      throw Exception('No network connection');
    }

    // Find data directory
    final appDef = AppStoreService.getAppDefinition(appId);
    if (appDef == null) throw Exception('Unknown app: $appId');

    final dir = overrideDir ?? findDataDirectory(appDef);
    if (dir == null || !dir.existsSync()) {
      throw Exception('WhatsApp data directory not found');
    }

    // Ensure bucket exists
    if (!await _ensureBackupBucketExists()) {
      throw Exception('Could not create backup storage');
    }

    // Derive encryption key if password set
    Uint8List? encKey;
    if (password != null) {
      encKey = await AppStoreService.instance.deriveEncryptionKey(appId, password);
      if (encKey == null) throw Exception('Invalid password');
    }

    // Scan for changes
    final record = await AppStoreService.instance.createBackupRecord(appId);
    record.status = BackupStatus.scanning;
    await AppStoreService.instance.updateBackupRecord(record);

    _reportProgress(onProgress, const BackupProgress());

    final scan = await scanForChanges(dir);
    if (_cancelled) {
      record.status = BackupStatus.cancelled;
      await AppStoreService.instance.updateBackupRecord(record);
      return record;
    }

    final filesToUpload = [...scan.newFiles, ...scan.changedFiles];
    if (filesToUpload.isEmpty) {
      record.status = BackupStatus.completed;
      record.completedAt = DateTime.now();
      record.newFileCount = 0;
      record.totalFileCount = scan.unchangedCount;
      record.totalSizeBytes = scan.totalSize;
      await AppStoreService.instance.updateBackupRecord(record);
      await AppStoreService.instance.updateLastBackupAt(appId, DateTime.now());
      return record;
    }

    // Upload
    record.status = BackupStatus.uploading;
    record.newFileCount = filesToUpload.length;
    record.totalFileCount = filesToUpload.length + scan.unchangedCount;
    record.totalSizeBytes = scan.totalSize;
    await AppStoreService.instance.updateBackupRecord(record);

    final categoryCounts = <String, int>{};
    var completedFiles = 0;
    var completedBytes = 0;

    // Sort: large files last (so small files go in parallel first)
    filesToUpload.sort((a, b) => a.size.compareTo(b.size));

    // Separate large and small files
    final largeFiles = filesToUpload.where((f) => f.size >= _largeFileThreshold).toList();
    final smallFiles = filesToUpload.where((f) => f.size < _largeFileThreshold).toList();

    final encryptionKey = await AuthService.instance.getEncryptionKey();

    // Upload small files with limited parallelism
    for (var i = 0; i < smallFiles.length && !_cancelled; i += 3) {
      final batch = smallFiles.skip(i).take(3).toList();
      await Future.wait(batch.map((fileInfo) async {
        if (_cancelled) return;
        try {
          await _uploadFile(fileInfo, record.id, appId, encKey, encryptionKey);
          completedFiles++;
          completedBytes += fileInfo.size;
          final catName = fileInfo.category.name;
          categoryCounts[catName] = (categoryCounts[catName] ?? 0) + 1;
          _reportProgress(onProgress, BackupProgress(
            completedFiles: completedFiles,
            totalFiles: filesToUpload.length,
            completedBytes: completedBytes,
            totalBytes: scan.totalSize,
            currentFile: fileInfo.relativePath,
          ));
        } catch (e) {
          debugPrint('WhatsAppBackup: upload error for ${fileInfo.relativePath}: $e');
        }
      }));
    }

    // Upload large files sequentially
    for (final fileInfo in largeFiles) {
      if (_cancelled) break;
      try {
        await _uploadFile(fileInfo, record.id, appId, encKey, encryptionKey);
        completedFiles++;
        completedBytes += fileInfo.size;
        final catName = fileInfo.category.name;
        categoryCounts[catName] = (categoryCounts[catName] ?? 0) + 1;
        _reportProgress(onProgress, BackupProgress(
          completedFiles: completedFiles,
          totalFiles: filesToUpload.length,
          completedBytes: completedBytes,
          totalBytes: scan.totalSize,
          currentFile: fileInfo.relativePath,
        ));
      } catch (e) {
        debugPrint('WhatsAppBackup: upload error for ${fileInfo.relativePath}: $e');
      }
    }

    // Finalize
    if (_cancelled) {
      record.status = BackupStatus.cancelled;
    } else {
      record.status = BackupStatus.completed;
      record.completedAt = DateTime.now();
    }
    record.categoryCounts = categoryCounts;
    await AppStoreService.instance.updateBackupRecord(record);
    await AppStoreService.instance.updateLastBackupAt(appId, DateTime.now());

    _scheduleManifestSync(appId);
    return record;
  }

  Future<void> _uploadFile(
    _FileInfo fileInfo,
    String backupId,
    String appId,
    Uint8List? passwordKey,
    Uint8List? encryptionKey,
  ) async {
    var data = await fileInfo.file.readAsBytes();

    // Password encryption layer
    if (passwordKey != null) {
      data = await AppStoreService.instance.encrypt(data, passwordKey);
    }

    // Remote key: .fula/apps/{appId}/files/{SHA-256 of relativePath}
    final pathHash = sha256.convert(utf8.encode(fileInfo.relativePath)).toString();
    final remoteKey = '.fula/apps/$appId/files/$pathHash';

    await FulaApiService.instance.encryptAndUploadLargeFile(
      _backupBucket,
      remoteKey,
      data,
      encryptionKey ?? Uint8List(32),
    );

    // Update file index
    final entry = BackupFileEntry(
      relativePath: fileInfo.relativePath,
      sizeBytes: fileInfo.size,
      modifiedAt: fileInfo.modified,
      contentHash: fileInfo.hash,
      backupId: backupId,
      remoteKey: remoteKey,
      category: fileInfo.category,
    );
    await AppStoreService.instance.putFileEntry(entry);
  }

  void cancelBackup() {
    _cancelled = true;
  }

  void _reportProgress(void Function(BackupProgress)? onProgress, BackupProgress progress) {
    _progressController.add(progress);
    onProgress?.call(progress);
  }

  // ============================================================================
  // RESTORE
  // ============================================================================

  /// Restore files from backup.
  /// [category] filters to a specific category; null = all.
  /// [specificPaths] overrides category filter with exact paths.
  Future<void> restoreFiles({
    String appId = 'whatsapp',
    BackupCategory? category,
    List<String>? specificPaths,
    String? password,
    Directory? restoreDir,
    void Function(BackupProgress)? onProgress,
  }) async {
    _cancelled = false;

    // Verify password if needed
    Uint8List? encKey;
    final app = AppStoreService.instance.getActivatedApp(appId);
    if (app != null && app.hasPassword) {
      if (password == null) throw Exception('Password required');
      final valid = await AppStoreService.instance.verifyAppPassword(appId, password);
      if (!valid) throw Exception('Incorrect password');
      encKey = await AppStoreService.instance.deriveEncryptionKey(appId, password);
    }

    final encryptionKey = await AuthService.instance.getEncryptionKey();

    // Determine files to restore
    var entries = AppStoreService.instance.getAllFileEntries();
    if (specificPaths != null) {
      entries = entries.where((e) => specificPaths.contains(e.relativePath)).toList();
    } else if (category != null) {
      entries = entries.where((e) => e.category == category).toList();
    }

    if (entries.isEmpty) throw Exception('No files to restore');

    // Determine restore directory
    final targetDir = restoreDir ?? _getDefaultRestoreDir(appId);
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }

    var completed = 0;
    var completedBytes = 0;
    final totalBytes = entries.fold<int>(0, (sum, e) => sum + e.sizeBytes);

    for (final entry in entries) {
      if (_cancelled) break;

      try {
        _reportProgress(onProgress, BackupProgress(
          completedFiles: completed,
          totalFiles: entries.length,
          completedBytes: completedBytes,
          totalBytes: totalBytes,
          currentFile: entry.relativePath,
        ));

        // Download from cloud
        var data = await FulaApiService.instance.downloadAndDecrypt(
          _backupBucket,
          entry.remoteKey,
          encryptionKey ?? Uint8List(32),
        );

        // Decrypt password layer
        if (encKey != null) {
          data = await AppStoreService.instance.decrypt(data, encKey);
        }

        // Write file to restore directory
        final targetFile = File('${targetDir.path}/${entry.relativePath}');
        await targetFile.parent.create(recursive: true);
        await targetFile.writeAsBytes(data);

        completed++;
        completedBytes += entry.sizeBytes;
      } catch (e) {
        debugPrint('WhatsAppBackup: restore error for ${entry.relativePath}: $e');
      }
    }

    _reportProgress(onProgress, BackupProgress(
      completedFiles: completed,
      totalFiles: entries.length,
      completedBytes: completedBytes,
      totalBytes: totalBytes,
    ));
  }

  Directory _getDefaultRestoreDir(String appId) {
    final appDef = AppStoreService.getAppDefinition(appId);
    if (Platform.isAndroid && appDef?.dataPathAndroid != null) {
      return Directory(appDef!.dataPathAndroid!);
    }
    // iOS / fallback: app documents directory
    return Directory('/tmp/fxfiles_restore/$appId');
  }

  void cancelRestore() {
    _cancelled = true;
  }

  // ============================================================================
  // BACKUP DELETION
  // ============================================================================

  Future<void> deleteBackup(String appId, String backupId) async {
    final entries = AppStoreService.instance.getFileEntriesForBackup(backupId);

    for (final entry in entries) {
      // Check if any other backup references this remote key
      final allEntries = AppStoreService.instance.getAllFileEntries();
      final otherRefs = allEntries.where(
        (e) => e.remoteKey == entry.remoteKey && e.backupId != backupId,
      );
      if (otherRefs.isEmpty) {
        try {
          await FulaApiService.instance.deleteObject(_backupBucket, entry.remoteKey);
        } catch (e) {
          debugPrint('WhatsAppBackup: delete error for ${entry.remoteKey}: $e');
        }
      }
    }

    await AppStoreService.instance.deleteBackupRecord(backupId);
    _scheduleManifestSync(appId);
  }

  // ============================================================================
  // MANIFEST SYNC
  // ============================================================================

  void _scheduleManifestSync(String appId) {
    if (_manifestSyncScheduled) return;
    _manifestSyncScheduled = true;

    Future.delayed(_manifestSyncDebounce, () async {
      _manifestSyncScheduled = false;
      await syncManifest(appId);
    });
  }

  Future<void> syncManifest(String appId) async {
    if (!FulaApiService.instance.isConfigured) return;
    if (!await _ensureBackupBucketExists()) return;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;

      final userId = await _getUserId();
      if (userId == null) return;

      final backups = AppStoreService.instance.getBackupHistory(appId)
          .map((r) => r.toJson())
          .toList();
      final fileIndex = <String, dynamic>{};
      for (final entry in AppStoreService.instance.getAllFileEntries()) {
        fileIndex[entry.relativePath] = entry.toJson();
      }

      final jsonStr = jsonEncode({
        'backups': backups,
        'fileIndex': fileIndex,
        'updatedAt': DateTime.now().toIso8601String(),
      });
      final data = Uint8List.fromList(utf8.encode(jsonStr));

      final key = '.fula/apps/$appId/manifests/$userId.json';
      await FulaApiService.instance.encryptAndUpload(
        _backupBucket,
        key,
        data,
        encryptionKey,
        contentType: 'application/json',
      );

      debugPrint('WhatsAppBackup: manifest synced for $appId');
    } catch (e) {
      debugPrint('WhatsAppBackup: syncManifest error: $e');
    }
  }

  Future<void> restoreManifest(String appId) async {
    if (!FulaApiService.instance.isConfigured) return;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;

      final userId = await _getUserId();
      if (userId == null) return;

      final key = '.fula/apps/$appId/manifests/$userId.json';
      final data = await FulaApiService.instance.downloadAndDecrypt(
        _backupBucket,
        key,
        encryptionKey,
      );

      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;

      // Restore backup records
      final backupsList = json['backups'] as List<dynamic>? ?? [];
      for (final bJson in backupsList) {
        final record = BackupRecord.fromJson(bJson as Map<String, dynamic>);
        await AppStoreService.instance.updateBackupRecord(record);
      }

      // Restore file index
      final fileIndex = json['fileIndex'] as Map<String, dynamic>? ?? {};
      for (final entry in fileIndex.values) {
        final fileEntry = BackupFileEntry.fromJson(entry as Map<String, dynamic>);
        await AppStoreService.instance.putFileEntry(fileEntry);
      }

      debugPrint('WhatsAppBackup: manifest restored for $appId (${backupsList.length} backups, ${fileIndex.length} files)');
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('NoSuchKey') ||
          errorStr.contains('Object not found') ||
          errorStr.contains('404')) {
        debugPrint('WhatsAppBackup: no manifest found for $appId (new user)');
      } else {
        debugPrint('WhatsAppBackup: restoreManifest error: $e');
      }
    }
  }

  // ============================================================================
  // HELPERS
  // ============================================================================

  Future<bool> _ensureBackupBucketExists() async {
    if (_backupBucketChecked && _backupBucketExists) return true;

    try {
      await FulaApiService.instance.createBucket(_backupBucket);
      _backupBucketExists = true;
      _backupBucketChecked = true;
      return true;
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('BucketAlreadyExists') ||
          errorStr.contains('BucketAlreadyOwnedByYou')) {
        _backupBucketExists = true;
        _backupBucketChecked = true;
        return true;
      }
      _backupBucketExists = false;
      _backupBucketChecked = false;
      return false;
    }
  }

  Future<String?> _getUserId() async {
    try {
      final publicKey = await AuthService.instance.getPublicKeyString();
      if (publicKey == null || publicKey.isEmpty) return null;
      final bytes = utf8.encode(publicKey);
      final hash = sha256.convert(bytes);
      return hash.toString().substring(0, 16);
    } catch (e) {
      return null;
    }
  }

  /// Get backup stats for display.
  ({int totalFiles, int totalBytes, DateTime? lastBackup}) getStats(String appId) {
    final entries = AppStoreService.instance.getAllFileEntries();
    final totalBytes = entries.fold<int>(0, (sum, e) => sum + e.sizeBytes);
    final app = AppStoreService.instance.getActivatedApp(appId);
    return (
      totalFiles: entries.length,
      totalBytes: totalBytes,
      lastBackup: app?.lastBackupAt,
    );
  }
}
