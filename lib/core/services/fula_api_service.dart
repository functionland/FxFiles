import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_files/core/models/fula_object.dart';

// Re-export commonly used types for convenience
export 'package:fula_client/fula_client.dart' show
    ShareMode,
    SharePermissions,
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
        timeoutSeconds: 60,
        maxRetries: 3,
      );

      final encConfig = fula.EncryptionConfig(
        secretKey: secretKey.toList(),
        enableMetadataPrivacy: true,
        obfuscationMode: fula.ObfuscationMode.flatNamespace, // Maximum privacy
      );

      _client = await fula.createEncryptedClient(config, encConfig);
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
        await fula.loadForest(_client!, bucket);
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
  Uint8List exportSecretKey() {
    _ensureConfigured();
    return Uint8List.fromList(fula.exportSecretKey(_client!));
  }

  /// Get the public key for sharing
  Uint8List getPublicKey() {
    _ensureConfigured();
    return Uint8List.fromList(fula.getPublicKey(_client!));
  }

  // ============================================================================
  // BUCKET OPERATIONS
  // ============================================================================

  Future<List<String>> listBuckets() async {
    _ensureConfigured();
    try {
      final buckets = await fula.encListBuckets(_client!);
      return buckets.map((b) => b.name).toList();
    } catch (e) {
      debugPrint('listBuckets error: $e');
      throw FulaApiException('Failed to list buckets: $e');
    }
  }

  Future<void> createBucket(String bucket) async {
    _ensureConfigured();
    try {
      await fula.encCreateBucket(_client!, bucket);
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

      final files = await fula.listFromForest(_client!, bucket);

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
  Future<DirectoryListing> listDirectory(String bucket, {String? prefix}) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);
      return await fula.listDirectory(_client!, bucket, prefix);
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
      final files = await fula.listFromForest(_client!, bucket);
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
      final data = await fula.getFlat(_client!, bucket, key);
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
      final result = await fula.putFlat(_client!, bucket, key, data.toList(), contentType);
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
      await fula.deleteFlat(_client!, bucket, key);
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
    final path = originalFilename != null ? '/$originalFilename' : key;
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
      final result = await fula.putFlat(_client!, bucket, key, data.toList(), null);

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
    final path = originalFilename != null ? '/$originalFilename' : key;
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
        await fula.putFlatDeferred(_client!, bucket, file.path, file.data.toList(), file.contentType);
      }

      // Save forest once after all uploads
      await fula.flushForest(_client!, bucket);
    } catch (e) {
      throw FulaApiException('Failed to batch upload: $e');
    }
  }

  // ============================================================================
  // SHARING
  // ============================================================================

  /// Create a share token for a file
  String createShareToken(
    String storageKey,
    Uint8List recipientPublicKey,
    ShareMode mode,
    int? expiresAt,
  ) {
    _ensureConfigured();
    return fula.createShareToken(
      _client!,
      storageKey,
      recipientPublicKey.toList(),
      mode,
      expiresAt,
    );
  }

  /// Accept a share token
  AcceptedShareHandle acceptShareToken(String tokenJson) {
    _ensureConfigured();
    return fula.acceptShare(tokenJson);
  }

  /// Download a shared file
  Future<Uint8List> downloadSharedFile(
    String bucket,
    String storageKey,
    AcceptedShareHandle share,
  ) async {
    _ensureConfigured();
    final data = await fula.getWithShare(_client!, bucket, storageKey, share);
    return Uint8List.fromList(data);
  }

  /// Get share permissions
  SharePermissions getSharePermissions(AcceptedShareHandle share) {
    return fula.getSharePermissions(share);
  }

  /// Check if share is expired
  bool isShareExpired(AcceptedShareHandle share) {
    return fula.isShareExpired(share);
  }

  // ============================================================================
  // KEY ROTATION
  // ============================================================================

  /// Create a rotation manager for key rotation
  RotationManagerHandle createRotationManager() {
    _ensureConfigured();
    return fula.createRotationManager(_client!);
  }

  /// Rotate all keys in a bucket
  Future<RotationReport> rotateBucket(
    String bucket,
    RotationManagerHandle manager,
  ) async {
    _ensureConfigured();
    return await fula.rotateBucket(_client!, bucket, manager);
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
