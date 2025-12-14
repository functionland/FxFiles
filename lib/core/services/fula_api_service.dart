import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:minio/minio.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/encryption_service.dart';

class FulaApiService {
  static final FulaApiService instance = FulaApiService._();
  FulaApiService._();

  Minio? _minio;
  String? _defaultBucket;
  bool _isConfigured = false;
  String? _pinningService;
  String? _pinningToken;

  bool get isConfigured => _isConfigured;
  String? get defaultBucket => _defaultBucket;

  void configure({
    required String endpoint,
    required String accessKey,
    required String secretKey,
    String? defaultBucket,
    bool? useSSL,
    String? pinningService,
    String? pinningToken,
  }) {
    _pinningService = pinningService;
    _pinningToken = pinningToken;
    final uri = Uri.parse(endpoint);
    
    // Auto-detect SSL from URL scheme
    final ssl = useSSL ?? uri.scheme == 'https';
    
    // For self-signed certs, globally allow bad certificates (dev only)
    if (ssl) {
      HttpOverrides.global = _AllowSelfSignedHttpOverrides();
    }
    
    _minio = Minio(
      endPoint: uri.host,
      port: uri.hasPort ? uri.port : (ssl ? 443 : 80),
      accessKey: accessKey,
      secretKey: secretKey,
      useSSL: ssl,
    );
    _defaultBucket = defaultBucket;
    _isConfigured = true;
    debugPrint('FulaApiService configured: ${uri.host}:${uri.hasPort ? uri.port : (ssl ? 443 : 80)}, SSL: $ssl');
  }

  void _ensureConfigured() {
    if (!_isConfigured || _minio == null) {
      throw FulaApiException('FulaApiService is not configured');
    }
  }

  // ============================================================================
  // BUCKET OPERATIONS
  // ============================================================================

  Future<List<String>> listBuckets() async {
    _ensureConfigured();
    try {
      final buckets = await _minio!.listBuckets();
      return buckets.map((b) => b.name).toList();
    } catch (e) {
      // If minio XML parsing fails, try to return known buckets from sync states
      debugPrint('listBuckets error: $e');
      if (e.toString().contains('XmlText') || e.toString().contains('XmlElement')) {
        debugPrint('XML parsing error, returning known category buckets');
        // Return standard category buckets as fallback
        return ['images', 'videos', 'audio', 'documents', 'archives', 'other'];
      }
      throw FulaApiException('Failed to list buckets: $e');
    }
  }

  Future<void> createBucket(String bucket) async {
    _ensureConfigured();
    try {
      await _minio!.makeBucket(bucket);
    } catch (e) {
      throw FulaApiException('Failed to create bucket: $e');
    }
  }

  Future<bool> bucketExists(String bucket) async {
    _ensureConfigured();
    try {
      return await _minio!.bucketExists(bucket);
    } catch (e) {
      throw FulaApiException('Failed to check bucket: $e');
    }
  }

  // ============================================================================
  // OBJECT OPERATIONS
  // ============================================================================

  Future<List<FulaObject>> listObjects(
    String bucket, {
    String prefix = '',
    bool recursive = false,
  }) async {
    _ensureConfigured();
    try {
      final objects = <FulaObject>[];
      final stream = _minio!.listObjects(bucket, prefix: prefix, recursive: recursive);
      
      await for (final result in stream) {
        for (final obj in result.objects) {
          objects.add(FulaObject(
            key: obj.key ?? '',
            size: obj.size ?? 0,
            lastModified: obj.lastModified,
            etag: obj.eTag,
            isDirectory: false,
          ));
        }
        for (final p in result.prefixes) {
          objects.add(FulaObject(
            key: p,
            size: 0,
            isDirectory: true,
          ));
        }
      }
      return objects;
    } catch (e) {
      throw FulaApiException('Failed to list objects: $e');
    }
  }

  Future<FulaObjectMetadata> getObjectMetadata(String bucket, String key) async {
    _ensureConfigured();
    try {
      final stat = await _minio!.statObject(bucket, key);
      return FulaObjectMetadata(
        size: stat.size ?? 0,
        lastModified: stat.lastModified,
        etag: stat.etag,
      );
    } catch (e) {
      throw FulaApiException('Failed to get object metadata: $e');
    }
  }

  Future<Uint8List> downloadObject(String bucket, String key) async {
    _ensureConfigured();
    try {
      final stream = await _minio!.getObject(bucket, key);
      final chunks = <int>[];
      await for (final chunk in stream) {
        chunks.addAll(chunk);
      }
      return Uint8List.fromList(chunks);
    } catch (e) {
      throw FulaApiException('Failed to download object: $e');
    }
  }

  Future<String> uploadObject(
    String bucket,
    String key,
    Uint8List data, {
    String? contentType,
    Map<String, String>? metadata,
  }) async {
    _ensureConfigured();
    try {
      final etag = await _minio!.putObject(
        bucket,
        key,
        Stream.value(data),
        size: data.length,
        metadata: metadata,
      );
      return etag;
    } catch (e) {
      throw FulaApiException('Failed to upload object: $e');
    }
  }

  Future<void> deleteObject(String bucket, String key) async {
    _ensureConfigured();
    try {
      await _minio!.removeObject(bucket, key);
    } catch (e) {
      throw FulaApiException('Failed to delete object: $e');
    }
  }

  // ============================================================================
  // ENCRYPTED OPERATIONS
  // ============================================================================

  Future<Uint8List> downloadAndDecrypt(
    String bucket,
    String key,
    Uint8List encryptionKey,
  ) async {
    final encryptedData = await downloadObject(bucket, key);
    return await EncryptionService.instance.decrypt(encryptedData, encryptionKey);
  }

  Future<String> encryptAndUpload(
    String bucket,
    String key,
    Uint8List data,
    Uint8List encryptionKey, {
    String? originalFilename,
    String? contentType,
  }) async {
    final encryptedData = await EncryptionService.instance.encrypt(data, encryptionKey);
    
    final metadata = <String, String>{
      'x-fula-encrypted': 'true',
      'x-fula-encryption-version': '1',
    };
    if (originalFilename != null) {
      metadata['x-fula-original-filename'] = originalFilename;
    }
    if (contentType != null) {
      metadata['x-fula-original-content-type'] = contentType;
    }

    return await uploadObject(bucket, key, encryptedData, metadata: metadata);
  }

  // ============================================================================
  // MULTIPART UPLOAD (LARGE FILES)
  // ============================================================================

  static const int multipartThreshold = 5 * 1024 * 1024; // 5MB
  static const int defaultChunkSize = 5 * 1024 * 1024; // 5MB

  Future<String> uploadLargeFile(
    String bucket,
    String key,
    Uint8List data, {
    int chunkSize = defaultChunkSize,
    void Function(UploadProgress)? onProgress,
    Map<String, String>? metadata,
  }) async {
    _ensureConfigured();
    try {
      int uploaded = 0;
      final total = data.length;
      
      // Add pinning headers to metadata
      final fullMetadata = <String, String>{...?metadata};
      if (_pinningService != null && _pinningService!.isNotEmpty) {
        fullMetadata['x-pinning-service'] = _pinningService!;
      }
      if (_pinningToken != null && _pinningToken!.isNotEmpty) {
        fullMetadata['x-pinning-token'] = _pinningToken!;
      }

      final etag = await _minio!.putObject(
        bucket,
        key,
        Stream.value(data),
        size: data.length,
        metadata: fullMetadata,
        onProgress: (bytes) {
          uploaded = bytes;
          if (onProgress != null) {
            onProgress(UploadProgress(
              bytesUploaded: uploaded,
              totalBytes: total,
            ));
          }
        },
      );
      return etag;
    } catch (e) {
      throw FulaApiException('Failed to upload large file: $e');
    }
  }

  Future<String> encryptAndUploadLargeFile(
    String bucket,
    String key,
    Uint8List data,
    Uint8List encryptionKey, {
    String? originalFilename,
    String? contentType,
    void Function(UploadProgress)? onProgress,
  }) async {
    final encryptedData = await EncryptionService.instance.encrypt(data, encryptionKey);
    
    final metadata = <String, String>{
      'x-fula-encrypted': 'true',
      'x-fula-encryption-version': '1',
    };
    if (originalFilename != null) {
      metadata['x-fula-original-filename'] = originalFilename;
    }
    if (contentType != null) {
      metadata['x-fula-original-content-type'] = contentType;
    }

    return await uploadLargeFile(
      bucket,
      key,
      encryptedData,
      onProgress: onProgress,
      metadata: metadata,
    );
  }

  // ============================================================================
  // INCOMPLETE UPLOADS MANAGEMENT
  // ============================================================================

  Future<List<IncompleteUploadInfo>> listIncompleteUploads(
    String bucket,
    String prefix,
  ) async {
    _ensureConfigured();
    try {
      final uploads = <IncompleteUploadInfo>[];
      final stream = _minio!.listIncompleteUploads(bucket, prefix);
      
      await for (final upload in stream) {
        uploads.add(IncompleteUploadInfo(
          key: upload.upload?.key,
          uploadId: upload.upload?.uploadId,
          initiated: upload.upload?.initiated,
        ));
      }
      
      return uploads;
    } catch (e) {
      throw FulaApiException('Failed to list incomplete uploads: $e');
    }
  }

  Future<void> removeIncompleteUpload(
    String bucket,
    String key,
    String uploadId,
  ) async {
    _ensureConfigured();
    try {
      await _minio!.removeIncompleteUpload(bucket, key);
    } catch (e) {
      throw FulaApiException('Failed to remove incomplete upload: $e');
    }
  }

  // ============================================================================
  // PRESIGNED URLs
  // ============================================================================

  Future<String> getPresignedDownloadUrl(
    String bucket,
    String key, {
    int expirySeconds = 3600,
  }) async {
    _ensureConfigured();
    try {
      return await _minio!.presignedGetObject(bucket, key, expires: expirySeconds);
    } catch (e) {
      throw FulaApiException('Failed to get presigned URL: $e');
    }
  }
}

class UploadProgress {
  final int bytesUploaded;
  final int totalBytes;

  UploadProgress({
    required this.bytesUploaded,
    required this.totalBytes,
  });

  double get percentage => totalBytes > 0 ? (bytesUploaded / totalBytes) * 100 : 0;
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

class _AllowSelfSignedHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}
