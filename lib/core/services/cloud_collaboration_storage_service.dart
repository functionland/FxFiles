import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fula_files/core/models/collaboration_group.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/auth_service.dart';

/// Service for syncing collaboration data to cloud storage
///
/// Allows recovery of collaboration groups if local storage is cleared.
///
/// Storage structure:
/// - Bucket: 'fula-metadata'
/// - Key: '.fula/collaborations/{userId}.json'
class CloudCollaborationStorageService {
  static final CloudCollaborationStorageService instance =
      CloudCollaborationStorageService._();
  CloudCollaborationStorageService._();

  static const String _metadataBucket = 'fula-metadata';
  static const String _collabsPrefix = '.fula/collaborations/';

  /// The bucket WRITES route to: `fula-metadata-v8` once the shared bucket is
  /// v8-managed (legacy forest is gc-damaged), else `fula-metadata`. Reads
  /// MERGE both via `downloadObjectMerged`. No-op until `fula-metadata` joins
  /// the managed set.
  String get _writeBucket =>
      BucketVersionResolver.writeBucket(_metadataBucket);

  /// Upload outgoing collaborations to cloud
  Future<void> uploadCollaborations(List<OutgoingCollaboration> collabs) async {
    if (!FulaApiService.instance.isConfigured) {
      debugPrint('CloudCollabStorage: Fula API not configured, skipping upload');
      return;
    }

    final userId = await _getUserId();
    if (userId == null) {
      throw CloudCollaborationStorageException('User ID not available');
    }

    try {
      final collabsJson = collabs.map((c) => c.toJson()).toList();
      final jsonString = jsonEncode({
        'version': 1,
        'updatedAt': DateTime.now().toIso8601String(),
        'collaborations': collabsJson,
      });

      await _ensureBucketExists();

      final key = '$_collabsPrefix$userId.json';
      final data = Uint8List.fromList(utf8.encode(jsonString));
      await FulaApiService.instance.uploadObject(
        _writeBucket,
        key,
        data,
        contentType: 'application/json',
      );

      debugPrint('CloudCollabStorage: Uploaded ${collabs.length} collaborations');
    } catch (e) {
      debugPrint('CloudCollabStorage: Failed to upload collaborations: $e');
      rethrow;
    }
  }

  /// Download collaborations from cloud
  Future<List<OutgoingCollaboration>> downloadCollaborations() async {
    if (!FulaApiService.instance.isConfigured) {
      debugPrint('CloudCollabStorage: Fula API not configured');
      return [];
    }

    final userId = await _getUserId();
    if (userId == null) {
      debugPrint('CloudCollabStorage: User ID not available');
      return [];
    }

    await _ensureBucketExists();

    final key = '$_collabsPrefix$userId.json';
    // MERGE legacy + v8 (additive, v8 wins a dup id). downloadObjectMerged
    // skips a 404/absent bucket but RETHROWS a hard (non-404) error, so
    // syncCollaborations' catch falls back to local instead of dropping cloud
    // state. (Matches the old rethrow-on-hard-error contract.)
    final blobs = await FulaApiService.instance
        .downloadObjectMerged(_metadataBucket, key);

    final byId = <String, OutgoingCollaboration>{};
    for (final data in blobs) {
      final Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(utf8.decode(data));
        if (decoded is! Map<String, dynamic>) {
          debugPrint('CloudCollabStorage: collaborations manifest is not an object');
          continue;
        }
        json = decoded;
      } catch (e) {
        debugPrint('CloudCollabStorage: collaborations manifest parse failed: $e');
        continue;
      }
      final collabsJson = json['collaborations'] as List<dynamic>? ?? <dynamic>[];
      for (final entry in collabsJson) {
        if (entry is! Map<String, dynamic>) continue;
        try {
          final c = OutgoingCollaboration.fromJson(entry);
          byId.putIfAbsent(c.id, () => c); // [v8, legacy] order ⇒ v8 wins
        } catch (e) {
          debugPrint('CloudCollabStorage: skipping malformed collaboration: $e');
        }
      }
    }

    final collabs = byId.values.toList();
    debugPrint('CloudCollabStorage: Downloaded ${collabs.length} collaborations (merged)');
    return collabs;
  }

  /// Sync local collaborations with cloud
  ///
  /// Merges local and cloud, preferring local for same ID
  Future<List<OutgoingCollaboration>> syncCollaborations(
    List<OutgoingCollaboration> localCollabs,
  ) async {
    try {
      final cloudCollabs = await downloadCollaborations();

      final mergedMap = <String, OutgoingCollaboration>{};

      // Add cloud first
      for (final c in cloudCollabs) {
        mergedMap[c.id] = c;
      }
      // Override with local
      for (final c in localCollabs) {
        mergedMap[c.id] = c;
      }

      final merged = mergedMap.values.toList()
        ..sort((a, b) => b.sharedAt.compareTo(a.sharedAt));

      if (merged.length != localCollabs.length ||
          merged.length != cloudCollabs.length) {
        await uploadCollaborations(merged);
      }

      return merged;
    } catch (e) {
      debugPrint('CloudCollabStorage: Sync failed, using local only: $e');
      return localCollabs;
    }
  }

  /// Upload accepted collaborations to cloud
  Future<void> uploadAcceptedCollaborations(List<AcceptedCollaboration> collabs) async {
    if (!FulaApiService.instance.isConfigured) return;

    final userId = await _getUserId();
    if (userId == null) return;

    try {
      final collabsJson = collabs.map((c) => c.toJson()).toList();
      final jsonString = jsonEncode({
        'version': 1,
        'updatedAt': DateTime.now().toIso8601String(),
        'acceptedCollaborations': collabsJson,
      });

      await _ensureBucketExists();

      final key = '$_collabsPrefix${userId}_accepted.json';
      final data = Uint8List.fromList(utf8.encode(jsonString));
      await FulaApiService.instance.uploadObject(
        _writeBucket,
        key,
        data,
        contentType: 'application/json',
      );

      debugPrint('CloudCollabStorage: Uploaded ${collabs.length} accepted collaborations');
    } catch (e) {
      debugPrint('CloudCollabStorage: Failed to upload accepted collaborations: $e');
    }
  }

  /// Download accepted collaborations from cloud
  Future<List<AcceptedCollaboration>> downloadAcceptedCollaborations() async {
    if (!FulaApiService.instance.isConfigured) return [];

    final userId = await _getUserId();
    if (userId == null) return [];

    await _ensureBucketExists();

    final key = '$_collabsPrefix${userId}_accepted.json';
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
      debugPrint('CloudCollabStorage: Failed to download accepted collaborations: $e');
      return [];
    }

    final byId = <String, AcceptedCollaboration>{};
    for (final data in blobs) {
      final Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(utf8.decode(data));
        if (decoded is! Map<String, dynamic>) {
          debugPrint('CloudCollabStorage: accepted collaborations manifest is not an object');
          continue;
        }
        json = decoded;
      } catch (e) {
        debugPrint('CloudCollabStorage: accepted collaborations manifest parse failed: $e');
        continue;
      }
      final collabsJson =
          json['acceptedCollaborations'] as List<dynamic>? ?? <dynamic>[];
      for (final entry in collabsJson) {
        if (entry is! Map<String, dynamic>) continue;
        try {
          final c = AcceptedCollaboration.fromJson(entry);
          byId.putIfAbsent(c.id, () => c); // [v8, legacy] order ⇒ v8 wins
        } catch (e) {
          debugPrint('CloudCollabStorage: skipping malformed accepted collaboration: $e');
        }
      }
    }

    final collabs = byId.values.toList();
    debugPrint('CloudCollabStorage: Downloaded ${collabs.length} accepted collaborations (merged)');
    return collabs;
  }

  Future<String?> _getUserId() async {
    final publicKey = await AuthService.instance.getPublicKeyString();
    if (publicKey == null) return null;
    final bytes = utf8.encode(publicKey);
    final hash = sha256.convert(bytes);
    return hash.toString().substring(0, 16);
  }

  Future<void> _ensureBucketExists() async {
    try {
      final exists = await FulaApiService.instance.bucketExists(_writeBucket);
      if (!exists) {
        await FulaApiService.instance.createBucket(_writeBucket);
      }
    } catch (e) {
      debugPrint('CloudCollabStorage: Could not ensure bucket exists: $e');
    }
  }
}

class CloudCollaborationStorageException implements Exception {
  final String message;
  CloudCollaborationStorageException(this.message);

  @override
  String toString() => 'CloudCollaborationStorageException: $message';
}
