import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/models/share_token.dart' as local;

// Re-export commonly used types for convenience (only non-conflicting ones)
export 'package:fula_client/fula_client.dart' show
    AcceptedShareHandle,
    RotationManagerHandle,
    RotationReport,
    DirectoryListing,
    DirectoryEntry,
    FileMetadata;

class FulaApiService {
  static final FulaApiService instance = FulaApiService._();
  FulaApiService._();

  fula.EncryptedClientHandle? _client;
  String? _defaultBucket;
  bool _isConfigured = false;

  // Track which buckets have had their forest loaded
  final Set<String> _loadedForests = {};

  bool get isConfigured => _isConfigured;
  String? get defaultBucket => _defaultBucket;
  fula.EncryptedClientHandle? get client => _client;

  /// Initialize the fula_client with encryption enabled
  ///
  /// [endpoint] - The Fula gateway URL (e.g., "http://localhost:9000")
  /// [secretKey] - 32-byte encryption key (derived from user credentials)
  /// [accessToken] - Optional JWT token for authentication
  /// [defaultBucket] - Optional default bucket name
  Future<void> initialize({
    required String endpoint,
    required Uint8List secretKey,
    String? accessToken,
    String? defaultBucket,
  }) async {
    try {
      final config = fula.FulaConfig(
        endpoint: endpoint,
        accessToken: accessToken,
        timeoutSeconds: BigInt.from(60),
        maxRetries: 3,
      );

      final encConfig = fula.EncryptionConfig(
        secretKey: secretKey,
        enableMetadataPrivacy: true,
        obfuscationMode: fula.ObfuscationMode.flatNamespace, // Maximum privacy
      );

      _client = await fula.createEncryptedClient(config: config, encryption: encConfig);
      _defaultBucket = defaultBucket;
      _isConfigured = true;
      _loadedForests.clear();

      debugPrint('FulaApiService initialized with FlatNamespace encryption');
    } catch (e) {
      throw FulaApiException('Failed to initialize FulaApiService: $e');
    }
  }

  /// Legacy configure method - redirects to initialize
  /// Kept for backward compatibility during migration
  void configure({
    required String endpoint,
    required String accessKey,
    required String secretKey,
    String? defaultBucket,
    bool? useSSL,
    String? pinningService,
    String? pinningToken,
  }) {
    debugPrint('Warning: configure() is deprecated. Use initialize() instead.');
    // This method cannot be used directly with fula_client
    // The caller should use initialize() with the encryption key
    _defaultBucket = defaultBucket;
  }

  void _ensureConfigured() {
    if (!_isConfigured || _client == null) {
      throw FulaApiException('FulaApiService is not configured. Call initialize() first.');
    }
  }

  /// Ensure the forest (encrypted file index) is loaded for a bucket
  Future<void> _ensureForestLoaded(String bucket) async {
    if (!_loadedForests.contains(bucket)) {
      try {
        await fula.loadForest(client: _client!, bucket: bucket);
        _loadedForests.add(bucket);
        debugPrint('Forest loaded for bucket: $bucket');
      } catch (e) {
        // Forest may not exist yet for new buckets - that's OK
        debugPrint('Forest load for $bucket: $e (may be new bucket)');
        _loadedForests.add(bucket); // Mark as "loaded" to avoid repeated attempts
      }
    }
  }

  /// Clear loaded forest cache (call when switching users or on logout)
  void clearForestCache() {
    _loadedForests.clear();
  }

  // ============================================================================
  // KEY MANAGEMENT
  // ============================================================================

  /// Export the secret key for backup
  Future<Uint8List> exportSecretKey() async {
    _ensureConfigured();
    return await fula.exportSecretKey(client: _client!);
  }

  /// Get the public key for sharing
  Future<Uint8List> getPublicKey() async {
    _ensureConfigured();
    return await fula.getPublicKey(client: _client!);
  }

  // ============================================================================
  // BUCKET OPERATIONS
  // ============================================================================

  Future<List<String>> listBuckets() async {
    _ensureConfigured();
    try {
      final buckets = await fula.encListBuckets(client: _client!);
      return buckets.map((b) => b.name).toList();
    } catch (e) {
      debugPrint('listBuckets error: $e');
      throw FulaApiException('Failed to list buckets: $e');
    }
  }

  Future<void> createBucket(String bucket) async {
    _ensureConfigured();
    try {
      await fula.encCreateBucket(client: _client!, name: bucket);
    } catch (e) {
      // Bucket may already exist
      if (!e.toString().contains('already exists')) {
        throw FulaApiException('Failed to create bucket: $e');
      }
    }
  }

  Future<bool> bucketExists(String bucket) async {
    _ensureConfigured();
    try {
      final buckets = await listBuckets();
      return buckets.contains(bucket);
    } catch (e) {
      throw FulaApiException('Failed to check bucket: $e');
    }
  }

  // ============================================================================
  // ENCRYPTED FILE OPERATIONS (using FlatNamespace)
  // ============================================================================

  /// List all files in a bucket (from the encrypted forest index)
  Future<List<FulaObject>> listObjects(
    String bucket, {
    String prefix = '',
    bool recursive = false,
  }) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);

      final files = await fula.listFromForest(client: _client!, bucket: bucket);

      // Filter by prefix if specified
      final filtered = prefix.isEmpty
          ? files
          : files.where((f) => f.originalKey.startsWith(prefix)).toList();

      return filtered.map((meta) => FulaObject(
        key: meta.originalKey,
        size: meta.size.toInt(),
        lastModified: meta.modifiedAt != null
            ? DateTime.fromMillisecondsSinceEpoch(meta.modifiedAt! * 1000)
            : null,
        isDirectory: false,
        metadata: {
          'storageKey': meta.storageKey,
          'contentType': meta.contentType ?? '',
          'isEncrypted': meta.isEncrypted.toString(),
        },
      )).toList();
    } catch (e) {
      throw FulaApiException('Failed to list objects: $e');
    }
  }

  /// List directory structure
  Future<fula.DirectoryListing> listDirectory(String bucket, {String? prefix}) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);
      return await fula.listDirectory(client: _client!, bucket: bucket, prefix: prefix);
    } catch (e) {
      throw FulaApiException('Failed to list directory: $e');
    }
  }

  /// Get file metadata without downloading content
  Future<FulaObjectMetadata> getObjectMetadata(String bucket, String key) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);

      // Find the file in the forest
      final files = await fula.listFromForest(client: _client!, bucket: bucket);
      final file = files.firstWhere(
        (f) => f.originalKey == key,
        orElse: () => throw FulaApiException('File not found: $key'),
      );

      return FulaObjectMetadata(
        size: file.size.toInt(),
        lastModified: file.modifiedAt != null
            ? DateTime.fromMillisecondsSinceEpoch(file.modifiedAt! * 1000)
            : null,
        contentType: file.contentType,
        isEncrypted: file.isEncrypted,
        originalFilename: file.originalKey.split('/').last,
      );
    } catch (e) {
      if (e is FulaApiException) rethrow;
      throw FulaApiException('Failed to get object metadata: $e');
    }
  }

  /// Download and decrypt a file by its path
  Future<Uint8List> downloadObject(String bucket, String key) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);
      final data = await fula.getFlat(client: _client!, bucket: bucket, path: key);
      return Uint8List.fromList(data);
    } catch (e) {
      throw FulaApiException('Failed to download object: $e');
    }
  }

  /// Upload and encrypt a file
  Future<String> uploadObject(
    String bucket,
    String key,
    Uint8List data, {
    String? contentType,
    Map<String, String>? metadata,
  }) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);
      final result = await fula.putFlat(
        client: _client!,
        bucket: bucket,
        path: key,
        data: data.toList(),
        contentType: contentType,
      );
      return result.etag;
    } catch (e) {
      throw FulaApiException('Failed to upload object: $e');
    }
  }

  /// Delete a file
  Future<void> deleteObject(String bucket, String key) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);
      await fula.deleteFlat(client: _client!, bucket: bucket, path: key);
    } catch (e) {
      throw FulaApiException('Failed to delete object: $e');
    }
  }

  // ============================================================================
  // ENCRYPTED OPERATIONS (Compatibility Layer)
  // These methods maintain backward compatibility with existing code
  // The encryption is now handled internally by fula_client
  // ============================================================================

  /// Download and decrypt - now just calls downloadObject
  /// The encryptionKey parameter is ignored as fula_client handles encryption internally
  Future<Uint8List> downloadAndDecrypt(
    String bucket,
    String key,
    Uint8List encryptionKey, // Ignored - kept for API compatibility
  ) async {
    return downloadObject(bucket, key);
  }

  /// Encrypt and upload - now just calls uploadObject with metadata
  /// The encryptionKey parameter is ignored as fula_client handles encryption internally
  Future<String> encryptAndUpload(
    String bucket,
    String key,
    Uint8List data,
    Uint8List encryptionKey, { // Ignored - kept for API compatibility
    String? originalFilename,
    String? contentType,
  }) async {
    // Use the originalFilename as the key if provided, otherwise use key
    final path = originalFilename ?? key;
    return uploadObject(bucket, path, data, contentType: contentType);
  }

  // ============================================================================
  // LARGE FILE UPLOADS
  // fula_client handles chunking internally, so these are simplified
  // ============================================================================

  Future<String> uploadLargeFile(
    String bucket,
    String key,
    Uint8List data, {
    int chunkSize = 5 * 1024 * 1024,
    void Function(UploadProgress)? onProgress,
    Map<String, String>? metadata,
  }) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);

      // fula_client handles large files automatically
      // Progress callback not yet supported in fula_client - upload directly
      final result = await fula.putFlat(
        client: _client!,
        bucket: bucket,
        path: key,
        data: data.toList(),
        contentType: null,
      );

      // Report completion
      if (onProgress != null) {
        onProgress(UploadProgress(
          bytesUploaded: data.length,
          totalBytes: data.length,
        ));
      }

      return result.etag;
    } catch (e) {
      throw FulaApiException('Failed to upload large file: $e');
    }
  }

  /// Encrypt and upload large file - now uses fula_client's built-in encryption
  Future<String> encryptAndUploadLargeFile(
    String bucket,
    String key,
    Uint8List data,
    Uint8List encryptionKey, { // Ignored - kept for API compatibility
    String? originalFilename,
    String? contentType,
    void Function(UploadProgress)? onProgress,
  }) async {
    final path = originalFilename ?? key;
    return uploadLargeFile(bucket, path, data, onProgress: onProgress);
  }

  // ============================================================================
  // BATCH OPERATIONS
  // ============================================================================

  /// Upload multiple files efficiently (deferred forest save)
  Future<void> uploadBatch(
    String bucket,
    List<BatchUploadItem> files,
  ) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);

      for (final file in files) {
        await fula.putFlatDeferred(
          client: _client!,
          bucket: bucket,
          path: file.path,
          data: file.data.toList(),
          contentType: file.contentType,
        );
      }

      // Save forest once after all uploads
      await fula.flushForest(client: _client!, bucket: bucket);
    } catch (e) {
      throw FulaApiException('Failed to batch upload: $e');
    }
  }

  // ============================================================================
  // SHARING
  // ============================================================================

  /// Convert local ShareMode to fula_client ShareMode
  fula.ShareMode _convertShareMode(local.ShareMode mode) {
    switch (mode) {
      case local.ShareMode.temporal:
        return fula.ShareMode.temporal;
      case local.ShareMode.snapshot:
        return fula.ShareMode.snapshot;
    }
  }

  /// Create a share token for a file
  /// Accepts local ShareMode from share_token.dart
  Future<String> createShareToken(
    String bucket,
    String storageKey,
    Uint8List recipientPublicKey,
    local.ShareMode mode,
    int? expiresAt,
  ) async {
    _ensureConfigured();
    return await fula.createShareTokenWithMode(
      client: _client!,
      bucket: bucket,
      storageKey: storageKey,
      recipientPublicKey: recipientPublicKey.toList(),
      mode: _convertShareMode(mode),
      expiresAt: expiresAt,
    );
  }

  /// Accept a share token
  Future<fula.AcceptedShareHandle> acceptShareToken(String tokenJson) async {
    _ensureConfigured();
    return await fula.acceptShare(client: _client!, tokenJson: tokenJson);
  }

  /// Download a shared file
  Future<Uint8List> downloadSharedFile(
    String bucket,
    String storageKey,
    fula.AcceptedShareHandle share,
  ) async {
    _ensureConfigured();
    final data = await fula.getWithShare(
      client: _client!,
      bucket: bucket,
      storageKey: storageKey,
      share: share,
    );
    return Uint8List.fromList(data);
  }

  /// Get share permissions (returns local SharePermissions enum)
  Future<local.SharePermissions> getSharePermissions(fula.AcceptedShareHandle share) async {
    final fulaPerms = await fula.getSharePermissions(share: share);
    // Convert fula_client SharePermissions class to local enum
    if (fulaPerms.canWrite) {
      return local.SharePermissions.full; // If can write, assume full access
    } else if (fulaPerms.canRead) {
      return local.SharePermissions.readOnly;
    }
    return local.SharePermissions.readOnly; // Default
  }

  /// Get raw share permissions from fula_client
  Future<fula.SharePermissions> getRawSharePermissions(fula.AcceptedShareHandle share) async {
    return await fula.getSharePermissions(share: share);
  }

  /// Check if share is expired
  Future<bool> isShareExpired(fula.AcceptedShareHandle share) async {
    return await fula.isShareExpired(share: share);
  }

  // ============================================================================
  // KEY ROTATION
  // ============================================================================

  /// Create a rotation manager for key rotation
  Future<fula.RotationManagerHandle> createRotationManager() async {
    _ensureConfigured();
    return await fula.createRotationManager(client: _client!);
  }

  /// Rotate all keys in a bucket
  Future<fula.RotationReport> rotateBucket(
    String bucket,
    fula.RotationManagerHandle manager,
  ) async {
    _ensureConfigured();
    return await fula.rotateBucket(client: _client!, bucket: bucket, manager: manager);
  }

  // ============================================================================
  // INCOMPLETE UPLOADS (Compatibility - may not be needed with fula_client)
  // ============================================================================

  Future<List<IncompleteUploadInfo>> listIncompleteUploads(
    String bucket,
    String prefix,
  ) async {
    // fula_client handles multipart internally
    // Return empty list for compatibility
    return [];
  }

  Future<void> removeIncompleteUpload(
    String bucket,
    String key,
    String uploadId,
  ) async {
    // No-op for fula_client
  }

  // ============================================================================
  // PRESIGNED URLs (Not supported with encrypted client)
  // ============================================================================

  Future<String> getPresignedDownloadUrl(
    String bucket,
    String key, {
    int expirySeconds = 3600,
  }) async {
    throw FulaApiException(
      'Presigned URLs are not supported with encrypted storage. '
      'Use sharing tokens instead.'
    );
  }

  // ============================================================================
  // CLEANUP
  // ============================================================================

  /// Reset the service (call on logout)
  void reset() {
    _client = null;
    _defaultBucket = null;
    _isConfigured = false;
    _loadedForests.clear();
  }
}

// ============================================================================
// HELPER CLASSES
// ============================================================================

class UploadProgress {
  final int bytesUploaded;
  final int totalBytes;

  UploadProgress({
    required this.bytesUploaded,
    required this.totalBytes,
  });

  double get percentage => totalBytes > 0 ? (bytesUploaded / totalBytes) * 100 : 0;
}

class BatchUploadItem {
  final String path;
  final Uint8List data;
  final String? contentType;

  BatchUploadItem({
    required this.path,
    required this.data,
    this.contentType,
  });
}

class IncompleteUploadInfo {
  final String? key;
  final String? uploadId;
  final DateTime? initiated;

  IncompleteUploadInfo({
    this.key,
    this.uploadId,
    this.initiated,
  });
}

class FulaApiException implements Exception {
  final String message;
  FulaApiException(this.message);

  @override
  String toString() => 'FulaApiException: $message';
}
