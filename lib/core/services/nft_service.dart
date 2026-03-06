import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';

/// Service that manages NFT collections, minting, claiming, and transfer-back.
/// Persists state in Hive and emits updates via a status stream.
class NftService {
  NftService._();
  static final NftService instance = NftService._();

  late Box<NftCollection> _collectionsBox;
  bool _isInitialized = false;

  final _statusController = StreamController<NftMintRecord>.broadcast();
  Stream<NftMintRecord> get statusStream => _statusController.stream;

  static const _uuid = Uuid();
  static const String _assetBucket = 'nft-assets';

  static const String _defaultApiGateway = 'https://s3.cloud.fx.land';
  static const String _defaultIpfsGateway = 'https://ipfs.cloud.fx.land/gateway/';

  // Cloud sync state
  static const String _nftMetadataBucket = 'nft-metadata';
  bool _metaBucketChecked = false;
  bool _metaBucketExists = false;
  bool _syncScheduled = false;
  static const Duration _syncDebounce = Duration(seconds: 5);

  Future<void> init() async {
    if (_isInitialized) return;

    try {
      if (!Hive.isAdapterRegistered(30)) {
        Hive.registerAdapter(NftCollectionAdapter());
      }
      if (!Hive.isAdapterRegistered(31)) {
        Hive.registerAdapter(NftMintRecordAdapter());
      }
      if (!Hive.isAdapterRegistered(32)) {
        Hive.registerAdapter(NftClaimRecordAdapter());
      }
      if (!Hive.isAdapterRegistered(33)) {
        Hive.registerAdapter(NftMintStatusAdapter());
      }
      if (!Hive.isAdapterRegistered(34)) {
        Hive.registerAdapter(NftClaimStatusAdapter());
      }

      _collectionsBox = await Hive.openBox<NftCollection>('nft_collections');
      _isInitialized = true;
      debugPrint('NftService initialized with ${_collectionsBox.length} collections');
    } catch (e) {
      debugPrint('Failed to initialize NftService: $e');
    }
  }

  // ============================================================================
  // COLLECTION CRUD
  // ============================================================================

  /// Get all NFT collections
  List<NftCollection> getAllCollections() {
    if (!_isInitialized) return [];
    return _collectionsBox.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Get a collection by tag ID
  NftCollection? getCollectionByTagId(String tagId) {
    if (!_isInitialized) return null;
    try {
      return _collectionsBox.values.firstWhere((c) => c.tagId == tagId);
    } catch (_) {
      return null;
    }
  }

  /// Create or ensure a collection exists for a tag
  Future<NftCollection> ensureCollection({
    required String tagId,
    required String name,
  }) async {
    if (!_isInitialized) await init();

    final existing = getCollectionByTagId(tagId);
    if (existing != null) return existing;

    final collection = NftCollection(
      id: _uuid.v4(),
      tagId: tagId,
      name: name,
      createdAt: DateTime.now(),
      mints: [],
    );

    await _collectionsBox.put(collection.id, collection);
    return collection;
  }

  /// Delete a collection and its data
  Future<void> deleteCollection(String tagId) async {
    if (!_isInitialized) await init();
    final toRemove = _collectionsBox.values
        .where((c) => c.tagId == tagId)
        .map((c) => c.id)
        .toList();
    for (final id in toRemove) {
      await _collectionsBox.delete(id);
    }
  }

  /// Get mint records for a specific tag
  List<NftMintRecord> getMintsForTag(String tagId) {
    final collection = getCollectionByTagId(tagId);
    if (collection == null) return [];
    return List.from(collection.mints)
      ..sort((a, b) => b.mintedAt.compareTo(a.mintedAt));
  }

  /// Add a mint record to a collection
  Future<void> addMintRecord(String tagId, NftMintRecord record) async {
    if (!_isInitialized) await init();

    final collection = getCollectionByTagId(tagId);
    if (collection == null) return;

    collection.mints = [...collection.mints, record];
    await _collectionsBox.put(collection.id, collection);
    _statusController.add(record);
  }

  /// Update a mint record
  Future<void> updateMintRecord(String tagId, NftMintRecord record) async {
    if (!_isInitialized) await init();

    final collection = getCollectionByTagId(tagId);
    if (collection == null) return;

    final index = collection.mints.indexWhere((m) => m.id == record.id);
    if (index == -1) return;

    final updatedMints = List<NftMintRecord>.from(collection.mints);
    updatedMints[index] = record;
    collection.mints = updatedMints;
    await _collectionsBox.put(collection.id, collection);
    _statusController.add(record);
  }

  // ============================================================================
  // IPFS UPLOAD
  // ============================================================================

  /// Upload an image to IPFS for NFT minting (unencrypted, public)
  Future<({String cid, String gatewayUrl})> uploadNftAsset({
    required String localPath,
    required String fileName,
    required String collectionName,
  }) async {
    final apiGateway = await SecureStorageService.instance
            .read(SecureStorageKeys.apiGatewayUrl) ??
        _defaultApiGateway;
    final jwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);

    if (jwt == null || jwt.isEmpty) {
      throw Exception('No API key configured');
    }

    // Ensure bucket exists
    try {
      await http.put(
        Uri.parse('$apiGateway/$_assetBucket'),
        headers: {'Authorization': 'Bearer $jwt'},
      );
    } catch (e) {
      debugPrint('NFT bucket creation note: $e');
    }

    final sanitizedName = collectionName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final key = '$sanitizedName/$fileName';
    final fileBytes = await File(localPath).readAsBytes();
    final contentType = lookupMimeType(localPath) ?? 'application/octet-stream';

    final response = await http.put(
      Uri.parse('$apiGateway/$_assetBucket/$key'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': contentType,
      },
      body: fileBytes,
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Upload failed (${response.statusCode}): ${response.body}');
    }

    final etag = response.headers['etag'];
    if (etag == null || etag.isEmpty) {
      throw Exception('Upload succeeded but no CID returned');
    }

    final cid = etag.replaceAll('"', '');
    final gatewayUrl = await _buildGatewayUrl(cid);

    return (cid: cid, gatewayUrl: gatewayUrl);
  }

  Future<String> _buildGatewayUrl(String cid) async {
    final gateway = await SecureStorageService.instance
            .read(SecureStorageKeys.ipfsGatewayUrl) ??
        _defaultIpfsGateway;
    final base = gateway.endsWith('/') ? gateway : '$gateway/';
    return '$base$cid';
  }

  // ============================================================================
  // CLOUD SYNC
  // ============================================================================

  void scheduleSyncToCloud() {
    if (_syncScheduled) return;
    _syncScheduled = true;

    Future.delayed(_syncDebounce, () async {
      _syncScheduled = false;
      await syncToCloud();
    });
  }

  Future<void> syncToCloud() async {
    if (_metaBucketChecked && !_metaBucketExists) return;
    if (!FulaApiService.instance.isConfigured) return;

    if (!await _ensureMetadataBucketExists()) return;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;

      final userId = await _getUserId();
      if (userId == null) return;

      final collections = _collectionsBox.values
          .map((c) => c.toJson())
          .toList();

      final jsonStr = jsonEncode({
        'collections': collections,
        'updatedAt': DateTime.now().toIso8601String(),
      });
      final data = Uint8List.fromList(utf8.encode(jsonStr));

      final key = '.fula/nfts/$userId.json';
      await FulaApiService.instance.encryptAndUpload(
        _nftMetadataBucket,
        key,
        data,
        encryptionKey,
        contentType: 'application/json',
      );

      debugPrint('NFT collections synced to cloud: ${collections.length}');
    } catch (e) {
      debugPrint('NftService: syncToCloud error: $e');
    }
  }

  Future<bool> _ensureMetadataBucketExists() async {
    if (_metaBucketChecked && _metaBucketExists) return true;

    try {
      await FulaApiService.instance.createBucket(_nftMetadataBucket);
      _metaBucketExists = true;
      _metaBucketChecked = true;
      return true;
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('BucketAlreadyExists') ||
          errorStr.contains('BucketAlreadyOwnedByYou')) {
        _metaBucketExists = true;
        _metaBucketChecked = true;
        return true;
      }
      _metaBucketExists = false;
      _metaBucketChecked = false;
      return false;
    }
  }

  Future<String?> _getUserId() async {
    try {
      final publicKey = await AuthService.instance.getPublicKeyString();
      if (publicKey == null || publicKey.isEmpty) return null;
      final bytes = utf8.encode(publicKey);
      final hash = sha256.convert(bytes);
      return hash.toString().substring(0, 16);
    } catch (e) {
      return null;
    }
  }

  void dispose() {
    _statusController.close();
  }
}
