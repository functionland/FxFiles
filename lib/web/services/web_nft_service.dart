import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:uuid/uuid.dart';
import 'package:web3dart/web3dart.dart' show keccak256;

import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/ipfs_gateway_helper.dart';
import 'package:fula_files/core/services/meta_tx_relay_service.dart';
import 'package:fula_files/core/services/nft_contract_service.dart';
import 'package:fula_files/core/services/nft_wallet_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/wallet_service.dart';
import 'package:fula_files/web/services/web_cache_sync.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';
import 'package:fula_files/web/services/web_listing_swr.dart';
import 'package:fula_files/web/services/web_tag_service.dart';

/// Web counterpart of the native NftService — same recipes for the
/// mint / claim-offer / claim flows (it reuses the io-free
/// NftWalletService / NftContractService / MetaTxRelayService
/// directly), with two web substitutions: picked bytes instead of
/// file paths, and the encrypted cloud manifest
/// (`nft-metadata(-v8)/.fula/nfts/{userId}.json`, `{collections,
/// updatedAt}`) instead of the Hive box — the same manifest the app
/// syncs, so collections and mints round-trip between platforms.
///
/// Wallet model (matches the economics): CREATOR-side transactions
/// (approve, mint, claim offers) go through a CONNECTED wallet via
/// Reown AppKit — the same modal stack the app uses, and it must hold
/// the gas + FULA. The internal derived wallet (same address as in the
/// app) is used only for CLAIMING, where the gasless relay / free-gas
/// chains mean the recipient needs no funds.
class WebNftService extends ChangeNotifier {
  WebNftService._();
  static final WebNftService instance = WebNftService._();

  static const String claimLinkHost = 'files.fx.land';
  static const String _assetBucket = 'nft-assets';
  static const String _nftMetadataBucket = 'nft-metadata';
  static const String _defaultApiGateway = 'https://s3.cloud.fx.land';

  static const _uuid = Uuid();

  List<NftCollection> _collections = [];
  bool _loaded = false;
  Future<void>? _loadFuture;

  /// NFTs claimed in THIS browser session (the app keeps received NFTs
  /// device-local too — they are not part of the cloud manifest).
  final List<ReceivedNft> receivedNfts = [];

  List<NftCollection> get collections => List.unmodifiable(_collections);

  NftCollection? collectionByTagId(String tagId) {
    for (final c in _collections) {
      if (c.tagId == tagId) return c;
    }
    return null;
  }

  // ----------------------------------------------------------- manifest

  static Future<Uint8List> _kek() async {
    final b64 = await SecureStorageService.instance
        .read(SecureStorageKeys.encryptionKey);
    if (b64 == null || b64.isEmpty) {
      throw StateError('No session encryption key');
    }
    return Uint8List.fromList(base64Decode(b64));
  }

  Future<String> _manifestKey() async =>
      '.fula/nfts/${await WebTagService.userId()}.json';

  /// Download + additively merge the [v8, legacy] manifests. SWR (P1):
  /// non-forced loads serve the cached blobs instantly (refreshed
  /// behind past the fresh window); force = awaited live read.
  Future<void> load({bool force = false, bool refetchForest = false}) {
    if (_loaded && !force) return Future.value();
    final inFlight = _loadFuture;
    if (inFlight != null) return inFlight;
    final f = _doLoad(force: force, refetchForest: refetchForest)
        .whenComplete(() => _loadFuture = null);
    _loadFuture = f;
    return f;
  }

  Future<void> _doLoad(
      {required bool force, required bool refetchForest}) async {
    final kek = await _kek();
    final key = await _manifestKey();
    final byId = <String, NftCollection>{};
    for (final blob in await WebListingSwr.instance
        .downloadMetadataMergedSwr(_nftMetadataBucket, key, kek,
            force: force, refetchForest: refetchForest)) {
      try {
        final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
        for (final raw in (j['collections'] as List<dynamic>? ?? const [])) {
          try {
            final c = NftCollection.fromJson(raw as Map<String, dynamic>);
            byId.putIfAbsent(c.id, () => c);
          } catch (e) {
            debugPrint('WebNftService: collection entry skipped: $e');
          }
        }
      } catch (e) {
        debugPrint('WebNftService: manifest blob skipped: $e');
      }
    }
    _collections = byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _loaded = true;
    notifyListeners();
  }

  /// Merge-before-overwrite manifest upload (local collections win
  /// their ids; foreign ids from the cloud are preserved).
  Future<void> _upload() async {
    try {
      final kek = await _kek();
      final key = await _manifestKey();
      final byId = <String, Map<String, dynamic>>{};
      for (final blob in await FulaApiService.instance
          .downloadMetadataMerged(_nftMetadataBucket, key, kek)) {
        try {
          final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
          for (final raw
              in (j['collections'] as List<dynamic>? ?? const [])) {
            final m = raw as Map<String, dynamic>;
            final id = m['id'] as String?;
            if (id != null) byId.putIfAbsent(id, () => m);
          }
        } catch (_) {}
      }
      for (final c in _collections) {
        byId[c.id] = c.toJson();
      }
      final writeBucket =
          BucketVersionResolver.writeBucket(_nftMetadataBucket);
      try {
        await FulaApiService.instance.createBucket(writeBucket);
      } catch (_) {}
      final data = Uint8List.fromList(utf8.encode(jsonEncode({
        'collections': byId.values.toList(),
        'updatedAt': DateTime.now().toIso8601String(),
      })));
      await FulaApiService.instance.encryptAndUpload(
        writeBucket,
        key,
        data,
        kek,
        contentType: 'application/json',
      );
      // Write-through so the next SWR read serves this manifest.
      await WebListingCache.instance.writeManifest(writeBucket, key, data);
      WebCacheSync.instance.sendInvalidateManifest(writeBucket, key);
      debugPrint('WebNftService: manifest synced (${byId.length})');
    } catch (e) {
      debugPrint('WebNftService: manifest sync failed (non-fatal): $e');
    }
  }

  // --------------------------------------------------------- collections

  /// Create an NFT collection: an `nft-` prefixed tag (native model)
  /// plus its manifest record.
  Future<NftCollection> createCollection(String name) async {
    final tag = await WebTagService.instance.createTag(
      name: 'nft-$name',
      colorValue: TagColors.getRandomColor(),
    );
    return ensureCollection(tagId: tag.id, name: name);
  }

  Future<NftCollection> ensureCollection({
    required String tagId,
    required String name,
  }) async {
    await load();
    final existing = collectionByTagId(tagId);
    if (existing != null) return existing;
    final collection = NftCollection(
      id: _uuid.v4(),
      tagId: tagId,
      name: name,
      createdAt: DateTime.now(),
      mints: [],
      creatorWalletAddress: WalletService.instance.connectedAddress ??
          await NftWalletService.instance.getAddress(),
    );
    _collections = [collection, ..._collections];
    notifyListeners();
    await _upload();
    return collection;
  }

  void _putMint(NftCollection collection, NftMintRecord record) {
    final idx = collection.mints.indexWhere((m) => m.id == record.id);
    if (idx == -1) {
      collection.mints = [...collection.mints, record];
    } else {
      final mints = List<NftMintRecord>.from(collection.mints);
      mints[idx] = record;
      collection.mints = mints;
    }
    notifyListeners();
  }

  // ------------------------------------------------------------- wallet

  Future<String> internalWalletAddress() async {
    final address = await NftWalletService.instance.getAddress();
    if (address == null) {
      throw Exception('Internal wallet not available — sign in first');
    }
    return address;
  }

  /// The connected (external) wallet address — creator-side
  /// transactions require it.
  String connectedWalletAddress() {
    final address = WalletService.instance.connectedAddress;
    if (address == null) {
      throw Exception('Connect a wallet first to mint NFTs');
    }
    return address;
  }

  Future<void> _ensureCorrectChain(SupportedChain chain) async {
    try {
      await WalletService.instance.switchChain(chain.chainId);
    } catch (e) {
      debugPrint('WebNftService: chain switch note: $e');
      // Non-fatal — the wallet may already be on the correct chain.
    }
  }

  /// ERC20 balanceOf via eth_call (the native path goes through the
  /// AppKit-tainted WalletService; this is the same 4-byte call).
  Future<BigInt> erc20BalanceOf({
    required SupportedChain chain,
    required String tokenAddress,
    required String walletAddress,
  }) async {
    const selector = '70a08231';
    final addr =
        walletAddress.toLowerCase().replaceFirst('0x', '').padLeft(64, '0');
    final result = await NftContractService.instance.ethCall(
      chainId: chain.chainId,
      contractAddress: tokenAddress,
      data: '0x$selector$addr',
    );
    final hex = result.replaceFirst('0x', '');
    if (hex.isEmpty) return BigInt.zero;
    return BigInt.parse(hex, radix: 16);
  }

  /// Same FULA→wei parsing as the native service (string amounts, 18
  /// decimals, fraction truncated).
  static BigInt parseToWei(String amount) {
    final trimmed = amount.trim();
    if (trimmed.isEmpty) return BigInt.zero;
    final parts = trimmed.split('.');
    final wholePart = parts[0].isEmpty ? '0' : parts[0];
    final fracPart = parts.length > 1 ? parts[1] : '';
    final paddedFrac = fracPart.length > 18
        ? fracPart.substring(0, 18)
        : fracPart.padRight(18, '0');
    return BigInt.parse('$wholePart$paddedFrac');
  }

  static String secretToClaimKey(String secret) {
    final hex = secret.replaceFirst('0x', '');
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    final keyBytes = keccak256(bytes);
    return '0x${keyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  static String buildClaimLink({
    required int chainId,
    required String contractAddress,
    required int tokenId,
    required String secret,
  }) {
    return 'https://$claimLinkHost/nft-claim?chain=$chainId&contract=$contractAddress&token=$tokenId#secret=$secret';
  }

  // -------------------------------------------------------------- upload

  Future<String> _jwt() async {
    final jwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    if (jwt == null || jwt.isEmpty) {
      throw Exception('No API key configured');
    }
    return jwt;
  }

  Future<String> _apiGateway() async =>
      await SecureStorageService.instance
          .read(SecureStorageKeys.apiGatewayUrl) ??
      _defaultApiGateway;

  /// Upload the NFT image unencrypted (public) — bytes variant of the
  /// native uploadNftAsset.
  Future<({String cid, String gatewayUrl})> _uploadNftAsset({
    required Uint8List bytes,
    required String fileName,
    required String collectionName,
  }) async {
    final apiGateway = await _apiGateway();
    final jwt = await _jwt();
    try {
      await http.put(
        Uri.parse('$apiGateway/$_assetBucket'),
        headers: {'Authorization': 'Bearer $jwt'},
      );
    } catch (e) {
      debugPrint('NFT bucket creation note: $e');
    }

    final sanitizedName =
        collectionName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final key = '$sanitizedName/$fileName';
    final contentType =
        lookupMimeType(fileName) ?? 'application/octet-stream';

    final response = await http.put(
      Uri.parse('$apiGateway/$_assetBucket/$key'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': contentType,
      },
      body: bytes,
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
          'Upload failed (${response.statusCode}): ${response.body}');
    }
    final etag = response.headers['etag'];
    if (etag == null || etag.isEmpty) {
      throw Exception('Upload succeeded but no CID returned');
    }
    final cid = etag.replaceAll('"', '');
    return (cid: cid, gatewayUrl: IpfsGatewayHelper.buildUrlForCid(cid));
  }

  /// ERC1155 metadata JSON wrapper (same schema as native).
  Future<String> _uploadMetadataJson({
    required String imageCid,
    required String name,
    required String description,
    required String collectionName,
  }) async {
    final apiGateway = await _apiGateway();
    final jwt = await _jwt();
    final gatewayUrl = IpfsGatewayHelper.buildUrlForCid(imageCid);
    final metadata = jsonEncode({
      'name': name,
      'description': description,
      'image': gatewayUrl,
      'properties': {
        'imageCid': imageCid,
        'collection': collectionName,
      },
    });
    final sanitizedName =
        collectionName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final key =
        '$sanitizedName/metadata_${DateTime.now().millisecondsSinceEpoch}.json';
    final response = await http.put(
      Uri.parse('$apiGateway/$_assetBucket/$key'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': 'application/json',
      },
      body: metadata,
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Metadata upload failed (${response.statusCode})');
    }
    final etag = response.headers['etag'];
    if (etag == null || etag.isEmpty) {
      throw Exception('Metadata upload succeeded but no CID returned');
    }
    return etag.replaceAll('"', '');
  }

  // ---------------------------------------------------------------- mint

  /// Full mint flow (CONNECTED wallet): upload image → metadata →
  /// approve FULA → mintWithFula → poll → parse tokenId. Mirrors the
  /// native startMint external-wallet path step-for-step.
  Future<NftMintRecord> startMint({
    required String tagId,
    required Uint8List bytes,
    required String fileName,
    required String collectionName,
    required SupportedChain chain,
    required int count,
    required String fulaPerNft,
    required String eventName,
    int royaltyBps = 0,
    void Function(String status)? onStatus,
  }) async {
    final nftContractAddress = chain.nftContractAddress;
    if (nftContractAddress == null ||
        nftContractAddress == '0x0000000000000000000000000000000000000000') {
      throw Exception('NFT contract not yet deployed on ${chain.chainName}');
    }

    final collection =
        await ensureCollection(tagId: tagId, name: collectionName);
    final creatorAddress = connectedWalletAddress();
    final contract = NftContractService.instance;

    await _ensureCorrectChain(chain);

    final fulaPerNftBigInt = parseToWei(fulaPerNft);
    final totalFula = fulaPerNftBigInt * BigInt.from(count);

    if (totalFula > BigInt.zero) {
      final balance = await erc20BalanceOf(
        chain: chain,
        tokenAddress: chain.tokenAddress,
        walletAddress: creatorAddress,
      );
      if (balance < totalFula) {
        final required = (totalFula / BigInt.from(10).pow(18)).toString();
        final available = (balance / BigInt.from(10).pow(18)).toString();
        throw Exception(
          'Insufficient FULA balance. Required: $required, Available: $available',
        );
      }
    }

    final recordId = _uuid.v4();
    var record = NftMintRecord(
      id: recordId,
      ipfsCid: '',
      count: count,
      fulaPerNft: fulaPerNft,
      chainId: chain.chainId,
      creatorAddress: creatorAddress,
      mintedAt: DateTime.now(),
      status: NftMintStatus.approving,
      eventName: eventName,
      royaltyBps: royaltyBps,
    );
    _putMint(collection, record);

    try {
      onStatus?.call('Uploading asset...');
      final upload = await _uploadNftAsset(
        bytes: bytes,
        fileName: fileName,
        collectionName: collectionName,
      );
      record = NftMintRecord(
        id: recordId,
        ipfsCid: upload.cid,
        gatewayUrl: upload.gatewayUrl,
        count: count,
        fulaPerNft: fulaPerNft,
        chainId: chain.chainId,
        creatorAddress: creatorAddress,
        mintedAt: record.mintedAt,
        status: NftMintStatus.approving,
        eventName: eventName,
        royaltyBps: royaltyBps,
      );
      _putMint(collection, record);

      onStatus?.call('Preparing metadata...');
      final metadataCid = await _uploadMetadataJson(
        imageCid: upload.cid,
        name: collectionName,
        description: 'NFT minted via FxFiles',
        collectionName: collectionName,
      );
      record.metadataCid = metadataCid;
      _putMint(collection, record);

      if (totalFula > BigInt.zero) {
        onStatus?.call('Approve FULA in your wallet...');
        final approveData =
            contract.encodeApprove(nftContractAddress, totalFula);
        final approvalTxHash =
            await WalletService.instance.sendContractTransaction(
          chain: chain,
          contractAddress: chain.tokenAddress,
          encodedData: approveData,
        );
        record.approvalTxHash = approvalTxHash;
        _putMint(collection, record);

        onStatus?.call('Waiting for approval confirmation...');
        await contract.pollForReceipt(
          chainId: chain.chainId,
          txHash: approvalTxHash,
        );
      }

      record.status = NftMintStatus.minting;
      _putMint(collection, record);

      onStatus?.call('Confirm mint in your wallet...');
      final mintData = contract.encodeMintWithFula(
        eventName,
        metadataCid,
        fulaPerNftBigInt,
        count,
        royaltyBps: royaltyBps,
      );
      final mintTxHash =
          await WalletService.instance.sendContractTransaction(
        chain: chain,
        contractAddress: nftContractAddress,
        encodedData: mintData,
      );
      record.txHash = mintTxHash;
      record.status = NftMintStatus.confirming;
      _putMint(collection, record);

      onStatus?.call('Waiting for mint confirmation...');
      final receipt = await contract.pollForReceipt(
        chainId: chain.chainId,
        txHash: mintTxHash,
      );
      final tokenId = contract.parseTokenIdFromReceipt(receipt);
      if (tokenId == null) {
        throw Exception(
            'Mint transaction succeeded but could not parse token ID from receipt');
      }
      record.tokenId = tokenId;
      record.status = NftMintStatus.completed;
      _putMint(collection, record);
      await _upload();
      return record;
    } catch (e) {
      record.status = NftMintStatus.error;
      record.errorMessage = e.toString();
      _putMint(collection, record);
      await _upload();
      rethrow;
    }
  }

  // -------------------------------------------------------- claim offers

  /// Create an on-chain claim offer + shareable link (internal wallet).
  Future<({String claimLink, NftClaimRecord record})> createClaimOffer({
    required String tagId,
    required NftMintRecord mint,
    required Duration expiry,
    String? claimerAddress,
  }) async {
    final chain = SupportedChain.byChainId(mint.chainId);
    if (chain == null) throw Exception('Unknown chain: ${mint.chainId}');
    final nftContractAddress = chain.nftContractAddress;
    if (nftContractAddress == null ||
        nftContractAddress == '0x0000000000000000000000000000000000000000') {
      throw Exception('NFT contract not deployed on ${chain.chainName}');
    }
    final collection = collectionByTagId(tagId);
    if (collection == null) throw Exception('Collection not found');
    final tokenId = mint.tokenId;
    if (tokenId == null) throw Exception('Mint has no token ID');

    // Creator-side tx — needs the connected wallet (it escrows the NFT).
    connectedWalletAddress();
    await _ensureCorrectChain(chain);
    final contract = NftContractService.instance;

    final expiresAt = BigInt.from(
        DateTime.now().add(expiry).millisecondsSinceEpoch ~/ 1000);

    final rng = Random.secure();
    final secretBytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      secretBytes[i] = rng.nextInt(256);
    }
    final secret =
        '0x${secretBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    final claimKeyBytes = keccak256(secretBytes);
    final claimKey =
        '0x${claimKeyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

    final data = contract.encodeCreateClaimOffer(
        tokenId, claimerAddress, expiresAt, claimKey);
    final txHash = await WalletService.instance.sendContractTransaction(
      chain: chain,
      contractAddress: nftContractAddress,
      encodedData: data,
    );
    await contract.pollForReceipt(chainId: chain.chainId, txHash: txHash);

    final claimLink = buildClaimLink(
      chainId: chain.chainId,
      contractAddress: nftContractAddress,
      tokenId: tokenId,
      secret: secret,
    );
    final claimRecord = NftClaimRecord(
      id: _uuid.v4(),
      tokenId: tokenId,
      linkHash: secret,
      claimerAddress: claimerAddress,
      chainId: chain.chainId,
      createdAt: DateTime.now(),
      expiresAt: DateTime.now().add(expiry),
      status: NftClaimStatus.pending,
      claimTxHash: null,
    );
    mint.claims = [...mint.claims, claimRecord];
    _putMint(collection, mint);
    await _upload();
    return (claimLink: claimLink, record: claimRecord);
  }

  // --------------------------------------------------------------- claim

  Future<({int tokenId, int status, int expiresAt, String? claimerAddress})?>
      fetchClaimOffer(int chainId, String contractAddress, String claimKey) async {
    final contract = NftContractService.instance;
    try {
      final result = await contract.ethCall(
        chainId: chainId,
        contractAddress: contractAddress,
        data: contract.encodeGetClaimOffer(claimKey),
      );
      return contract.decodeClaimOffer(result);
    } catch (e) {
      debugPrint('WebNftService: fetchClaimOffer error: $e');
      return null;
    }
  }

  Future<({String creator, String metadataCid, String eventName, BigInt fulaPerNft, int initialMintCount})?>
      fetchTokenInfo(int chainId, int tokenId) async {
    final chain = SupportedChain.byChainId(chainId);
    final address = chain?.nftContractAddress;
    if (address == null) return null;
    final contract = NftContractService.instance;
    try {
      final result = await contract.ethCall(
        chainId: chainId,
        contractAddress: address,
        data: contract.encodeGetTokenInfo(tokenId),
      );
      return contract.decodeTokenInfo(result);
    } catch (e) {
      debugPrint('WebNftService: fetchTokenInfo error: $e');
      return null;
    }
  }

  /// Resolve the image URL from a metadata CID (same fallbacks as
  /// native resolveImageUrl).
  Future<String?> resolveImageUrl(String metadataCid) async {
    if (metadataCid.isEmpty) return null;
    try {
      final metadataUrl = IpfsGatewayHelper.buildUrlForCid(metadataCid);
      final response = await http
          .get(Uri.parse(metadataUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final image = json['image'] as String?;
        if (image != null && image.isNotEmpty) return image;
        final props = json['properties'] as Map<String, dynamic>?;
        final imageCid = props?['imageCid'] as String?;
        if (imageCid != null && imageCid.isNotEmpty) {
          return IpfsGatewayHelper.buildUrlForCid(imageCid);
        }
      }
    } catch (e) {
      debugPrint('WebNftService: resolveImageUrl error: $e');
    }
    return null;
  }

  /// Claim an NFT with the internal wallet (gasless relay when
  /// available, direct tx otherwise) — mirror of the native claimNft
  /// internal-wallet path, including its user-facing error mapping.
  Future<String> claimNft({
    required int chainId,
    required String secret,
  }) async {
    final chain = SupportedChain.byChainId(chainId);
    if (chain == null) throw Exception('Unknown chain: $chainId');
    final nftContractAddress = chain.nftContractAddress;
    if (nftContractAddress == null ||
        nftContractAddress == '0x0000000000000000000000000000000000000000') {
      throw Exception('NFT contract not deployed on ${chain.chainName}');
    }

    final claimKey = secretToClaimKey(secret);
    final address = await internalWalletAddress();
    final contract = NftContractService.instance;

    // Pre-check offer status (same semantics as native).
    try {
      final offerInfo =
          await fetchClaimOffer(chainId, nftContractAddress, claimKey);
      if (offerInfo != null) {
        if (offerInfo.status == 1) {
          throw Exception('This NFT has already been claimed');
        }
        if (offerInfo.status == 2) {
          throw Exception('This claim offer was cancelled');
        }
        if (offerInfo.expiresAt > 0 &&
            DateTime.now().millisecondsSinceEpoch ~/ 1000 >=
                offerInfo.expiresAt) {
          throw Exception('This claim link has expired');
        }
        final designated = offerInfo.claimerAddress;
        if (designated != null &&
            designated !=
                '0x0000000000000000000000000000000000000000' &&
            designated.toLowerCase() != address.toLowerCase()) {
          throw Exception('Your wallet is not the designated claimer');
        }
      }
    } catch (e) {
      final s = e.toString();
      if (s.contains('already been claimed') ||
          s.contains('expired') ||
          s.contains('cancelled') ||
          s.contains('designated claimer')) {
        rethrow;
      }
      debugPrint('WebNftService: could not verify claim status: $e');
    }

    // Gasless relay path.
    if (chain.supportsGaslessRelay) {
      var useRelay = chain.freeGas;
      if (!useRelay) {
        final gasDeposit = await MetaTxRelayService.instance.getGasDeposit(
          chainId: chain.chainId,
          linkHash: claimKey,
        );
        useRelay = gasDeposit > BigInt.zero;
      }
      if (useRelay) {
        return _claimViaMeta(
            chain: chain, secret: secret, claimKey: claimKey);
      }
    }

    // Direct on-chain claim.
    final data = contract.encodeClaimNft(secret);
    String txHash;
    try {
      txHash = await NftWalletService.instance.sendSignedTransaction(
        chain: chain,
        to: nftContractAddress,
        encodedData: data,
      );
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('already claimed') || msg.contains('alreadyclaimed')) {
        throw Exception('This NFT has already been claimed');
      }
      if (msg.contains('expired') || msg.contains('claimexpired')) {
        throw Exception('This claim link has expired');
      }
      if (msg.contains('not claim recipient') ||
          msg.contains('notclaimrecipient')) {
        throw Exception('Your wallet is not the designated claimer');
      }
      rethrow;
    }
    try {
      await contract.pollForReceipt(
          chainId: chain.chainId, txHash: txHash);
    } catch (e) {
      if (e.toString().contains('reverted')) {
        throw Exception(
            'Claim transaction failed. The link may have expired or already been claimed.');
      }
      rethrow;
    }
    return txHash;
  }

  Future<String> _claimViaMeta({
    required SupportedChain chain,
    required String secret,
    required String claimKey,
  }) async {
    final relay = MetaTxRelayService.instance;
    final wallet = NftWalletService.instance;
    final address = await wallet.getAddress();
    if (address == null) throw Exception('Internal wallet not available');

    final nonce =
        await relay.getMetaNonce(chainId: chain.chainId, address: address);
    final deadline = DateTime.now()
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch ~/
        1000;
    final sig = await wallet.signClaimNftMeta(
      claimKey: claimKey,
      claimer: address,
      deadline: deadline,
      nonce: nonce,
      chainId: chain.chainId,
      contractAddress: chain.nftContractAddress!,
    );
    final txHash = await relay.relay(
      action: 'claimNFT',
      chainId: chain.chainId,
      secret: secret,
      claimKey: claimKey,
      signer: address,
      deadline: deadline,
      nonce: nonce,
      signature: sig,
    );
    await NftContractService.instance
        .pollForReceipt(chainId: chain.chainId, txHash: txHash);
    return txHash;
  }

  /// Record a claim done in this session (Received tab).
  Future<ReceivedNft> recordClaimed({
    required int chainId,
    required String contractAddress,
    required int tokenId,
    required String claimTxHash,
    required String secret,
  }) async {
    final info = await fetchTokenInfo(chainId, tokenId);
    String? gatewayUrl;
    if (info != null && info.metadataCid.isNotEmpty) {
      gatewayUrl = await resolveImageUrl(info.metadataCid);
    }
    final nft = ReceivedNft(
      id: _uuid.v4(),
      tokenId: tokenId,
      chainId: chainId,
      contractAddress: contractAddress,
      eventName: info?.eventName ?? '',
      fulaPerNft: info != null
          ? (info.fulaPerNft / BigInt.from(10).pow(18)).toString()
          : '0',
      creator: info?.creator ?? '',
      claimTxHash: claimTxHash,
      claimedAt: DateTime.now(),
      gatewayUrl: gatewayUrl,
      status: ReceivedNftStatus.held,
      claimLinkHash: secret,
    );
    receivedNfts.insert(0, nft);
    notifyListeners();
    return nft;
  }
}
