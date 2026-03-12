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

import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/nft_contract_service.dart';
import 'package:fula_files/core/services/nft_wallet_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/wallet_service.dart';

/// Whether to use the internal (derived) wallet or an external (AppKit) wallet.
enum WalletSource { internal, external }

/// Service that manages NFT collections, minting, claiming, burning, and transfers.
/// Persists state in Hive and emits updates via a status stream.
class NftService {
  NftService._();
  static final NftService instance = NftService._();

  /// HTTPS domain for shareable claim links.
  static const String claimLinkHost = 'files.fx.land';

  /// Build a shareable HTTPS claim link.
  static String buildClaimLink({
    required int chainId,
    required String contractAddress,
    required int tokenId,
    required String linkHash,
  }) {
    return 'https://$claimLinkHost/nft-claim?chain=$chainId&contract=$contractAddress&token=$tokenId&hash=$linkHash';
  }

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

  /// Upload an ERC1155-compliant metadata JSON to S3, returns the metadata CID.
  Future<String> _uploadMetadataJson({
    required String imageCid,
    required String name,
    required String description,
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

    final gatewayUrl = await _buildGatewayUrl(imageCid);
    final metadata = jsonEncode({
      'name': name,
      'description': description,
      'image': gatewayUrl,
      'properties': {
        'imageCid': imageCid,
        'collection': collectionName,
      },
    });

    final sanitizedName = collectionName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final key = '$sanitizedName/metadata_${DateTime.now().millisecondsSinceEpoch}.json';

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

  // ============================================================================
  // MINTING FLOW
  // ============================================================================

  /// Full mint flow: upload asset → upload metadata JSON → approve FULA → mint → poll → parse tokenId
  Future<NftMintRecord> startMint({
    required String tagId,
    required String localPath,
    required String fileName,
    required String collectionName,
    required SupportedChain chain,
    required int count,
    required String fulaPerNft,
    required String eventName,
    WalletSource walletSource = WalletSource.external,
  }) async {
    final nftContractAddress = chain.nftContractAddress;
    if (nftContractAddress == null ||
        nftContractAddress == '0x0000000000000000000000000000000000000000') {
      throw Exception('NFT contract not yet deployed on ${chain.chainName}');
    }

    final creatorAddress = await _getWalletAddress(walletSource);
    final contract = NftContractService.instance;

    // Ensure wallet is on the correct chain (external wallet only)
    if (walletSource == WalletSource.external) {
      await _ensureCorrectChain(chain);
    }

    // Parse fulaPerNft to BigInt (in token units, 18 decimals)
    final fulaPerNftBigInt = _parseToWei(fulaPerNft);
    final totalFula = fulaPerNftBigInt * BigInt.from(count);

    // Check FULA balance before proceeding
    if (totalFula > BigInt.zero) {
      final BigInt balance;
      if (walletSource == WalletSource.external) {
        balance = await WalletService.instance.getFulaBalance(chain);
      } else {
        balance = await WalletService.instance.getErc20Balance(
          chain: chain,
          tokenAddress: chain.tokenAddress,
          walletAddress: creatorAddress,
        );
      }
      if (balance < totalFula) {
        final required = (totalFula / BigInt.from(10).pow(18)).toString();
        final available = (balance / BigInt.from(10).pow(18)).toString();
        throw Exception(
          'Insufficient FULA balance. Required: $required, Available: $available',
        );
      }
    }

    // Create initial record
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
    );
    await addMintRecord(tagId, record);

    try {
      // Step 1: Upload asset to IPFS
      debugPrint('NftService: Uploading asset to IPFS...');
      final upload = await uploadNftAsset(
        localPath: localPath,
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
      );
      await updateMintRecord(tagId, record);

      // Step 2: Upload metadata JSON wrapper (ERC1155-compliant)
      debugPrint('NftService: Uploading metadata JSON...');
      final metadataCid = await _uploadMetadataJson(
        imageCid: upload.cid,
        name: collectionName,
        description: 'NFT minted via FxFiles',
        collectionName: collectionName,
      );
      record.metadataCid = metadataCid;
      await updateMintRecord(tagId, record);

      // Step 3: Approve FULA spend on the token contract
      if (totalFula > BigInt.zero) {
        debugPrint('NftService: Approving FULA spend: $totalFula');
        String approvalTxHash;
        if (walletSource == WalletSource.internal) {
          approvalTxHash = await NftWalletService.instance.sendApproveTransaction(
            chain: chain,
            tokenAddress: chain.tokenAddress,
            spender: nftContractAddress,
            amount: totalFula,
          );
        } else {
          final approveData = contract.encodeApprove(nftContractAddress, totalFula);
          approvalTxHash = await WalletService.instance.sendContractTransaction(
            chain: chain,
            contractAddress: chain.tokenAddress,
            encodedData: approveData,
          );
        }

        record.approvalTxHash = approvalTxHash;
        await updateMintRecord(tagId, record);

        // Poll for approval receipt
        debugPrint('NftService: Waiting for approval tx: $approvalTxHash');
        await contract.pollForReceipt(
          chainId: chain.chainId,
          txHash: approvalTxHash,
        );
      }

      // Step 3: Call mintWithFula on NFT contract
      record.status = NftMintStatus.minting;
      await updateMintRecord(tagId, record);

      debugPrint('NftService: Calling mintWithFula...');
      final mintData = contract.encodeMintWithFula(
        eventName,
        metadataCid,
        fulaPerNftBigInt,
        count,
      );
      final mintTxHash = await _sendTransaction(
        chain: chain,
        contractAddress: nftContractAddress,
        encodedData: mintData,
        walletSource: walletSource,
      );

      record.txHash = mintTxHash;
      record.status = NftMintStatus.confirming;
      await updateMintRecord(tagId, record);

      // Step 4: Poll for mint receipt
      debugPrint('NftService: Waiting for mint tx: $mintTxHash');
      final receipt = await contract.pollForReceipt(
        chainId: chain.chainId,
        txHash: mintTxHash,
      );

      // Step 5: Parse tokenId from receipt
      final tokenId = contract.parseTokenIdFromReceipt(receipt);
      if (tokenId == null) {
        throw Exception('Mint transaction succeeded but could not parse token ID from receipt');
      }
      record.tokenId = tokenId;
      record.status = NftMintStatus.completed;
      await updateMintRecord(tagId, record);

      debugPrint('NftService: Mint complete! Token ID: $tokenId');
      scheduleSyncToCloud();

      return record;
    } catch (e) {
      debugPrint('NftService: Mint error: $e');
      record.status = NftMintStatus.error;
      record.errorMessage = e.toString();
      await updateMintRecord(tagId, record);
      rethrow;
    }
  }

  // ============================================================================
  // CLAIM OFFER FLOW
  // ============================================================================

  /// Create a claim offer on-chain and return the claim link.
  /// If [claimerAddress] is null, creates an open claim (anyone can claim).
  Future<({String linkHash, String claimLink, NftClaimRecord record})> createClaimOffer({
    required String tagId,
    required NftMintRecord mint,
    String? claimerAddress,
    required Duration expiry,
    WalletSource walletSource = WalletSource.external,
  }) async {
    final chain = SupportedChain.byChainId(mint.chainId);
    if (chain == null) throw Exception('Unknown chain: ${mint.chainId}');

    final nftContractAddress = chain.nftContractAddress;
    if (nftContractAddress == null ||
        nftContractAddress == '0x0000000000000000000000000000000000000000') {
      throw Exception('NFT contract not deployed on ${chain.chainName}');
    }

    // Validate wallet availability
    await _getWalletAddress(walletSource);

    final contract = NftContractService.instance;
    final tokenId = mint.tokenId;
    if (tokenId == null) throw Exception('Mint has no token ID');

    final expiresAt = BigInt.from(
      DateTime.now().add(expiry).millisecondsSinceEpoch ~/ 1000,
    );

    // Send createClaimOffer tx
    debugPrint('NftService: Creating claim offer for token $tokenId...');
    final data = contract.encodeCreateClaimOffer(tokenId, claimerAddress, expiresAt);
    final txHash = await _sendTransaction(
      chain: chain,
      contractAddress: nftContractAddress,
      encodedData: data,
      walletSource: walletSource,
    );

    // Poll for receipt
    debugPrint('NftService: Waiting for claim offer tx: $txHash');
    final receipt = await contract.pollForReceipt(
      chainId: chain.chainId,
      txHash: txHash,
    );

    // Parse linkHash from event
    final linkHash = contract.parseClaimOfferHash(receipt);
    if (linkHash == null) {
      throw Exception('Failed to parse claim offer linkHash from receipt');
    }

    // Build shareable HTTPS claim link
    final claimLink = buildClaimLink(
      chainId: chain.chainId,
      contractAddress: nftContractAddress,
      tokenId: tokenId,
      linkHash: linkHash,
    );

    // Save claim record
    final claimRecord = NftClaimRecord(
      id: _uuid.v4(),
      tokenId: tokenId,
      linkHash: linkHash,
      claimerAddress: claimerAddress,
      chainId: chain.chainId,
      createdAt: DateTime.now(),
      expiresAt: DateTime.now().add(expiry),
      status: NftClaimStatus.pending,
      claimTxHash: null,
    );

    // Add to mint's claims list
    mint.claims = [...mint.claims, claimRecord];
    await updateMintRecord(tagId, mint);

    debugPrint('NftService: Claim offer created: $linkHash');
    scheduleSyncToCloud();

    return (linkHash: linkHash, claimLink: claimLink, record: claimRecord);
  }

  /// Claim an NFT using the specified wallet source.
  Future<String> claimNft({
    required int chainId,
    required String linkHash,
    WalletSource walletSource = WalletSource.external,
  }) async {
    final chain = SupportedChain.byChainId(chainId);
    if (chain == null) throw Exception('Unknown chain: $chainId');

    final nftContractAddress = chain.nftContractAddress;
    if (nftContractAddress == null ||
        nftContractAddress == '0x0000000000000000000000000000000000000000') {
      throw Exception('NFT contract not deployed on ${chain.chainName}');
    }

    // Validate wallet availability
    await _getWalletAddress(walletSource);

    // Ensure wallet is on the correct chain (external wallet only)
    if (walletSource == WalletSource.external) {
      await _ensureCorrectChain(chain);
    }

    // Check claim expiry on-chain before attempting
    try {
      final offerInfo = await _fetchClaimOffer(chainId, nftContractAddress, linkHash);
      if (offerInfo != null) {
        if (offerInfo.status == 1) {
          throw Exception('This NFT has already been claimed');
        }
        if (offerInfo.status == 2) {
          throw Exception('This claim offer was cancelled');
        }
        if (offerInfo.expiresAt > 0 &&
            DateTime.now().millisecondsSinceEpoch ~/ 1000 >= offerInfo.expiresAt) {
          throw Exception('This claim link has expired');
        }
      }
    } catch (e) {
      if (e.toString().contains('already been claimed') ||
          e.toString().contains('expired') ||
          e.toString().contains('cancelled')) {
        rethrow;
      }
      // Non-fatal: proceed anyway if we can't check
      debugPrint('NftService: Could not verify claim status: $e');
    }

    final contract = NftContractService.instance;

    // Send claimNFT tx
    debugPrint('NftService: Claiming NFT with linkHash: $linkHash');
    final data = contract.encodeClaimNft(linkHash);

    String txHash;
    try {
      txHash = await _sendTransaction(
        chain: chain,
        contractAddress: nftContractAddress,
        encodedData: data,
        walletSource: walletSource,
      );
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('already claimed') || msg.contains('alreadyclaimed')) {
        throw Exception('This NFT has already been claimed');
      }
      if (msg.contains('expired') || msg.contains('claimexpired')) {
        throw Exception('This claim link has expired');
      }
      if (msg.contains('not claim recipient') || msg.contains('notclaimrecipient')) {
        throw Exception('Your wallet is not the designated claimer');
      }
      rethrow;
    }

    // Poll for receipt
    debugPrint('NftService: Waiting for claim tx: $txHash');
    try {
      await contract.pollForReceipt(
        chainId: chain.chainId,
        txHash: txHash,
      );
    } catch (e) {
      if (e.toString().contains('reverted')) {
        throw Exception('Claim transaction failed. The link may have expired or already been claimed.');
      }
      rethrow;
    }

    debugPrint('NftService: NFT claimed successfully');
    return txHash;
  }

  /// Fetch claim offer data from the contract to check expiry/status
  Future<({int tokenId, int status, int expiresAt})?> _fetchClaimOffer(
    int chainId,
    String contractAddress,
    String linkHash,
  ) async {
    final contract = NftContractService.instance;
    final data = contract.encodeGetClaimOffer(linkHash);
    try {
      final result = await contract.ethCall(
        chainId: chainId,
        contractAddress: contractAddress,
        data: data,
      );
      return contract.decodeClaimOffer(result);
    } catch (e) {
      debugPrint('NftService: _fetchClaimOffer error: $e');
      return null;
    }
  }

  /// Ensure the wallet is on the correct chain, switching if needed
  Future<void> _ensureCorrectChain(SupportedChain chain) async {
    final wallet = WalletService.instance;
    try {
      await wallet.switchChain(chain.chainId);
    } catch (e) {
      debugPrint('NftService: Chain switch note: $e');
      // Non-fatal — the wallet may already be on the correct chain
    }
  }

  // ============================================================================
  // CANCEL CLAIM OFFER
  // ============================================================================

  /// Cancel a pending claim offer, returning the escrowed NFT to the creator.
  Future<void> cancelClaimOffer({
    required String tagId,
    required NftMintRecord mint,
    required NftClaimRecord claim,
    WalletSource walletSource = WalletSource.external,
  }) async {
    if (claim.linkHash == null) throw Exception('No link hash for this claim');

    final chain = SupportedChain.byChainId(claim.chainId);
    if (chain == null) throw Exception('Unknown chain: ${claim.chainId}');

    final nftContractAddress = chain.nftContractAddress;
    if (nftContractAddress == null ||
        nftContractAddress == '0x0000000000000000000000000000000000000000') {
      throw Exception('NFT contract not deployed on ${chain.chainName}');
    }

    if (walletSource == WalletSource.external) {
      await _ensureCorrectChain(chain);
    }

    final contract = NftContractService.instance;
    final data = contract.encodeCancelClaimOffer(claim.linkHash!);

    debugPrint('NftService: Cancelling claim offer: ${claim.linkHash}');
    final txHash = await _sendTransaction(
      chain: chain,
      contractAddress: nftContractAddress,
      encodedData: data,
      walletSource: walletSource,
    );

    await contract.pollForReceipt(
      chainId: chain.chainId,
      txHash: txHash,
    );

    // Update local record
    final claimIndex = mint.claims.indexWhere((c) => c.id == claim.id);
    if (claimIndex != -1) {
      mint.claims[claimIndex].status = NftClaimStatus.expired; // reuse expired for cancelled
      await updateMintRecord(tagId, mint);
      scheduleSyncToCloud();
    }

    debugPrint('NftService: Claim offer cancelled');
  }

  // ============================================================================
  // REFRESH CLAIM STATUSES FROM CHAIN
  // ============================================================================

  /// Query on-chain status of all pending claims for a mint record.
  /// Updates local records with claimed/cancelled status and claimer addresses.
  Future<void> refreshClaimStatuses({
    required String tagId,
    required NftMintRecord mint,
  }) async {
    final chain = SupportedChain.byChainId(mint.chainId);
    if (chain == null) return;

    final nftContractAddress = chain.nftContractAddress;
    if (nftContractAddress == null) return;

    bool changed = false;
    for (final claim in mint.claims) {
      if (claim.linkHash == null) continue;
      // Only refresh pending claims
      if (claim.status != NftClaimStatus.pending) continue;

      final offerInfo = await _fetchClaimOffer(
        chain.chainId,
        nftContractAddress,
        claim.linkHash!,
      );
      if (offerInfo == null) continue;

      if (offerInfo.status == 1 && claim.status != NftClaimStatus.claimed) {
        claim.status = NftClaimStatus.claimed;
        claim.claimerAddress = offerInfo.claimerAddress;
        changed = true;
      } else if (offerInfo.status == 2 && claim.status != NftClaimStatus.expired) {
        claim.status = NftClaimStatus.expired;
        changed = true;
      }
    }

    if (changed) {
      await updateMintRecord(tagId, mint);
      scheduleSyncToCloud();
    }
  }

  // ============================================================================
  // BURN FLOW (releases locked FULA)
  // ============================================================================

  /// Burn NFTs, releasing locked FULA to the burner.
  Future<String> burnNft({
    required int chainId,
    required int tokenId,
    required int amount,
    WalletSource walletSource = WalletSource.external,
  }) async {
    final chain = SupportedChain.byChainId(chainId);
    if (chain == null) throw Exception('Unknown chain: $chainId');

    final nftContractAddress = chain.nftContractAddress;
    if (nftContractAddress == null ||
        nftContractAddress == '0x0000000000000000000000000000000000000000') {
      throw Exception('NFT contract not deployed on ${chain.chainName}');
    }

    final account = await _getWalletAddress(walletSource);

    if (walletSource == WalletSource.external) {
      await _ensureCorrectChain(chain);
    }

    final contract = NftContractService.instance;

    debugPrint('NftService: Burning token $tokenId (amount: $amount)');
    final data = contract.encodeBurn(account, tokenId, amount);
    final txHash = await _sendTransaction(
      chain: chain,
      contractAddress: nftContractAddress,
      encodedData: data,
      walletSource: walletSource,
    );

    debugPrint('NftService: Waiting for burn tx: $txHash');
    await contract.pollForReceipt(
      chainId: chainId,
      txHash: txHash,
    );

    debugPrint('NftService: Burn successful');
    return txHash;
  }

  /// Update a claim record's status to burned.
  /// Note: Only callable by the claim creator (sender), not the claimer,
  /// since the claimer doesn't have the sender's local claim records.
  Future<void> markClaimBurned({
    required String tagId,
    required NftMintRecord mint,
    required String claimId,
    required String txHash,
  }) async {
    final claimIndex = mint.claims.indexWhere((c) => c.id == claimId);
    if (claimIndex == -1) return;

    final updatedClaims = List<NftClaimRecord>.from(mint.claims);
    updatedClaims[claimIndex].status = NftClaimStatus.burned;
    updatedClaims[claimIndex].burnTxHash = txHash;
    mint.claims = updatedClaims;
    await updateMintRecord(tagId, mint);
    scheduleSyncToCloud();
  }

  // ============================================================================
  // TRANSFER FLOW (no FULA released — standard ERC1155 transfer)
  // ============================================================================

  /// Transfer NFTs to another address. FULA stays locked — only burn releases it.
  Future<String> transferNft({
    required int chainId,
    required int tokenId,
    required String toAddress,
    required int amount,
    WalletSource walletSource = WalletSource.external,
  }) async {
    final chain = SupportedChain.byChainId(chainId);
    if (chain == null) throw Exception('Unknown chain: $chainId');

    final nftContractAddress = chain.nftContractAddress;
    if (nftContractAddress == null ||
        nftContractAddress == '0x0000000000000000000000000000000000000000') {
      throw Exception('NFT contract not deployed on ${chain.chainName}');
    }

    final from = await _getWalletAddress(walletSource);

    if (walletSource == WalletSource.external) {
      await _ensureCorrectChain(chain);
    }

    final contract = NftContractService.instance;

    debugPrint('NftService: Transferring token $tokenId (amount: $amount) to $toAddress');
    final data = contract.encodeSafeTransferFrom(from, toAddress, tokenId, amount);
    final txHash = await _sendTransaction(
      chain: chain,
      contractAddress: nftContractAddress,
      encodedData: data,
      walletSource: walletSource,
    );

    debugPrint('NftService: Waiting for transfer tx: $txHash');
    await contract.pollForReceipt(
      chainId: chainId,
      txHash: txHash,
    );

    debugPrint('NftService: Transfer successful');
    return txHash;
  }

  /// Fetch token info from the contract via eth_call.
  Future<({String creator, String metadataCid, String eventName, BigInt fulaPerNft, int initialMintCount})?> fetchTokenInfo({
    required int chainId,
    required int tokenId,
  }) async {
    final chain = SupportedChain.byChainId(chainId);
    if (chain == null) return null;

    final nftContractAddress = chain.nftContractAddress;
    if (nftContractAddress == null) return null;

    final contract = NftContractService.instance;
    final data = contract.encodeGetTokenInfo(tokenId);

    try {
      final result = await contract.ethCall(
        chainId: chainId,
        contractAddress: nftContractAddress,
        data: data,
      );
      return contract.decodeTokenInfo(result);
    } catch (e) {
      debugPrint('NftService: fetchTokenInfo error: $e');
      return null;
    }
  }

  // ============================================================================
  // RETRY LOGIC
  // ============================================================================

  /// Retry a failed mint from its last successful step
  Future<NftMintRecord> retryMint({
    required String tagId,
    required NftMintRecord record,
    required SupportedChain chain,
    WalletSource walletSource = WalletSource.external,
  }) async {
    final nftContractAddress = chain.nftContractAddress;
    if (nftContractAddress == null ||
        nftContractAddress == '0x0000000000000000000000000000000000000000') {
      throw Exception('NFT contract not yet deployed on ${chain.chainName}');
    }

    await _getWalletAddress(walletSource);
    final contract = NftContractService.instance;

    if (walletSource == WalletSource.external) {
      await _ensureCorrectChain(chain);
    }

    // Clear error and restart from last known state
    record.status = NftMintStatus.approving;
    record.errorMessage = null;
    await updateMintRecord(tagId, record);

    try {
      final fulaPerNftBigInt = _parseToWei(record.fulaPerNft);
      final totalFula = fulaPerNftBigInt * BigInt.from(record.count);

      // If we already have an IPFS CID, skip upload
      if (record.ipfsCid.isEmpty) {
        throw Exception('Cannot retry: no IPFS CID. Please start a new mint.');
      }

      // If we don't have an approval tx yet, do the approval
      if (record.approvalTxHash == null && totalFula > BigInt.zero) {
        // Check balance
        final walletAddress = await _getWalletAddress(walletSource);
        final BigInt balance;
        if (walletSource == WalletSource.external) {
          balance = await WalletService.instance.getFulaBalance(chain);
        } else {
          balance = await WalletService.instance.getErc20Balance(
            chain: chain,
            tokenAddress: chain.tokenAddress,
            walletAddress: walletAddress,
          );
        }
        if (balance < totalFula) {
          final required = (totalFula / BigInt.from(10).pow(18)).toString();
          final available = (balance / BigInt.from(10).pow(18)).toString();
          throw Exception(
            'Insufficient FULA balance. Required: $required, Available: $available',
          );
        }

        debugPrint('NftService: Retry - Approving FULA spend');
        String approvalTxHash;
        if (walletSource == WalletSource.internal) {
          approvalTxHash = await NftWalletService.instance.sendApproveTransaction(
            chain: chain,
            tokenAddress: chain.tokenAddress,
            spender: nftContractAddress,
            amount: totalFula,
          );
        } else {
          final approveData = contract.encodeApprove(nftContractAddress, totalFula);
          approvalTxHash = await WalletService.instance.sendContractTransaction(
            chain: chain,
            contractAddress: chain.tokenAddress,
            encodedData: approveData,
          );
        }
        record.approvalTxHash = approvalTxHash;
        await updateMintRecord(tagId, record);

        await contract.pollForReceipt(
          chainId: chain.chainId,
          txHash: approvalTxHash,
        );
      }

      // If we don't have a mint tx yet, do the mint
      if (record.txHash == null) {
        record.status = NftMintStatus.minting;
        await updateMintRecord(tagId, record);

        debugPrint('NftService: Retry - Calling mintWithFula');
        final mintData = contract.encodeMintWithFula(
          record.eventName,
          record.metadataCid ?? record.ipfsCid,
          fulaPerNftBigInt,
          record.count,
        );
        final mintTxHash = await _sendTransaction(
          chain: chain,
          contractAddress: nftContractAddress,
          encodedData: mintData,
          walletSource: walletSource,
        );

        record.txHash = mintTxHash;
        record.status = NftMintStatus.confirming;
        await updateMintRecord(tagId, record);
      } else {
        // We have a mint tx — just poll for it
        record.status = NftMintStatus.confirming;
        await updateMintRecord(tagId, record);
      }

      // Poll for mint receipt
      debugPrint('NftService: Retry - Waiting for mint tx: ${record.txHash}');
      final receipt = await contract.pollForReceipt(
        chainId: chain.chainId,
        txHash: record.txHash!,
      );

      // Parse tokenId from receipt
      final tokenId = contract.parseTokenIdFromReceipt(receipt);
      if (tokenId == null) {
        throw Exception('Mint transaction succeeded but could not parse token ID from receipt');
      }
      record.tokenId = tokenId;
      record.status = NftMintStatus.completed;
      await updateMintRecord(tagId, record);

      debugPrint('NftService: Retry mint complete! Token ID: $tokenId');
      scheduleSyncToCloud();

      return record;
    } catch (e) {
      debugPrint('NftService: Retry mint error: $e');
      record.status = NftMintStatus.error;
      record.errorMessage = e.toString();
      await updateMintRecord(tagId, record);
      rethrow;
    }
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

  /// Restore NFT collections from cloud following WebsiteService pattern
  Future<void> restoreFromCloud() async {
    if (!_isInitialized) await init();
    if (!FulaApiService.instance.isConfigured) return;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;

      final userId = await _getUserId();
      if (userId == null) return;

      final key = '.fula/nfts/$userId.json';
      final data = await FulaApiService.instance.downloadAndDecrypt(
        _nftMetadataBucket,
        key,
        encryptionKey,
      );

      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final collectionsList = json['collections'] as List<dynamic>? ?? [];

      if (_collectionsBox.isEmpty || collectionsList.isNotEmpty) {
        // Preserve ALL local mints not found in cloud data (merge by mint ID)
        final localCollections = _collectionsBox.values.toList();

        await _collectionsBox.clear();

        // Restore from cloud
        for (final collJson in collectionsList) {
          final collection = NftCollection.fromJson(collJson as Map<String, dynamic>);
          await _collectionsBox.put(collection.id, collection);
        }

        // Re-add local mints not found in cloud (merge by tagId + mint ID)
        for (final local in localCollections) {
          final existing = getCollectionByTagId(local.tagId);
          if (existing != null) {
            final cloudMintIds = existing.mints.map((m) => m.id).toSet();
            final newMints = local.mints
                .where((m) => !cloudMintIds.contains(m.id))
                .toList();
            if (newMints.isNotEmpty) {
              existing.mints = [...existing.mints, ...newMints];
              await _collectionsBox.put(existing.id, existing);
            }
          } else {
            await _collectionsBox.put(local.id, local);
          }
        }

        debugPrint('NFT collections restored from cloud: ${collectionsList.length}');
      }
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('NoSuchKey') ||
          errorStr.contains('Object not found') ||
          errorStr.contains('404')) {
        debugPrint('NFT restore: no cloud data found (new user or never synced)');
      } else {
        debugPrint('NftService: restoreFromCloud error: $e');
      }
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

  // ============================================================================
  // WALLET DISPATCH
  // ============================================================================

  /// Send a contract transaction via the appropriate wallet.
  Future<String> _sendTransaction({
    required SupportedChain chain,
    required String contractAddress,
    required String encodedData,
    WalletSource walletSource = WalletSource.external,
  }) async {
    if (walletSource == WalletSource.internal) {
      return NftWalletService.instance.sendSignedTransaction(
        chain: chain,
        to: contractAddress,
        encodedData: encodedData,
      );
    } else {
      return WalletService.instance.sendContractTransaction(
        chain: chain,
        contractAddress: contractAddress,
        encodedData: encodedData,
      );
    }
  }

  /// Get the wallet address for the given source.
  Future<String> _getWalletAddress(WalletSource source) async {
    if (source == WalletSource.internal) {
      final address = await NftWalletService.instance.getAddress();
      if (address == null) throw Exception('Internal wallet not available — sign in first');
      return address;
    } else {
      final wallet = WalletService.instance;
      if (!wallet.isConnected || wallet.connectedAddress == null) {
        throw Exception('Wallet not connected');
      }
      return wallet.connectedAddress!;
    }
  }

  /// Convert a decimal string like "10.5" to BigInt in wei (18 decimals).
  /// Avoids floating-point precision loss from double arithmetic.
  static BigInt _parseToWei(String amount) {
    final trimmed = amount.trim();
    if (trimmed.isEmpty) return BigInt.zero;

    final parts = trimmed.split('.');
    final wholePart = parts[0].isEmpty ? '0' : parts[0];
    final fracPart = parts.length > 1 ? parts[1] : '';

    // Pad or truncate fraction to 18 decimals
    final paddedFrac = fracPart.length > 18
        ? fracPart.substring(0, 18)
        : fracPart.padRight(18, '0');

    final combined = '$wholePart$paddedFrac';
    return BigInt.parse(combined);
  }

  void dispose() {
    _statusController.close();
  }
}
