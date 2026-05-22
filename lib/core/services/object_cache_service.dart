import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';

/// Per-bucket stale-cache for `listObjects` results, mirroring
/// [BucketCacheService] for bucket-name lists.
///
/// Purpose: keep the Cloud Files / phone-bucket UI responsive when
/// `FulaApiService.listObjects` is slow or fails. This happens whenever
///
///   * The encrypted client's outer write lock is held by an in-flight
///     upload (`fula-flutter/src/api/forest.rs` takes `write().await` on
///     `EncryptedClientHandle.inner` for puts — fix queued in Phase B1).
///   * The IPNS chain RPC backing the forest's users-index resolution is
///     unreachable or slow (e.g. `mainnet.base.org` outages).
///
/// Like [BucketCacheService], entries are scoped to a per-user owner hash
/// of [SecureStorageKeys.derivationEmail], so signing in as a different
/// account is treated as a cache miss. Sign-out clears via [clearAll].
///
/// One cache entry per (bucket, prefix) tuple. Prefix-narrowed cache keys
/// keep large buckets manageable (we only persist the slice the UI just
/// fetched).
class ObjectCacheService {
  ObjectCacheService._();

  static const String _keyPrefix = 'cached_objects_v1::';

  /// Persist the most recent successful list for [bucket]/[prefix].
  /// No-op if no derivation email is available (pre-sign-in).
  static Future<void> persist(
    String bucket,
    String prefix,
    List<FulaObject> objects,
  ) async {
    final ownerHash = await _ownerHash();
    if (ownerHash == null) return;

    try {
      await SecureStorageService.instance.writeJson(_storageKey(bucket, prefix), {
        'owner': ownerHash,
        'bucket': bucket,
        'prefix': prefix,
        'objects': objects.map(_objectToJson).toList(),
        'fetched_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('ObjectCacheService: persist($bucket, "$prefix") failed: $e');
    }
  }

  /// Read the cached list for [bucket]/[prefix]. Returns null on miss,
  /// owner mismatch, or malformed payload.
  static Future<({List<FulaObject> objects, DateTime fetchedAt})?> readCache(
    String bucket,
    String prefix,
  ) async {
    final ownerHash = await _ownerHash();
    if (ownerHash == null) return null;
    try {
      final json = await SecureStorageService.instance.readJson(_storageKey(bucket, prefix));
      if (json == null) return null;
      if (json['owner'] != ownerHash) return null;
      if (json['bucket'] != bucket) return null;

      final raw = json['objects'];
      if (raw is! List) return null;

      final objects = raw
          .whereType<Map>()
          .map((m) => _objectFromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false);

      final fetchedAt = DateTime.tryParse(json['fetched_at'] as String? ?? '');
      if (fetchedAt == null) return null;

      return (objects: objects, fetchedAt: fetchedAt);
    } catch (e) {
      debugPrint('ObjectCacheService: readCache($bucket, "$prefix") failed: $e');
      return null;
    }
  }

  /// No-op on the secure-storage side: SecureStorageService doesn't expose
  /// a prefix scan, and the per-user owner-hash gate on [readCache] already
  /// makes cross-user reads return null. Sign-out callers can rely on that
  /// gate; remaining entries sit until the app is uninstalled or the OS
  /// prunes the keychain.
  static Future<void> clearAll() async {
    // Intentionally empty — see method doc.
  }

  static String _storageKey(String bucket, String prefix) {
    final digest = sha256.convert(utf8.encode('$bucket|$prefix')).bytes;
    return '$_keyPrefix${base64UrlEncode(digest).substring(0, 24)}';
  }

  static Map<String, dynamic> _objectToJson(FulaObject obj) => {
        'key': obj.key,
        'size': obj.size,
        'lastModified': obj.lastModified?.toIso8601String(),
        'etag': obj.etag,
        'isDirectory': obj.isDirectory,
        'metadata': obj.metadata,
      };

  static FulaObject _objectFromJson(Map<String, dynamic> json) => FulaObject(
        key: json['key'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        lastModified: json['lastModified'] is String
            ? DateTime.tryParse(json['lastModified'] as String)
            : null,
        etag: json['etag'] as String?,
        isDirectory: json['isDirectory'] as bool? ?? false,
        metadata: json['metadata'] is Map
            ? Map<String, String>.from(
                (json['metadata'] as Map).map(
                  (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
                ),
              )
            : null,
      );

  static Future<String?> _ownerHash() async {
    final email = await SecureStorageService.instance
        .read(SecureStorageKeys.derivationEmail);
    if (email == null || email.isEmpty) return null;
    final digest = sha256.convert(utf8.encode(email)).bytes;
    return base64UrlEncode(digest).substring(0, 16);
  }
}
