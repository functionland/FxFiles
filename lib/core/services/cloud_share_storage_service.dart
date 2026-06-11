import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';

/// Service for syncing share data to cloud storage
///
/// This allows recovery of shares if local storage is cleared.
/// Shares are encrypted with the user's encryption key before upload.
///
/// Storage structure:
/// - Bucket: 'fula-metadata' (or configured metadata bucket)
/// - Key: '.fula/shares/{userId}.json.enc'
class CloudShareStorageService {
  static final CloudShareStorageService instance = CloudShareStorageService._();
  CloudShareStorageService._();

  static const String _metadataBucket = 'fula-metadata';
  static const String _sharesPrefix = '.fula/shares/';

  /// The bucket WRITES/DELETES route to: `fula-metadata-v8` once the shared
  /// bucket is v8-managed (legacy forest is gc-damaged), else `fula-metadata`.
  /// Reads MERGE both via `downloadObjectMerged`. No-op until `fula-metadata`
  /// joins the managed set.
  String get _writeBucket =>
      BucketVersionResolver.writeBucket(_metadataBucket);

  /// Upload outgoing shares to cloud
  ///
  /// Shares are encrypted automatically by fula_client before upload
  Future<void> uploadShares(List<OutgoingShare> shares) async {
    if (!FulaApiService.instance.isConfigured) {
      debugPrint('CloudShareStorage: Fula API not configured, skipping upload');
      return;
    }

    final userId = await _getUserId();
    if (userId == null) {
      throw CloudShareStorageException('User ID not available');
    }

    try {
      // Convert shares to JSON
      final sharesJson = shares.map((s) => s.toJson()).toList();
      final jsonString = jsonEncode({
        'version': 1,
        'updatedAt': DateTime.now().toIso8601String(),
        'shares': sharesJson,
      });

      // Ensure bucket exists
      await _ensureBucketExists();

      // Upload to cloud (encryption handled by fula_client)
      final key = '$_sharesPrefix$userId.json';
      final data = Uint8List.fromList(utf8.encode(jsonString));
      await FulaApiService.instance.uploadObject(
        _writeBucket,
        key,
        data,
        contentType: 'application/json',
      );

      debugPrint('CloudShareStorage: Uploaded ${shares.length} shares to cloud');
    } catch (e) {
      debugPrint('CloudShareStorage: Failed to upload shares: $e');
      rethrow;
    }
  }

  /// Download shares from cloud (decryption handled by fula_client)
  Future<List<OutgoingShare>> downloadShares() async {
    if (!FulaApiService.instance.isConfigured) {
      debugPrint('CloudShareStorage: Fula API not configured');
      return [];
    }

    final userId = await _getUserId();
    if (userId == null) {
      debugPrint('CloudShareStorage: User ID not available');
      return [];
    }

    await _ensureBucketExists();

    final key = '$_sharesPrefix$userId.json';
    // MERGE legacy + v8 (additive, v8 wins a dup id). downloadObjectMerged
    // skips a 404/absent bucket but RETHROWS a hard (non-404) error, so
    // syncShares' catch falls back to local instead of dropping cloud state.
    final blobs = await FulaApiService.instance
        .downloadObjectMerged(_metadataBucket, key);

    final byId = <String, OutgoingShare>{};
    for (final data in blobs) {
      final Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(utf8.decode(data));
        if (decoded is! Map<String, dynamic>) {
          debugPrint('CloudShareStorage: shares manifest is not an object');
          continue;
        }
        json = decoded;
      } catch (e) {
        debugPrint('CloudShareStorage: shares manifest parse failed: $e');
        continue;
      }
      final sharesJson = json['shares'] as List<dynamic>? ?? <dynamic>[];
      for (final entry in sharesJson) {
        if (entry is! Map<String, dynamic>) continue;
        try {
          final s = OutgoingShare.fromJson(entry);
          byId.putIfAbsent(s.id, () => s); // [v8, legacy] order ⇒ v8 wins
        } catch (e) {
          debugPrint('CloudShareStorage: skipping malformed share entry: $e');
        }
      }
    }

    final shares = byId.values.toList();
    debugPrint('CloudShareStorage: Downloaded ${shares.length} shares from cloud (merged)');
    return shares;
  }

  /// Sync local shares with cloud
  ///
  /// Merges local and cloud shares, preferring local for conflicts
  Future<List<OutgoingShare>> syncShares(List<OutgoingShare> localShares) async {
    try {
      final cloudShares = await downloadShares();

      // Merge: local takes precedence for same ID
      final mergedMap = <String, OutgoingShare>{};

      // Add all cloud shares first
      for (final share in cloudShares) {
        mergedMap[share.id] = share;
      }

      // Override with local shares
      for (final share in localShares) {
        mergedMap[share.id] = share;
      }

      final mergedShares = mergedMap.values.toList();

      // Sort by creation date (newest first)
      mergedShares.sort((a, b) => b.sharedAt.compareTo(a.sharedAt));

      // Upload merged list if there are changes
      if (mergedShares.length != localShares.length ||
          mergedShares.length != cloudShares.length) {
        await uploadShares(mergedShares);
      }

      return mergedShares;
    } catch (e) {
      debugPrint('CloudShareStorage: Sync failed, using local only: $e');
      return localShares;
    }
  }

  /// Upload accepted shares to cloud
  Future<void> uploadAcceptedShares(List<AcceptedShare> shares) async {
    if (!FulaApiService.instance.isConfigured) return;

    final userId = await _getUserId();
    if (userId == null) return;

    try {
      final sharesJson = shares.map((s) => s.toJson()).toList();
      final jsonString = jsonEncode({
        'version': 1,
        'updatedAt': DateTime.now().toIso8601String(),
        'acceptedShares': sharesJson,
      });

      await _ensureBucketExists();

      final key = '$_sharesPrefix${userId}_accepted.json';
      final data = Uint8List.fromList(utf8.encode(jsonString));
      await FulaApiService.instance.uploadObject(
        _writeBucket,
        key,
        data,
        contentType: 'application/json',
      );

      debugPrint('CloudShareStorage: Uploaded ${shares.length} accepted shares to cloud');
    } catch (e) {
      debugPrint('CloudShareStorage: Failed to upload accepted shares: $e');
    }
  }

  /// Download accepted shares from cloud
  Future<List<AcceptedShare>> downloadAcceptedShares() async {
    if (!FulaApiService.instance.isConfigured) return [];

    final userId = await _getUserId();
    if (userId == null) return [];

    await _ensureBucketExists();

    final key = '$_sharesPrefix${userId}_accepted.json';
    // MERGE legacy + v8 (additive, v8 wins a dup id). Preserve the old
    // contract: a hard (non-404) gateway error surfaces; any other failure
    // degrades to empty.
    final List<Uint8List> blobs;
    try {
      blobs = await FulaApiService.instance
          .downloadObjectMerged(_metadataBucket, key);
    } on FulaApiException {
      rethrow;
    } catch (e) {
      debugPrint('CloudShareStorage: Failed to download accepted shares: $e');
      return [];
    }

    final byId = <String, AcceptedShare>{};
    for (final data in blobs) {
      final Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(utf8.decode(data));
        if (decoded is! Map<String, dynamic>) {
          debugPrint('CloudShareStorage: accepted shares manifest is not an object');
          continue;
        }
        json = decoded;
      } catch (e) {
        debugPrint('CloudShareStorage: accepted shares manifest parse failed: $e');
        continue;
      }
      final sharesJson = json['acceptedShares'] as List<dynamic>? ?? <dynamic>[];
      for (final entry in sharesJson) {
        if (entry is! Map<String, dynamic>) continue;
        try {
          final s = AcceptedShare.fromJson(entry);
          byId.putIfAbsent(s.id, () => s); // [v8, legacy] order ⇒ v8 wins
        } catch (e) {
          debugPrint('CloudShareStorage: skipping malformed accepted share: $e');
        }
      }
    }

    final shares = byId.values.toList();
    debugPrint('CloudShareStorage: Downloaded ${shares.length} accepted shares from cloud (merged)');
    return shares;
  }

  /// Upload the revoked-share-ID list to cloud so that revokes propagate to
  /// other devices after a restore.
  Future<void> uploadRevokedList(List<String> revokedIds) async {
    if (!FulaApiService.instance.isConfigured) return;
    final userId = await _getUserId();
    if (userId == null) return;
    try {
      final jsonString = jsonEncode({
        'version': 1,
        'updatedAt': DateTime.now().toIso8601String(),
        'revokedShareIds': revokedIds,
      });
      await _ensureBucketExists();
      final key = '$_sharesPrefix${userId}_revoked.json';
      final data = Uint8List.fromList(utf8.encode(jsonString));
      await FulaApiService.instance.uploadObject(
        _writeBucket,
        key,
        data,
        contentType: 'application/json',
      );
      debugPrint(
          'CloudShareStorage: Uploaded ${revokedIds.length} revoked IDs to cloud');
    } catch (e) {
      debugPrint('CloudShareStorage: Failed to upload revoked list: $e');
    }
  }

  /// Download the revoked-share-ID list from cloud. Returns an empty list if
  /// no remote list is stored yet.
  Future<List<String>> downloadRevokedList() async {
    if (!FulaApiService.instance.isConfigured) return [];
    final userId = await _getUserId();
    if (userId == null) return [];
    await _ensureBucketExists();
    final key = '$_sharesPrefix${userId}_revoked.json';
    // Fully lenient (matches old): any failure degrades to empty.
    final List<Uint8List> blobs;
    try {
      blobs = await FulaApiService.instance
          .downloadObjectMerged(_metadataBucket, key);
    } catch (e) {
      debugPrint('CloudShareStorage: Failed to download revoked list: $e');
      return [];
    }

    // UNION the revoked IDs from both buckets — a revoke on either device must
    // propagate (revokes are monotonic).
    final ids = <String>{};
    for (final data in blobs) {
      try {
        final decoded = jsonDecode(utf8.decode(data));
        if (decoded is! Map<String, dynamic>) {
          debugPrint('CloudShareStorage: revoked manifest is not an object');
          continue;
        }
        final raw = decoded['revokedShareIds'] as List<dynamic>? ?? <dynamic>[];
        ids.addAll(raw.map((e) => e.toString()));
      } catch (e) {
        debugPrint('CloudShareStorage: revoked manifest parse failed: $e');
      }
    }

    final list = ids.toList();
    debugPrint(
        'CloudShareStorage: Downloaded ${list.length} revoked IDs from cloud (merged)');
    return list;
  }

  /// Delete shares from cloud
  Future<void> deleteShares() async {
    if (!FulaApiService.instance.isConfigured) return;

    final userId = await _getUserId();
    if (userId == null) return;

    try {
      final key = '$_sharesPrefix$userId.json';
      // Route to the v8 bucket (H2): the legacy shares manifest is preserved
      // (a legacy delete would 410 on the gc-damaged forest anyway) and is
      // filtered by the revoked-list on the next merge-read.
      await FulaApiService.instance.deleteObject(_writeBucket, key);
      debugPrint('CloudShareStorage: Deleted shares from cloud');
    } on FulaApiException catch (e) {
      // Ignore if bucket/key doesn't exist
      if (e.message.contains('NoSuchKey') ||
          e.message.contains('NoSuchBucket') ||
          e.message.contains('bucket not found') ||
          e.message.contains('404')) {
        debugPrint('CloudShareStorage: No shares to delete');
        return;
      }
      debugPrint('CloudShareStorage: Failed to delete shares: $e');
    } catch (e) {
      debugPrint('CloudShareStorage: Failed to delete shares: $e');
    }
  }

  /// Get user ID for storage key.
  ///
  /// Hashes the BASE64 STRING of the public key (utf8 bytes), not the
  /// raw key — that's the historical input every per-user manifest key
  /// was derived with, so it can never change. Sourced directly from
  /// FulaApiService (platform-neutral) rather than AuthService
  /// (dart:io-tainted): every public method of this service guards on
  /// `isConfigured` before calling this, which is exactly the state in
  /// which AuthService.getPublicKeyString() returned the same bytes.
  Future<String?> _getUserId() async {
    try {
      final publicKey =
          base64Encode(await FulaApiService.instance.getPublicKey());

      // Use first 16 chars of SHA256 hash of public key as user ID
      final bytes = utf8.encode(publicKey);
      final hash = sha256.convert(bytes);
      return hash.toString().substring(0, 16);
    } catch (e) {
      debugPrint('CloudShareStorage: could not derive user ID: $e');
      return null;
    }
  }

  /// Ensure the metadata bucket exists
  Future<void> _ensureBucketExists() async {
    try {
      final exists = await FulaApiService.instance.bucketExists(_writeBucket);
      if (!exists) {
        await FulaApiService.instance.createBucket(_writeBucket);
        debugPrint('CloudShareStorage: Created metadata bucket');
      }
    } catch (e) {
      // Bucket might already exist or we don't have permission to create
      debugPrint('CloudShareStorage: Could not ensure bucket exists: $e');
    }
  }
}

class CloudShareStorageException implements Exception {
  final String message;
  CloudShareStorageException(this.message);

  @override
  String toString() => 'CloudShareStorageException: $message';
}
