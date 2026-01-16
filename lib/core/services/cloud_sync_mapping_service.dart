import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';

/// Represents a mapping between a local file and its cloud counterpart
class SyncMapping {
  final String? iosAssetId; // iOS: PhotoKit asset ID (stable across reinstalls)
  final String? localPath; // Android: File path (stable unless user moves files)
  final String remoteKey; // Filename in cloud
  final String bucket; // Cloud bucket
  final String? etag;
  final DateTime uploadedAt;

  SyncMapping({
    this.iosAssetId,
    this.localPath,
    required this.remoteKey,
    required this.bucket,
    this.etag,
    required this.uploadedAt,
  });

  /// Get the primary identifier for this mapping
  String get identifier => iosAssetId ?? localPath ?? remoteKey;

  Map<String, dynamic> toJson() => {
        'iosAssetId': iosAssetId,
        'localPath': localPath,
        'remoteKey': remoteKey,
        'bucket': bucket,
        'etag': etag,
        'uploadedAt': uploadedAt.toIso8601String(),
      };

  factory SyncMapping.fromJson(Map<String, dynamic> json) => SyncMapping(
        iosAssetId: json['iosAssetId'] as String?,
        localPath: json['localPath'] as String?,
        remoteKey: json['remoteKey'] as String,
        bucket: json['bucket'] as String,
        etag: json['etag'] as String?,
        uploadedAt: DateTime.parse(json['uploadedAt'] as String),
      );
}

/// Service for syncing file-to-cloud mappings to cloud storage
///
/// This allows recovery of sync status if local storage is cleared (reinstall).
/// Mappings are stored in cloud as JSON.
///
/// Storage structure:
/// - Bucket: 'fula-metadata'
/// - Key: '.fula/sync-mapping/{userId}.json'
class CloudSyncMappingService {
  static final CloudSyncMappingService instance = CloudSyncMappingService._();
  CloudSyncMappingService._();

  static const String _metadataBucket = 'fula-metadata';
  static const String _mappingPrefix = '.fula/sync-mapping/';

  // In-memory cache of mappings
  final List<SyncMapping> _mappings = [];
  bool _isLoaded = false;

  // Debounce upload to avoid excessive cloud writes
  Timer? _uploadDebounceTimer;
  static const Duration _uploadDebounceDelay = Duration(seconds: 5);

  /// Add a mapping (after successful upload)
  /// This caches locally and schedules a debounced upload to cloud
  Future<void> addMapping(SyncMapping mapping) async {
    // Remove any existing mapping for the same identifier
    _mappings.removeWhere((m) => m.identifier == mapping.identifier);
    _mappings.add(mapping);

    // Schedule debounced upload
    _scheduleUpload();
  }

  /// Remove a mapping (when file is deleted from cloud)
  Future<void> removeMapping(String remoteKey, String bucket) async {
    _mappings.removeWhere((m) => m.remoteKey == remoteKey && m.bucket == bucket);
    _scheduleUpload();
  }

  /// Schedule a debounced upload to cloud
  void _scheduleUpload() {
    _uploadDebounceTimer?.cancel();
    _uploadDebounceTimer = Timer(_uploadDebounceDelay, () {
      _uploadMappings();
    });
  }

  /// Upload mappings to cloud
  Future<void> _uploadMappings() async {
    if (!FulaApiService.instance.isConfigured) {
      debugPrint('CloudSyncMapping: Fula API not configured, skipping upload');
      return;
    }

    final userId = await _getUserId();
    if (userId == null) {
      debugPrint('CloudSyncMapping: User ID not available');
      return;
    }

    try {
      // Convert mappings to JSON
      final mappingsJson = _mappings.map((m) => m.toJson()).toList();
      final jsonString = jsonEncode({
        'version': 1,
        'updatedAt': DateTime.now().toIso8601String(),
        'mappings': mappingsJson,
      });

      // Ensure bucket exists
      await _ensureBucketExists();

      // Upload to cloud
      final key = '$_mappingPrefix$userId.json';
      final data = Uint8List.fromList(utf8.encode(jsonString));
      await FulaApiService.instance.uploadObject(
        _metadataBucket,
        key,
        data,
        contentType: 'application/json',
      );

      debugPrint('CloudSyncMapping: Uploaded ${_mappings.length} mappings to cloud');
    } catch (e) {
      debugPrint('CloudSyncMapping: Failed to upload mappings: $e');
    }
  }

  /// Download mappings from cloud
  Future<List<SyncMapping>> downloadMappings() async {
    if (!FulaApiService.instance.isConfigured) {
      debugPrint('CloudSyncMapping: Fula API not configured');
      return [];
    }

    final userId = await _getUserId();
    if (userId == null) {
      debugPrint('CloudSyncMapping: User ID not available');
      return [];
    }

    try {
      // Ensure bucket exists
      await _ensureBucketExists();

      final key = '$_mappingPrefix$userId.json';

      // Download from cloud
      final data = await FulaApiService.instance.downloadObject(
        _metadataBucket,
        key,
      );

      // Parse JSON
      final jsonString = utf8.decode(data);
      final json = jsonDecode(jsonString) as Map<String, dynamic>;

      final mappingsJson = json['mappings'] as List<dynamic>;
      final mappings = mappingsJson
          .map((m) => SyncMapping.fromJson(m as Map<String, dynamic>))
          .toList();

      debugPrint('CloudSyncMapping: Downloaded ${mappings.length} mappings from cloud');
      return mappings;
    } on FulaApiException catch (e) {
      if (e.message.contains('NoSuchKey') ||
          e.message.contains('NoSuchBucket') ||
          e.message.contains('bucket not found') ||
          e.message.contains('404') ||
          e.message.contains('not found')) {
        debugPrint('CloudSyncMapping: No mappings found in cloud');
        return [];
      }
      debugPrint('CloudSyncMapping: Failed to download mappings: $e');
      rethrow;
    } catch (e) {
      debugPrint('CloudSyncMapping: Failed to download mappings: $e');
      rethrow;
    }
  }

  /// Re-link mappings to local files after reinstall/clear storage
  /// This creates local SyncState entries for files that exist both locally and in cloud
  Future<void> relinkMappings() async {
    debugPrint('CloudSyncMapping: Starting relink process');

    try {
      final mappings = await downloadMappings();
      if (mappings.isEmpty) {
        debugPrint('CloudSyncMapping: No mappings to relink');
        return;
      }

      _mappings.clear();
      _mappings.addAll(mappings);
      _isLoaded = true;

      int linkedCount = 0;

      for (final mapping in mappings) {
        bool linked = false;

        if (Platform.isIOS && mapping.iosAssetId != null) {
          // iOS: Try to find asset by PhotoKit ID
          linked = await _relinkIosAsset(mapping);
        } else if (Platform.isAndroid && mapping.localPath != null) {
          // Android: Check if file still exists at path
          linked = await _relinkAndroidFile(mapping);
        }

        if (linked) {
          linkedCount++;
        }
        // If not linked, file shows as cloud-only (expected for deleted/moved files)
      }

      debugPrint('CloudSyncMapping: Relinked $linkedCount of ${mappings.length} mappings');
    } catch (e) {
      debugPrint('CloudSyncMapping: Relink failed: $e');
    }
  }

  /// Relink an iOS PhotoKit asset
  Future<bool> _relinkIosAsset(SyncMapping mapping) async {
    try {
      final asset = await AssetEntity.fromId(mapping.iosAssetId!);
      if (asset != null) {
        // Asset exists - create sync state
        // For iOS, we use a virtual display path
        final displayPath = 'PhotoKit/${mapping.remoteKey}';

        // Check if sync state already exists
        final existing = LocalStorageService.instance.getSyncStateByIosAssetId(mapping.iosAssetId!);
        if (existing != null) {
          debugPrint('CloudSyncMapping: iOS asset ${mapping.iosAssetId} already has sync state');
          return true;
        }

        // Get the actual file to get localPath
        final file = await asset.file;
        final localPath = file?.path ?? displayPath;

        await LocalStorageService.instance.addSyncState(SyncState(
          localPath: localPath,
          remotePath: '${mapping.bucket}/${mapping.remoteKey}',
          remoteKey: mapping.remoteKey,
          bucket: mapping.bucket,
          status: SyncStatus.synced,
          lastSyncedAt: mapping.uploadedAt,
          etag: mapping.etag,
          displayPath: displayPath,
          iosAssetId: mapping.iosAssetId,
        ));

        debugPrint('CloudSyncMapping: Relinked iOS asset ${mapping.iosAssetId} -> ${mapping.remoteKey}');
        return true;
      }
    } catch (e) {
      debugPrint('CloudSyncMapping: Failed to relink iOS asset ${mapping.iosAssetId}: $e');
    }
    return false;
  }

  /// Relink an Android file
  Future<bool> _relinkAndroidFile(SyncMapping mapping) async {
    try {
      final file = File(mapping.localPath!);
      if (await file.exists()) {
        // File exists - create sync state
        // Check if sync state already exists
        final existing = LocalStorageService.instance.getSyncState(mapping.localPath!);
        if (existing != null) {
          debugPrint('CloudSyncMapping: Android file ${mapping.localPath} already has sync state');
          return true;
        }

        await LocalStorageService.instance.addSyncState(SyncState(
          localPath: mapping.localPath!,
          remotePath: '${mapping.bucket}/${mapping.remoteKey}',
          remoteKey: mapping.remoteKey,
          bucket: mapping.bucket,
          status: SyncStatus.synced,
          lastSyncedAt: mapping.uploadedAt,
          etag: mapping.etag,
        ));

        debugPrint('CloudSyncMapping: Relinked Android file ${mapping.localPath} -> ${mapping.remoteKey}');
        return true;
      }
    } catch (e) {
      debugPrint('CloudSyncMapping: Failed to relink Android file ${mapping.localPath}: $e');
    }
    return false;
  }

  /// Get user ID for storage key
  Future<String?> _getUserId() async {
    final publicKey = await AuthService.instance.getPublicKeyString();
    if (publicKey == null) return null;

    // Use first 16 chars of SHA256 hash of public key as user ID
    final bytes = utf8.encode(publicKey);
    final hash = sha256.convert(bytes);
    return hash.toString().substring(0, 16);
  }

  /// Ensure the metadata bucket exists
  Future<void> _ensureBucketExists() async {
    try {
      final exists = await FulaApiService.instance.bucketExists(_metadataBucket);
      if (!exists) {
        await FulaApiService.instance.createBucket(_metadataBucket);
        debugPrint('CloudSyncMapping: Created metadata bucket');
      }
    } catch (e) {
      debugPrint('CloudSyncMapping: Could not ensure bucket exists: $e');
    }
  }

  /// Clear all cached mappings (for sign out)
  void clear() {
    _mappings.clear();
    _isLoaded = false;
    _uploadDebounceTimer?.cancel();
  }
}

class CloudSyncMappingException implements Exception {
  final String message;
  CloudSyncMappingException(this.message);

  @override
  String toString() => 'CloudSyncMappingException: $message';
}
