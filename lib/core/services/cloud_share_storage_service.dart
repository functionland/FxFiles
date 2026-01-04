import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/encryption_service.dart';
import 'package:fula_files/core/services/auth_service.dart';

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
  static const String _sharesSuffix = '.json.enc';

  /// Upload outgoing shares to cloud
  ///
  /// Shares are encrypted with user's encryption key before upload
  Future<void> uploadShares(List<OutgoingShare> shares) async {
    if (!FulaApiService.instance.isConfigured) {
      debugPrint('CloudShareStorage: Fula API not configured, skipping upload');
      return;
    }

    final encryptionKey = await AuthService.instance.getEncryptionKey();
    if (encryptionKey == null) {
      throw CloudShareStorageException('Encryption key not available');
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

      // Encrypt the JSON
      final plainBytes = Uint8List.fromList(utf8.encode(jsonString));
      final encryptedBytes = await EncryptionService.instance.encrypt(
        plainBytes,
        encryptionKey,
      );

      // Ensure bucket exists
      await _ensureBucketExists();

      // Upload to cloud
      final key = '$_sharesPrefix$userId$_sharesSuffix';
      await FulaApiService.instance.uploadObject(
        _metadataBucket,
        key,
        encryptedBytes,
        metadata: {
          'x-fula-encrypted': 'true',
          'x-fula-content-type': 'application/json',
          'x-fula-share-count': shares.length.toString(),
        },
      );

      debugPrint('CloudShareStorage: Uploaded ${shares.length} shares to cloud');
    } catch (e) {
      debugPrint('CloudShareStorage: Failed to upload shares: $e');
      rethrow;
    }
  }

  /// Download and decrypt shares from cloud
  Future<List<OutgoingShare>> downloadShares() async {
    if (!FulaApiService.instance.isConfigured) {
      debugPrint('CloudShareStorage: Fula API not configured');
      return [];
    }

    final encryptionKey = await AuthService.instance.getEncryptionKey();
    if (encryptionKey == null) {
      debugPrint('CloudShareStorage: Encryption key not available');
      return [];
    }

    final userId = await _getUserId();
    if (userId == null) {
      debugPrint('CloudShareStorage: User ID not available');
      return [];
    }

    try {
      final key = '$_sharesPrefix$userId$_sharesSuffix';

      // Download encrypted data
      final encryptedBytes = await FulaApiService.instance.downloadObject(
        _metadataBucket,
        key,
      );

      // Decrypt
      final decryptedBytes = await EncryptionService.instance.decrypt(
        encryptedBytes,
        encryptionKey,
      );

      // Parse JSON
      final jsonString = utf8.decode(decryptedBytes);
      final json = jsonDecode(jsonString) as Map<String, dynamic>;

      final sharesJson = json['shares'] as List<dynamic>;
      final shares = sharesJson
          .map((s) => OutgoingShare.fromJson(s as Map<String, dynamic>))
          .toList();

      debugPrint('CloudShareStorage: Downloaded ${shares.length} shares from cloud');
      return shares;
    } on FulaApiException catch (e) {
      if (e.message.contains('NoSuchKey') || e.message.contains('404')) {
        // No shares stored yet
        debugPrint('CloudShareStorage: No shares found in cloud');
        return [];
      }
      debugPrint('CloudShareStorage: Failed to download shares: $e');
      rethrow;
    } catch (e) {
      debugPrint('CloudShareStorage: Failed to download shares: $e');
      rethrow;
    }
  }

  /// Sync local shares with cloud
  ///
  /// Merges local and cloud shares, preferring local for conflicts
  Future<List<OutgoingShare>> syncShares(List<OutgoingShare> localShares) async {
    try {
      final cloudShares = await downloadShares();

      // Create a map of cloud shares by ID
      final cloudShareMap = {for (var s in cloudShares) s.id: s};

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

  /// Delete shares from cloud
  Future<void> deleteShares() async {
    if (!FulaApiService.instance.isConfigured) return;

    final userId = await _getUserId();
    if (userId == null) return;

    try {
      final key = '$_sharesPrefix$userId$_sharesSuffix';
      await FulaApiService.instance.deleteObject(_metadataBucket, key);
      debugPrint('CloudShareStorage: Deleted shares from cloud');
    } catch (e) {
      debugPrint('CloudShareStorage: Failed to delete shares: $e');
    }
  }

  /// Get user ID for storage key
  Future<String?> _getUserId() async {
    final publicKey = await AuthService.instance.getPublicKeyString();
    if (publicKey == null) return null;

    // Use first 16 chars of public key hash as user ID
    final hash = await EncryptionService.instance.hashDataAsync(
      Uint8List.fromList(utf8.encode(publicKey)),
    );
    return hash.substring(0, 16).replaceAll('/', '_').replaceAll('+', '-');
  }

  /// Ensure the metadata bucket exists
  Future<void> _ensureBucketExists() async {
    try {
      final exists = await FulaApiService.instance.bucketExists(_metadataBucket);
      if (!exists) {
        await FulaApiService.instance.createBucket(_metadataBucket);
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
