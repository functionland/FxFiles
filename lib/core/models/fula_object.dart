import 'dart:convert';

class FulaObject {
  final String key;
  final int size;
  final DateTime? lastModified;
  final String? etag;
  final bool isDirectory;
  final Map<String, String>? metadata;

  /// The bucket this object physically lives in (v8 migration). Set by the
  /// listing layer so that, in a merged legacy+v8 category view, each item's
  /// later download / delete / share / thumbnail targets the correct bucket.
  /// Null when unknown (constructed outside the listing path) — callers then
  /// fall back to the category's default bucket.
  final String? sourceBucket;

  FulaObject({
    required this.key,
    required this.size,
    this.lastModified,
    this.etag,
    this.isDirectory = false,
    this.metadata,
    this.sourceBucket,
  });

  /// Return a copy tagged with [bucket] as its [sourceBucket].
  FulaObject withSourceBucket(String bucket) => FulaObject(
        key: key,
        size: size,
        lastModified: lastModified,
        etag: etag,
        isDirectory: isDirectory,
        metadata: metadata,
        sourceBucket: bucket,
      );

  String get name {
    if (isDirectory) {
      final parts = key.split('/');
      return parts.where((p) => p.isNotEmpty).lastOrNull ?? key;
    }
    return key.split('/').last;
  }

  String get extension {
    if (isDirectory) return '';
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex == name.length - 1) return '';
    return name.substring(dotIndex + 1).toLowerCase();
  }

  String get parentPath {
    final parts = key.split('/');
    if (parts.length <= 1) return '';
    parts.removeLast();
    return parts.join('/');
  }

  /// Check if file is encrypted (supports both old and new metadata formats)
  bool get isEncrypted {
    // New format from fula_client
    if (metadata?['isEncrypted'] == 'true') return true;
    // Legacy format
    if (metadata?['x-fula-encrypted'] == 'true') return true;
    return false;
  }

  /// Get storage key (obfuscated CID-like key used on server)
  String? get storageKey => metadata?['storageKey'];

  /// Get original filename (with fula_client, key IS the original name)
  /// For legacy compatibility, also checks x-fula-original-filename
  String? get originalFilename {
    // Legacy format - check for encoded filename
    final encoded = metadata?['x-fula-original-filename'];
    if (encoded != null) {
      // Check if filename is base64 encoded
      if (metadata?['x-fula-filename-encoding'] == 'base64') {
        try {
          return utf8.decode(base64Decode(encoded));
        } catch (_) {
          return encoded; // Fallback to raw value if decoding fails
        }
      }
      return encoded;
    }
    // With fula_client FlatNamespace, key is the original path
    return name;
  }

  /// Get content type (supports both old and new formats)
  String? get originalContentType {
    return metadata?['contentType'] ?? metadata?['x-fula-original-content-type'];
  }

  bool get isImage {
    final ext = extension;
    return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'svg'].contains(ext);
  }

  bool get isVideo {
    final ext = extension;
    return ['mp4', 'mov', 'avi', 'mkv', 'webm', 'flv', 'm4v', '3gp'].contains(ext);
  }

  bool get isAudio {
    final ext = extension;
    return ['mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a', 'wma', 'opus'].contains(ext);
  }

  bool get isDocument {
    final ext = extension;
    return ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf', 'md'].contains(ext);
  }

  String get sizeFormatted {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// JSON for the v8 legacy-listing cache (Phase 3). Round-trips every field
  /// including [sourceBucket] so a cached merged item still routes correctly.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'size': size,
        'lastModified': lastModified?.millisecondsSinceEpoch,
        'etag': etag,
        'isDirectory': isDirectory,
        'metadata': metadata,
        'sourceBucket': sourceBucket,
      };

  factory FulaObject.fromJson(Map<String, dynamic> j) => FulaObject(
        key: j['key'] as String,
        size: (j['size'] as num?)?.toInt() ?? 0,
        lastModified: j['lastModified'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(j['lastModified'] as int),
        etag: j['etag'] as String?,
        isDirectory: j['isDirectory'] as bool? ?? false,
        metadata: (j['metadata'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ),
        sourceBucket: j['sourceBucket'] as String?,
      );
}

class FulaObjectMetadata {
  final int size;
  final DateTime? lastModified;
  final String? etag;
  final String? contentType;
  final Map<String, String> userMetadata;
  final bool isEncrypted;
  final String? originalFilename;

  FulaObjectMetadata({
    required this.size,
    this.lastModified,
    this.etag,
    this.contentType,
    this.userMetadata = const {},
    this.isEncrypted = false,
    this.originalFilename,
  });

  factory FulaObjectMetadata.fromMap(Map<String, dynamic> data) {
    return FulaObjectMetadata(
      size: data['size'] as int? ?? 0,
      lastModified: data['lastModified'] as DateTime?,
      etag: data['etag'] as String?,
      contentType: data['contentType'] as String?,
      userMetadata: (data['metadata'] as Map<String, String>?) ?? {},
      isEncrypted: data['metadata']?['x-fula-encrypted'] == 'true',
      originalFilename: data['metadata']?['x-fula-original-filename'],
    );
  }
}
