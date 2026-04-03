import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fula_files/core/models/collaboration_group.dart';
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
        _metadataBucket,
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

    try {
      await _ensureBucketExists();

      final key = '$_collabsPrefix$userId.json';
      final data = await FulaApiService.instance.downloadObject(
        _metadataBucket,
        key,
      );

      final jsonString = utf8.decode(data);
      final json = jsonDecode(jsonString) as Map<String, dynamic>;

      final collabsJson = json['collaborations'] as List<dynamic>;
      final collabs = collabsJson
          .map((c) => OutgoingCollaboration.fromJson(c as Map<String, dynamic>))
          .toList();

      debugPrint('CloudCollabStorage: Downloaded ${collabs.length} collaborations');
      return collabs;
    } on FulaApiException catch (e) {
      if (e.message.contains('NoSuchKey') ||
          e.message.contains('NoSuchBucket') ||
          e.message.contains('bucket not found') ||
          e.message.contains('404') ||
          e.message.contains('not found')) {
        debugPrint('CloudCollabStorage: No collaborations found in cloud');
        return [];
      }
      debugPrint('CloudCollabStorage: Failed to download collaborations: $e');
      rethrow;
    } catch (e) {
      debugPrint('CloudCollabStorage: Failed to download collaborations: $e');
      rethrow;
    }
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

  Future<String?> _getUserId() async {
    final publicKey = await AuthService.instance.getPublicKeyString();
    if (publicKey == null) return null;
    final bytes = utf8.encode(publicKey);
    final hash = sha256.convert(bytes);
    return hash.toString().substring(0, 16);
  }

  Future<void> _ensureBucketExists() async {
    try {
      final exists = await FulaApiService.instance.bucketExists(_metadataBucket);
      if (!exists) {
        await FulaApiService.instance.createBucket(_metadataBucket);
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
