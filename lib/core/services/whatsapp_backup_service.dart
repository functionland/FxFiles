import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/app_models.dart';
import 'package:fula_files/core/services/app_store_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/sync_notification_service.dart';

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

  // Concurrency lock: prevents parallel runBackup() calls from racing on
  // _cancelled flag and index writes (e.g. UI + WorkManager in same process).
  bool _isRunning = false;
  Completer<BackupRecord?>? _runningBackup;

  // Manifest sync state
  bool _manifestSyncScheduled = false;
  static const Duration _manifestSyncDebounce = Duration(seconds: 5);

  final _progressController = StreamController<BackupProgress>.broadcast();
  Stream<BackupProgress> get progressStream => _progressController.stream;

  Future<void> init() async {
    // AppStoreService handles Hive init for all app models
    await AppStoreService.instance.init();
    // Mark any records stuck in uploading/scanning/pending as interrupted.
    // This happens when the app was killed mid-backup.
    await AppStoreService.instance.finalizeStaleRecords();
  }

  // ============================================================================
  // DIRECTORY DISCOVERY
  // ============================================================================

  /// Find the WhatsApp data directory for a given app definition.
  /// Returns null on iOS (caller must provide iosFolderPath) or if not found.
  Directory? findDataDirectory(AppDefinition app) {
    if (Platform.isIOS) {
      debugPrint('WhatsAppBackup: iOS — caller must provide folder');
      return null;
    }

    if (app.dataPathAndroid != null) {
      final dir = Directory(app.dataPathAndroid!);
      debugPrint('WhatsAppBackup: checking primary path: ${app.dataPathAndroid}');
      if (dir.existsSync()) {
        debugPrint('WhatsAppBackup: found primary path');
        // Verify we can actually list contents (permission check)
        try {
          final count = dir.listSync().length;
          debugPrint('WhatsAppBackup: primary path has $count top-level entries');
          if (count > 0) return dir;
          debugPrint('WhatsAppBackup: primary path exists but is empty, trying legacy');
        } catch (e) {
          debugPrint('WhatsAppBackup: cannot list primary path (permission?): $e');
        }
      } else {
        debugPrint('WhatsAppBackup: primary path does not exist');
      }
    }

    if (app.dataPathAndroidLegacy != null) {
      final dir = Directory(app.dataPathAndroidLegacy!);
      debugPrint('WhatsAppBackup: checking legacy path: ${app.dataPathAndroidLegacy}');
      if (dir.existsSync()) {
        debugPrint('WhatsAppBackup: found legacy path');
        try {
          final count = dir.listSync().length;
          debugPrint('WhatsAppBackup: legacy path has $count top-level entries');
          if (count > 0) return dir;
        } catch (e) {
          debugPrint('WhatsAppBackup: cannot list legacy path (permission?): $e');
        }
      } else {
        debugPrint('WhatsAppBackup: legacy path does not exist');
      }
    }

    debugPrint('WhatsAppBackup: no readable data directory found');
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
  /// [onScanProgress] reports (scannedSoFar, totalFileCount) during the scan.
  Future<ScanResult> scanForChanges(
    Directory dir, {
    void Function(int scanned, int total)? onScanProgress,
  }) async {
    final newFiles = <_FileInfo>[];
    final changedFiles = <_FileInfo>[];
    var unchangedCount = 0;
    var totalSize = 0;

    final basePath = dir.path;
    debugPrint('WhatsAppBackup: scanning $basePath');

    List<FileSystemEntity> entities;
    try {
      entities = dir.listSync(recursive: true, followLinks: false);
    } catch (e) {
      debugPrint('WhatsAppBackup: listSync FAILED for $basePath: $e');
      return ScanResult(newFiles: [], changedFiles: [], unchangedCount: 0, totalSize: 0);
    }

    final allCount = entities.length;
    final files = entities.whereType<File>().toList();
    final fileCount = files.length;
    final dirCount = entities.whereType<Directory>().length;
    debugPrint('WhatsAppBackup: found $allCount entities ($fileCount files, $dirCount dirs)');

    if (fileCount == 0) {
      // Log first few entries to help diagnose
      for (var i = 0; i < entities.length && i < 10; i++) {
        debugPrint('WhatsAppBackup:   [$i] ${entities[i].runtimeType}: ${entities[i].path}');
      }
    }

    var scanned = 0;
    for (final file in files) {
      if (_cancelled) break;

      try {
        final stat = file.statSync();
        final size = stat.size;
        final modified = stat.modified;
        final relativePath = file.path.substring(basePath.length + 1);
        final hash = await _computeQuickHash(file, size);
        final category = categorizeFile(relativePath);

        totalSize += size;

        final existing = AppStoreService.instance.getFileEntry(relativePath);
        if (existing == null) {
          newFiles.add(_FileInfo(
            relativePath: relativePath,
            file: file,
            size: size,
            modified: modified,
            hash: hash,
            category: category,
          ));
        } else if (existing.contentHash != hash || existing.sizeBytes != size) {
          changedFiles.add(_FileInfo(
            relativePath: relativePath,
            file: file,
            size: size,
            modified: modified,
            hash: hash,
            category: category,
          ));
        } else {
          unchangedCount++;
        }
      } catch (e) {
        debugPrint('WhatsAppBackup: scan error for ${file.path}: $e');
      }

      scanned++;
      // Report progress every 100 files to avoid excessive UI updates
      if (onScanProgress != null && (scanned % 100 == 0 || scanned == fileCount)) {
        onScanProgress(scanned, fileCount);
      }
    }

    debugPrint('WhatsAppBackup: scan result — ${newFiles.length} new, ${changedFiles.length} changed, $unchangedCount unchanged, ${totalSize} bytes total');
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
  /// [overrideDir] used on iOS where user selects folder manually.
  /// [showNotifications] true when running from background — shows Android
  ///   top-bar progress notification and iOS badge. The foreground UI uses
  ///   [onProgress] stream instead.
  ///
  /// Password encryption is handled automatically: if the user has set a
  /// password, the derived key is loaded from SecureStorage (works in both
  /// foreground and background). No password parameter needed.
  ///
  /// Notifications are always shown on mobile (Android top-bar, iOS badge)
  /// so the user can track progress even if they leave the app.
  Future<BackupRecord?> runBackup({
    String appId = 'whatsapp',
    Directory? overrideDir,
    void Function(BackupProgress)? onProgress,
    bool showNotifications = true,
  }) async {
    // If a backup is already running, return the existing future instead of
    // starting a second concurrent run that would race on state.
    if (_isRunning && _runningBackup != null) {
      debugPrint('WhatsAppBackup: backup already running — returning existing future');
      return _runningBackup!.future;
    }

    _isRunning = true;
    _runningBackup = Completer<BackupRecord?>();

    try {
      final result = await _runBackupInternal(
        appId: appId,
        overrideDir: overrideDir,
        onProgress: onProgress,
        showNotifications: showNotifications,
      );
      _runningBackup!.complete(result);
      return result;
    } catch (e) {
      _runningBackup!.completeError(e);
      rethrow;
    } finally {
      _isRunning = false;
      _runningBackup = null;
    }
  }

  Future<BackupRecord?> _runBackupInternal({
    required String appId,
    Directory? overrideDir,
    void Function(BackupProgress)? onProgress,
    required bool showNotifications,
  }) async {
    _cancelled = false;
    final notifier = SyncNotificationService.instance;

    // Check network
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) {
      throw Exception('No network connection');
    }

    // Find data directory
    final appDef = AppStoreService.getAppDefinition(appId);
    if (appDef == null) throw Exception('Unknown app: $appId');

    final dir = overrideDir ?? findDataDirectory(appDef);
    debugPrint('WhatsAppBackup: runBackup appId=$appId dir=${dir?.path} overrideDir=${overrideDir?.path}');
    if (dir == null || !dir.existsSync()) {
      debugPrint('WhatsAppBackup: data directory not found or does not exist');
      throw Exception('WhatsApp data directory not found');
    }

    // Ensure bucket exists
    if (!await _ensureBackupBucketExists()) {
      throw Exception('Could not create backup storage');
    }

    // Load password encryption key if the user has set one.
    // getEncryptionKey checks RAM cache first, then SecureStorage.
    // This works in both foreground and background isolates.
    final activated = AppStoreService.instance.getActivatedApp(appId);
    Uint8List? encKey;
    if (activated?.hasPassword == true) {
      encKey = await AppStoreService.instance.getEncryptionKey(appId);
      debugPrint('WhatsAppBackup: password encryption ${encKey != null ? "active" : "key not found (will skip)"}');
    }

    // Log file index state to help diagnose "0 new files" issues
    final existingEntries = AppStoreService.instance.getAllFileEntries();
    debugPrint('WhatsAppBackup: file index has ${existingEntries.length} existing entries before scan');

    // Scan for changes (no record created yet — avoids showing 0/0 in history)
    if (showNotifications) {
      await notifier.showSyncNotification(
        title: 'WhatsApp Backup',
        body: 'Scanning for changes...',
      );
    }
    _reportProgress(onProgress, const BackupProgress());

    final scan = await scanForChanges(dir, onScanProgress: (scanned, total) {
      _reportProgress(onProgress, BackupProgress(
        completedFiles: scanned,
        totalFiles: total,
        currentFile: 'Scanning files...',
      ));
      if (showNotifications) {
        notifier.updateSyncProgress(
          current: scanned,
          total: total,
          currentFile: 'Scanning...',
        );
      }
    });
    if (_cancelled) {
      if (showNotifications) await notifier.hideSyncNotification();
      return null;
    }

    // Now create the record with real values
    final record = await AppStoreService.instance.createBackupRecord(appId);
    final filesToUpload = [...scan.newFiles, ...scan.changedFiles];
    debugPrint('WhatsAppBackup: ${filesToUpload.length} files to upload, ${scan.unchangedCount} unchanged');
    if (filesToUpload.isEmpty) {
      debugPrint('WhatsAppBackup: nothing to upload — completing immediately');
      record.status = BackupStatus.completed;
      record.completedAt = DateTime.now();
      record.newFileCount = 0;
      record.totalFileCount = scan.unchangedCount;
      record.totalSizeBytes = scan.totalSize;
      await AppStoreService.instance.updateBackupRecord(record);
      await AppStoreService.instance.updateLastBackupAt(appId, DateTime.now());
      if (showNotifications) {
        await notifier.showSyncCompleteNotification(fileCount: 0);
      }
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
          final progress = BackupProgress(
            completedFiles: completedFiles,
            totalFiles: filesToUpload.length,
            completedBytes: completedBytes,
            totalBytes: scan.totalSize,
            currentFile: fileInfo.relativePath,
          );
          _reportProgress(onProgress, progress);
          if (showNotifications) {
            await notifier.updateSyncProgress(
              current: completedFiles,
              total: filesToUpload.length,
              currentFile: fileInfo.relativePath,
            );
          }
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
        final progress = BackupProgress(
          completedFiles: completedFiles,
          totalFiles: filesToUpload.length,
          completedBytes: completedBytes,
          totalBytes: scan.totalSize,
          currentFile: fileInfo.relativePath,
        );
        _reportProgress(onProgress, progress);
        if (showNotifications) {
          await notifier.updateSyncProgress(
            current: completedFiles,
            total: filesToUpload.length,
            currentFile: fileInfo.relativePath,
          );
        }
      } catch (e) {
        debugPrint('WhatsAppBackup: upload error for ${fileInfo.relativePath}: $e');
      }
    }

    // Finalize
    final hasErrors = completedFiles < filesToUpload.length;
    if (_cancelled) {
      record.status = BackupStatus.cancelled;
    } else if (hasErrors && completedFiles == 0) {
      record.status = BackupStatus.error;
      record.errorMessage = 'All uploads failed';
    } else {
      record.status = BackupStatus.completed;
      record.completedAt = DateTime.now();
    }
    record.categoryCounts = categoryCounts;
    await AppStoreService.instance.updateBackupRecord(record);
    await AppStoreService.instance.updateLastBackupAt(appId, DateTime.now());

    if (showNotifications) {
      await notifier.showSyncCompleteNotification(
        fileCount: completedFiles,
        hasErrors: hasErrors,
      );
    }

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
      encryptionKey ?? Uint8List(0),
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
  ///
  /// Password encryption is handled automatically: if the user has set a
  /// password, the derived key is loaded from SecureStorage (same as backup).
  /// The caller must ensure the session key is available (prompt once if needed).
  Future<void> restoreFiles({
    String appId = 'whatsapp',
    BackupCategory? category,
    List<String>? specificPaths,
    Directory? restoreDir,
    void Function(BackupProgress)? onProgress,
  }) async {
    _cancelled = false;

    // Load password encryption key if the user has set one.
    Uint8List? encKey;
    final app = AppStoreService.instance.getActivatedApp(appId);
    if (app != null && app.hasPassword) {
      encKey = await AppStoreService.instance.getEncryptionKey(appId);
      if (encKey == null) {
        throw Exception('Encryption key not available. Please enter your password first.');
      }
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
    final targetDir = restoreDir ?? await _getDefaultRestoreDir(appId);
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
          encryptionKey ?? Uint8List(0),
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

  Future<Directory> _getDefaultRestoreDir(String appId) async {
    final appDef = AppStoreService.getAppDefinition(appId);
    if (Platform.isAndroid && appDef?.dataPathAndroid != null) {
      return Directory(appDef!.dataPathAndroid!);
    }
    // iOS / fallback: use app documents directory (not world-readable /tmp)
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/fxfiles_restore/$appId');
  }

  void cancelRestore() {
    _cancelled = true;
  }

  // ============================================================================
  // BACKUP DELETION
  // ============================================================================

  Future<void> deleteBackup(String appId, String backupId) async {
    final entries = AppStoreService.instance.getFileEntriesForBackup(backupId);
    final failedKeys = <String>[];

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
          failedKeys.add(entry.remoteKey);
          debugPrint('WhatsAppBackup: delete error for ${entry.remoteKey}: $e');
        }
      }
    }

    if (failedKeys.isNotEmpty) {
      debugPrint('WhatsAppBackup: ${failedKeys.length} cloud files failed to delete '
          '(encrypted, inaccessible without key — orphaned storage only)');
    }

    await AppStoreService.instance.deleteBackupRecord(backupId);
    _scheduleManifestSync(appId);
  }

  /// Delete ALL backups for an app: remove every file from S3, clear local
  /// Hive indexes, and delete the cloud manifest. Resets to a clean state
  /// as if no backup ever happened.
  Future<void> deleteAllBackups(String appId, {
    void Function(int deleted, int total)? onProgress,
  }) async {
    // 1. Collect all unique remote keys from the file index
    final allEntries = AppStoreService.instance.getAllFileEntries();
    final remoteKeys = allEntries.map((e) => e.remoteKey).toSet().toList();
    debugPrint('WhatsAppBackup: deleteAllBackups — ${remoteKeys.length} cloud files to delete');

    // 2. Delete each file from S3
    var deleted = 0;
    var failedCount = 0;
    for (final key in remoteKeys) {
      try {
        await FulaApiService.instance.deleteObject(_backupBucket, key);
      } catch (e) {
        failedCount++;
        debugPrint('WhatsAppBackup: deleteAll error for $key: $e');
      }
      deleted++;
      onProgress?.call(deleted, remoteKeys.length);
    }

    if (failedCount > 0) {
      debugPrint('WhatsAppBackup: deleteAll — $failedCount/$deleted cloud deletes failed '
          '(encrypted, inaccessible without key — orphaned storage only)');
    }

    // 3. Delete the cloud manifest
    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      final userId = await _getUserId();
      if (encryptionKey != null && userId != null) {
        final manifestKey = '.fula/apps/$appId/manifests/$userId.json';
        await FulaApiService.instance.deleteObject(_backupBucket, manifestKey);
        debugPrint('WhatsAppBackup: deleted cloud manifest for $appId');
      }
    } catch (e) {
      debugPrint('WhatsAppBackup: deleteAll manifest error: $e');
    }

    // 4. Clear all local Hive data (records + file index)
    await AppStoreService.instance.clearAllBackupData(appId);

    debugPrint('WhatsAppBackup: deleteAllBackups complete — $deleted cloud files removed');
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
        // Use hashed keys as defense-in-depth (the manifest is already
        // encrypted by fula_client, but plaintext paths in keys would leak
        // structure if the outer encryption were ever compromised).
        final keyHash = sha256.convert(utf8.encode(entry.relativePath)).toString();
        fileIndex[keyHash] = entry.toJson();
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

      // Restore backup records — merge, don't overwrite.
      // If a record already exists locally (e.g. from a more recent backup on
      // this device), keep the local version to avoid destroying newer state
      // with a stale cloud manifest from a previous device.
      final backupsList = json['backups'] as List<dynamic>? ?? [];
      var restoredRecords = 0;
      for (final bJson in backupsList) {
        final record = BackupRecord.fromJson(bJson as Map<String, dynamic>);
        final existing = AppStoreService.instance.getBackupRecord(record.id);
        if (existing == null) {
          await AppStoreService.instance.updateBackupRecord(record);
          restoredRecords++;
        }
      }

      // Restore file index — merge, don't overwrite.
      final fileIndex = json['fileIndex'] as Map<String, dynamic>? ?? {};
      var restoredFiles = 0;
      for (final entry in fileIndex.values) {
        final fileEntry = BackupFileEntry.fromJson(entry as Map<String, dynamic>);
        final existing = AppStoreService.instance.getFileEntry(fileEntry.relativePath);
        if (existing == null) {
          await AppStoreService.instance.putFileEntry(fileEntry);
          restoredFiles++;
        }
      }

      debugPrint('WhatsAppBackup: manifest restored for $appId '
          '($restoredRecords/${backupsList.length} records merged, '
          '$restoredFiles/${fileIndex.length} files merged)');
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
