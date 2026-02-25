import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/auth_service.dart';

/// Service for storing and managing file tags locally and in S3
class TagStorageService {
  TagStorageService._();
  static final TagStorageService instance = TagStorageService._();

  late Box<FileTag> _tagsBox;
  late Box<TaggedFile> _taggedFilesBox;
  bool _isInitialized = false;
  final _uuid = const Uuid();

  // S3 bucket for tag metadata
  static const String _tagMetadataBucket = 'tag-metadata';
  bool _bucketChecked = false;
  bool _bucketExists = false;

  // Debounce cloud sync
  DateTime? _lastSyncTime;
  bool _syncScheduled = false;
  static const Duration _syncDebounce = Duration(seconds: 5);

  // Listeners for tag changes
  final List<VoidCallback> _listeners = [];

  /// Initialize Hive boxes for tag storage
  Future<void> init() async {
    if (_isInitialized) return;

    try {
      // Register adapters if not already registered
      if (!Hive.isAdapterRegistered(20)) {
        Hive.registerAdapter(FileTagAdapter());
      }
      if (!Hive.isAdapterRegistered(21)) {
        Hive.registerAdapter(TaggedFileAdapter());
      }

      _tagsBox = await Hive.openBox<FileTag>('file_tags');
      _taggedFilesBox = await Hive.openBox<TaggedFile>('tagged_files');

      _isInitialized = true;
      debugPrint('TagStorageService initialized with ${_tagsBox.length} tags and ${_taggedFilesBox.length} tagged files');
    } catch (e) {
      debugPrint('Failed to initialize TagStorageService: $e');
    }
  }

  /// Add a listener for tag changes
  void addListener(VoidCallback callback) {
    _listeners.add(callback);
  }

  /// Remove a listener
  void removeListener(VoidCallback callback) {
    _listeners.remove(callback);
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      try {
        listener();
      } catch (e) {
        debugPrint('TagStorageService listener error: $e');
      }
    }
  }

  // ============================================================================
  // TAG MANAGEMENT
  // ============================================================================

  /// Create a new tag
  Future<FileTag> createTag({
    required String name,
    required int colorValue,
  }) async {
    if (!_isInitialized) await init();

    final tag = FileTag(
      id: _uuid.v4(),
      name: name.trim(),
      colorValue: colorValue,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      fileCount: 0,
    );

    await _tagsBox.put(tag.id, tag);
    _scheduleSyncToCloud();
    _notifyListeners();

    debugPrint('Created tag: ${tag.name} (${tag.id})');
    return tag;
  }

  /// Get all tags
  Future<List<FileTag>> getAllTags() async {
    if (!_isInitialized) await init();
    return _tagsBox.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// Get a tag by ID
  Future<FileTag?> getTag(String tagId) async {
    if (!_isInitialized) await init();
    return _tagsBox.get(tagId);
  }

  /// Update tag name
  Future<void> updateTagName(String tagId, String newName) async {
    if (!_isInitialized) await init();
    final tag = _tagsBox.get(tagId);
    if (tag != null) {
      tag.name = newName.trim();
      tag.updatedAt = DateTime.now();
      await _tagsBox.put(tagId, tag);
      _scheduleSyncToCloud();
      _notifyListeners();
    }
  }

  /// Update tag color
  Future<void> updateTagColor(String tagId, int newColorValue) async {
    if (!_isInitialized) await init();
    final tag = _tagsBox.get(tagId);
    if (tag != null) {
      tag.colorValue = newColorValue;
      tag.updatedAt = DateTime.now();
      await _tagsBox.put(tagId, tag);
      _scheduleSyncToCloud();
      _notifyListeners();
    }
  }

  /// Delete a tag and all its file associations
  Future<void> deleteTag(String tagId) async {
    if (!_isInitialized) await init();

    // Remove all file associations for this tag
    final toRemove = _taggedFilesBox.values
        .where((tf) => tf.tagId == tagId)
        .map((tf) => tf.id)
        .toList();

    for (final id in toRemove) {
      await _taggedFilesBox.delete(id);
    }

    // Delete the tag
    await _tagsBox.delete(tagId);
    _scheduleSyncToCloud();
    _notifyListeners();

    debugPrint('Deleted tag: $tagId (and ${toRemove.length} file associations)');
  }

  /// Search tags by name
  Future<List<FileTag>> searchTags(String query) async {
    if (!_isInitialized) await init();

    if (query.isEmpty) return getAllTags();

    final lowerQuery = query.toLowerCase();
    return _tagsBox.values
        .where((t) => t.name.toLowerCase().contains(lowerQuery))
        .toList();
  }

  // ============================================================================
  // FILE TAGGING
  // ============================================================================

  /// Tag a file with a tag
  Future<void> tagFile({
    required String tagId,
    String? localPath,
    String? remoteKey,
    String? iosAssetId,
    required String fileName,
  }) async {
    if (!_isInitialized) await init();

    // Check if already tagged
    final existing = _findTaggedFile(tagId, localPath, remoteKey, iosAssetId);
    if (existing != null) return; // Already tagged

    final taggedFile = TaggedFile(
      id: _uuid.v4(),
      tagId: tagId,
      localPath: localPath,
      remoteKey: remoteKey,
      iosAssetId: iosAssetId,
      fileName: fileName,
      taggedAt: DateTime.now(),
    );

    await _taggedFilesBox.put(taggedFile.id, taggedFile);

    // Update tag file count
    await _updateTagFileCount(tagId);
    _scheduleSyncToCloud();
    _notifyListeners();

    debugPrint('Tagged file: $fileName with tag $tagId');
  }

  /// Remove a tag from a file
  Future<void> untagFile({
    required String tagId,
    String? localPath,
    String? remoteKey,
    String? iosAssetId,
  }) async {
    if (!_isInitialized) await init();

    final taggedFile = _findTaggedFile(tagId, localPath, remoteKey, iosAssetId);
    if (taggedFile == null) return;

    await _taggedFilesBox.delete(taggedFile.id);

    // Update tag file count
    await _updateTagFileCount(tagId);
    _scheduleSyncToCloud();
    _notifyListeners();

    debugPrint('Untagged file from tag $tagId');
  }

  /// Remove all tags from a file
  Future<void> removeAllTagsFromFile({
    String? localPath,
    String? remoteKey,
    String? iosAssetId,
  }) async {
    if (!_isInitialized) await init();

    final tagIds = <String>{};
    final toRemove = _taggedFilesBox.values.where((tf) {
      if (iosAssetId != null && tf.iosAssetId == iosAssetId) return true;
      if (localPath != null && tf.localPath == localPath) return true;
      if (remoteKey != null && tf.remoteKey == remoteKey) return true;
      return false;
    }).toList();

    for (final tf in toRemove) {
      tagIds.add(tf.tagId);
      await _taggedFilesBox.delete(tf.id);
    }

    // Update tag file counts
    for (final tagId in tagIds) {
      await _updateTagFileCount(tagId);
    }

    if (toRemove.isNotEmpty) {
      _scheduleSyncToCloud();
      _notifyListeners();
    }
  }

  /// Get all tags for a file
  Future<List<FileTag>> getTagsForFile({
    String? localPath,
    String? remoteKey,
    String? iosAssetId,
  }) async {
    if (!_isInitialized) await init();

    final tagIds = _taggedFilesBox.values.where((tf) {
      if (iosAssetId != null && tf.iosAssetId == iosAssetId) return true;
      if (localPath != null && tf.localPath == localPath) return true;
      if (remoteKey != null && tf.remoteKey == remoteKey) return true;
      return false;
    }).map((tf) => tf.tagId).toSet();

    final tags = <FileTag>[];
    for (final tagId in tagIds) {
      final tag = _tagsBox.get(tagId);
      if (tag != null) {
        tags.add(tag);
      }
    }

    return tags..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// Get all files with a specific tag
  Future<List<TaggedFile>> getFilesWithTag(String tagId) async {
    if (!_isInitialized) await init();
    return _taggedFilesBox.values
        .where((tf) => tf.tagId == tagId)
        .toList()
      ..sort((a, b) => b.taggedAt.compareTo(a.taggedAt));
  }

  /// Check if a file has a specific tag
  Future<bool> hasTag({
    required String tagId,
    String? localPath,
    String? remoteKey,
    String? iosAssetId,
  }) async {
    if (!_isInitialized) await init();
    return _findTaggedFile(tagId, localPath, remoteKey, iosAssetId) != null;
  }

  TaggedFile? _findTaggedFile(
    String tagId,
    String? localPath,
    String? remoteKey,
    String? iosAssetId,
  ) {
    return _taggedFilesBox.values.cast<TaggedFile?>().firstWhere(
      (tf) {
        if (tf == null || tf.tagId != tagId) return false;
        if (iosAssetId != null && tf.iosAssetId == iosAssetId) return true;
        if (localPath != null && tf.localPath == localPath) return true;
        if (remoteKey != null && tf.remoteKey == remoteKey) return true;
        return false;
      },
      orElse: () => null,
    );
  }

  Future<void> _updateTagFileCount(String tagId) async {
    final tag = _tagsBox.get(tagId);
    if (tag != null) {
      final count = _taggedFilesBox.values.where((tf) => tf.tagId == tagId).length;
      tag.fileCount = count;
      tag.updatedAt = DateTime.now();
      await _tagsBox.put(tagId, tag);
    }
  }

  // ============================================================================
  // S3 SYNC
  // ============================================================================

  void _scheduleSyncToCloud() {
    if (_syncScheduled) return;
    _syncScheduled = true;

    Future.delayed(_syncDebounce, () async {
      _syncScheduled = false;
      await syncToCloud();
    });
  }

  /// Ensure the tag metadata bucket exists
  Future<bool> _ensureBucketExists() async {
    if (_bucketChecked && _bucketExists) return true;

    debugPrint('TagStorageService: ensuring bucket exists: $_tagMetadataBucket');

    try {
      await FulaApiService.instance.createBucket(_tagMetadataBucket);
      _bucketExists = true;
      _bucketChecked = true;
      debugPrint('Tag metadata bucket ready: $_tagMetadataBucket');
      return true;
    } catch (e) {
      debugPrint('TagStorageService: createBucket error: $e');
      final errorStr = e.toString();

      if (errorStr.contains('BucketAlreadyExists') ||
          errorStr.contains('BucketAlreadyOwnedByYou')) {
        debugPrint('TagStorageService: bucket already exists, continuing...');
        _bucketExists = true;
        _bucketChecked = true;
        return true;
      }

      try {
        await FulaApiService.instance.listObjects(_tagMetadataBucket);
        _bucketExists = true;
        _bucketChecked = true;
        return true;
      } catch (listError) {
        final listErrorStr = listError.toString();
        if (listErrorStr.contains('AccountProblem') ||
            listErrorStr.contains('AccessDenied') ||
            listErrorStr.contains('QuotaExceeded')) {
          debugPrint('Tag metadata bucket not accessible: $listError');
          _bucketExists = false;
          _bucketChecked = true;
          return false;
        }

        _bucketExists = false;
        _bucketChecked = false;
        return false;
      }
    }
  }

  /// Get user ID for cloud storage key
  Future<String?> _getUserId() async {
    try {
      // Use AuthService to get the public key string (same as CloudSyncMappingService)
      final publicKey = await AuthService.instance.getPublicKeyString();
      if (publicKey == null || publicKey.isEmpty) {
        debugPrint('TagStorageService._getUserId: publicKey is NULL/empty from AuthService');
        return null;
      }

      debugPrint('TagStorageService._getUserId: publicKey available (${publicKey.length} chars)');

      // Generate user ID from public key hash (same as CloudSyncMappingService)
      final bytes = utf8.encode(publicKey);
      final hash = sha256.convert(bytes);
      final userId = hash.toString().substring(0, 16);
      debugPrint('TagStorageService._getUserId: derived userId=$userId');
      return userId;
    } catch (e) {
      debugPrint('Failed to get user ID: $e');
      return null;
    }
  }

  /// Sync all tags and tagged files to S3
  Future<void> syncToCloud() async {
    debugPrint('TagStorageService.syncToCloud() called');

    if (_bucketChecked && !_bucketExists) {
      debugPrint('Tag sync skipped: bucket does not exist');
      return;
    }
    if (!FulaApiService.instance.isConfigured) {
      debugPrint('Tag sync skipped: FulaApiService not configured');
      return;
    }

    // Debounce
    final now = DateTime.now();
    if (_lastSyncTime != null &&
        now.difference(_lastSyncTime!) < const Duration(seconds: 2)) {
      debugPrint('Tag sync skipped: debounce');
      return;
    }
    _lastSyncTime = now;

    if (!await _ensureBucketExists()) {
      debugPrint('Tag sync skipped: failed to ensure bucket exists');
      return;
    }
    debugPrint('TagStorageService: bucket check passed, proceeding with sync');

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      debugPrint('TagStorageService: encryption key is ${encryptionKey != null ? "available" : "NULL"}');
      if (encryptionKey == null) {
        debugPrint('Tag sync skipped: no encryption key');
        return;
      }

      final userId = await _getUserId();
      debugPrint('TagStorageService: user ID is ${userId ?? "NULL"}');
      if (userId == null) {
        debugPrint('Tag sync skipped: no user ID');
        return;
      }

      // Create metadata
      final metadata = TagCloudMetadata(
        userId: userId,
        tags: _tagsBox.values.toList(),
        taggedFiles: _taggedFilesBox.values.toList(),
        updatedAt: DateTime.now(),
      );

      // Convert to JSON and encrypt
      final jsonStr = jsonEncode(metadata.toJson());
      final data = Uint8List.fromList(utf8.encode(jsonStr));

      // Upload metadata (key must match what downloadAndDecrypt uses)
      final key = '.fula/tags/$userId.json';
      debugPrint('TagStorageService: uploading to bucket=$_tagMetadataBucket, key=$key, dataSize=${data.length}');
      await FulaApiService.instance.encryptAndUpload(
        _tagMetadataBucket,
        key,
        data,
        encryptionKey,
        // NOTE: Don't pass originalFilename - it overrides the key path!
        contentType: 'application/json',
      );

      debugPrint('Tags synced to cloud successfully: ${_tagsBox.length} tags, ${_taggedFilesBox.length} files');
    } catch (e) {
      debugPrint('TagStorageService: syncToCloud error: $e');
      final errorStr = e.toString();

      if (errorStr.contains('NoSuchBucket') || errorStr.contains('bucket not found')) {
        _bucketChecked = false;
        _bucketExists = false;
        return;
      }

      final isPermanentError = errorStr.contains('AccountProblem') ||
          errorStr.contains('QuotaExceeded') ||
          errorStr.contains('AccessDenied');

      if (isPermanentError) {
        if (_bucketExists) {
          debugPrint('Tag cloud sync disabled (permanent error): $e');
          _bucketExists = false;
          _bucketChecked = true;
        }
      }
    }
  }

  /// Restore tags from cloud after reinstall
  Future<void> restoreFromCloud() async {
    debugPrint('TagStorageService.restoreFromCloud() called');
    if (!_isInitialized) await init();
    debugPrint('TagStorageService: current local tags=${_tagsBox.length}, taggedFiles=${_taggedFilesBox.length}');

    if (!FulaApiService.instance.isConfigured) {
      debugPrint('Tag restore skipped: FulaApiService not configured');
      return;
    }

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      debugPrint('TagStorageService restore: encryption key is ${encryptionKey != null ? "available" : "NULL"}');
      if (encryptionKey == null) {
        debugPrint('Tag restore skipped: no encryption key');
        return;
      }

      final userId = await _getUserId();
      debugPrint('TagStorageService restore: user ID is ${userId ?? "NULL"}');
      if (userId == null) {
        debugPrint('Tag restore skipped: no user ID');
        return;
      }

      final key = '.fula/tags/$userId.json';
      debugPrint('TagStorageService: attempting to download from bucket=$_tagMetadataBucket, key=$key');

      final data = await FulaApiService.instance.downloadAndDecrypt(
        _tagMetadataBucket,
        key,
        encryptionKey,
      );

      debugPrint('TagStorageService: downloaded ${data.length} bytes from cloud');

      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final metadata = TagCloudMetadata.fromJson(json);

      debugPrint('TagStorageService: parsed metadata with ${metadata.tags.length} tags and ${metadata.taggedFiles.length} tagged files');

      // Only restore if local is empty or cloud has data
      if (_tagsBox.isEmpty || metadata.tags.isNotEmpty) {
        // Clear existing data
        await _tagsBox.clear();
        await _taggedFilesBox.clear();

        // Restore tags
        for (final tag in metadata.tags) {
          await _tagsBox.put(tag.id, tag);
        }

        // Restore tagged files
        for (final tf in metadata.taggedFiles) {
          await _taggedFilesBox.put(tf.id, tf);
        }

        debugPrint('Restored ${metadata.tags.length} tags and ${metadata.taggedFiles.length} tagged files from cloud');
        _notifyListeners();
      } else {
        debugPrint('TagStorageService: skipped restore - local has ${_tagsBox.length} tags, cloud has ${metadata.tags.length}');
      }
    } catch (e) {
      final errorStr = e.toString();
      // NoSuchKey is expected for new users
      if (errorStr.contains('NoSuchKey') || errorStr.contains('Object not found') || errorStr.contains('404')) {
        debugPrint('Tag restore: no cloud data found (new user or never synced)');
      } else {
        debugPrint('Failed to restore tags from cloud: $e');
      }
    }
  }

  /// Relink tagged files after reinstall (match cloud files to local files)
  Future<void> relinkTaggedFiles({
    required Map<String, String> remoteKeyToLocalPath,
    required Map<String, String> iosAssetIdToLocalPath,
  }) async {
    if (!_isInitialized) await init();

    int relinked = 0;
    for (final tf in _taggedFilesBox.values.toList()) {
      String? newLocalPath;

      // Try to match by iOS asset ID first
      if (tf.iosAssetId != null && iosAssetIdToLocalPath.containsKey(tf.iosAssetId)) {
        newLocalPath = iosAssetIdToLocalPath[tf.iosAssetId];
      }
      // Then try by remote key
      else if (tf.remoteKey != null && remoteKeyToLocalPath.containsKey(tf.remoteKey)) {
        newLocalPath = remoteKeyToLocalPath[tf.remoteKey];
      }

      if (newLocalPath != null && newLocalPath != tf.localPath) {
        await _taggedFilesBox.put(tf.id, tf.copyWith(localPath: newLocalPath));
        relinked++;
      }
    }

    if (relinked > 0) {
      debugPrint('Relinked $relinked tagged files to local paths');
      _notifyListeners();
    }
  }

  // ============================================================================
  // STATISTICS
  // ============================================================================

  /// Get total number of tags
  Future<int> getTagCount() async {
    if (!_isInitialized) await init();
    return _tagsBox.length;
  }

  /// Get total number of tagged files
  Future<int> getTaggedFileCount() async {
    if (!_isInitialized) await init();
    return _taggedFilesBox.length;
  }

  // ============================================================================
  // CLEANUP
  // ============================================================================

  /// Clear all tag data
  Future<void> clearAll() async {
    if (!_isInitialized) await init();
    await _tagsBox.clear();
    await _taggedFilesBox.clear();
    _notifyListeners();
  }
}
