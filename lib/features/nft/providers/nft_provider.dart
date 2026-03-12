import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/core/services/nft_service.dart';
import 'package:fula_files/core/services/tag_storage_service.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';

export 'package:fula_files/core/services/nft_service.dart' show WalletSource;

/// Provider for all NFT tags (tags with "nft-" prefix)
final nftTagsProvider = Provider<List<FileTag>>((ref) {
  final tagState = ref.watch(tagProvider);
  return tagState.tags
      .where((t) => t.name.startsWith('nft-'))
      .toList();
});

/// Provider for mint records of a specific NFT tag
final nftMintsProvider =
    StreamProvider.family<List<NftMintRecord>, String>((ref, tagId) {
  final initial = NftService.instance.getMintsForTag(tagId);

  final controller = StreamController<List<NftMintRecord>>();
  controller.add(initial);

  final subscription = NftService.instance.statusStream.listen((record) {
    controller.add(NftService.instance.getMintsForTag(tagId));
  });

  ref.onDispose(() {
    subscription.cancel();
    controller.close();
  });

  return controller.stream;
});

/// State for the NFT notifier
class NftState {
  final bool isCreating;
  final bool isMinting;
  final bool isClaiming;
  final bool isBurning;
  final bool isTransferring;
  final String? error;
  final String? statusMessage;

  const NftState({
    this.isCreating = false,
    this.isMinting = false,
    this.isClaiming = false,
    this.isBurning = false,
    this.isTransferring = false,
    this.error,
    this.statusMessage,
  });

  /// True when any operation is in progress
  bool get isBusy => isCreating || isMinting || isClaiming || isBurning || isTransferring;

  NftState copyWith({
    bool? isCreating,
    bool? isMinting,
    bool? isClaiming,
    bool? isBurning,
    bool? isTransferring,
    String? error,
    String? statusMessage,
  }) {
    return NftState(
      isCreating: isCreating ?? this.isCreating,
      isMinting: isMinting ?? this.isMinting,
      isClaiming: isClaiming ?? this.isClaiming,
      isBurning: isBurning ?? this.isBurning,
      isTransferring: isTransferring ?? this.isTransferring,
      error: error,
      statusMessage: statusMessage,
    );
  }
}

/// Map raw exception messages to user-friendly strings
String _friendlyError(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('insufficient fula')) return 'Not enough FULA tokens';
  if (lower.contains('rpc call failed') || lower.contains('rpc error')) return 'Network error — please try again';
  if (lower.contains('transaction reverted')) return 'Transaction failed on-chain';
  if (lower.contains('receipt timeout')) return 'Transaction is taking longer than expected';
  if (lower.contains('no api key')) return 'Not signed in — please sign in first';
  if (lower.contains('wallet not connected')) return 'Wallet not connected';
  if (lower.contains('internal wallet not available')) return 'Please sign in first';
  // Strip "Exception: " prefix if present
  final cleaned = raw.replaceFirst(RegExp(r'^Exception:\s*'), '');
  return cleaned;
}

/// Notifier for NFT operations
class NftNotifier extends Notifier<NftState> {
  @override
  NftState build() => const NftState();

  /// Create a new NFT collection (tag with "nft-" prefix)
  Future<FileTag?> createCollection(String name) async {
    state = state.copyWith(isCreating: true, error: null);
    try {
      final tag = await ref.read(tagProvider.notifier).createTag(
        name: 'nft-$name',
        colorValue: TagColors.getRandomColor(),
      );

      if (tag != null) {
        await NftService.instance.ensureCollection(
          tagId: tag.id,
          name: name,
        );
      }

      state = state.copyWith(isCreating: false);
      return tag;
    } catch (e) {
      state = state.copyWith(isCreating: false, error: _friendlyError(e.toString()));
      return null;
    }
  }

  /// Start minting NFTs for a collection asset
  Future<NftMintRecord?> startMint({
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
    state = state.copyWith(isMinting: true, error: null, statusMessage: 'Uploading asset...');
    try {
      final record = await NftService.instance.startMint(
        tagId: tagId,
        localPath: localPath,
        fileName: fileName,
        collectionName: collectionName,
        chain: chain,
        count: count,
        fulaPerNft: fulaPerNft,
        eventName: eventName,
        walletSource: walletSource,
      );
      state = state.copyWith(isMinting: false, statusMessage: null);
      return record;
    } catch (e) {
      state = state.copyWith(isMinting: false, error: _friendlyError(e.toString()), statusMessage: null);
      return null;
    }
  }

  /// Create a claim offer for a minted NFT.
  /// If [claimerAddress] is null, creates an open claim (anyone can claim).
  Future<({String linkHash, String claimLink})?> createClaimOffer({
    required String tagId,
    required NftMintRecord mint,
    String? claimerAddress,
    required Duration expiry,
    WalletSource walletSource = WalletSource.external,
  }) async {
    state = state.copyWith(isClaiming: true, error: null, statusMessage: 'Creating claim offer...');
    try {
      final result = await NftService.instance.createClaimOffer(
        tagId: tagId,
        mint: mint,
        claimerAddress: claimerAddress,
        expiry: expiry,
        walletSource: walletSource,
      );
      state = state.copyWith(isClaiming: false, statusMessage: null);
      return (linkHash: result.linkHash, claimLink: result.claimLink);
    } catch (e) {
      state = state.copyWith(isClaiming: false, error: _friendlyError(e.toString()), statusMessage: null);
      return null;
    }
  }

  /// Claim an NFT from a claim link
  Future<String?> claimNft({
    required int chainId,
    required String linkHash,
    WalletSource walletSource = WalletSource.external,
  }) async {
    state = state.copyWith(isClaiming: true, error: null, statusMessage: 'Claiming NFT...');
    try {
      final txHash = await NftService.instance.claimNft(
        chainId: chainId,
        linkHash: linkHash,
        walletSource: walletSource,
      );
      state = state.copyWith(isClaiming: false, statusMessage: null);
      return txHash;
    } catch (e) {
      state = state.copyWith(isClaiming: false, error: _friendlyError(e.toString()), statusMessage: null);
      return null;
    }
  }

  /// Retry a failed mint from its last successful step
  Future<NftMintRecord?> retryMint({
    required String tagId,
    required NftMintRecord record,
    required SupportedChain chain,
    WalletSource walletSource = WalletSource.external,
  }) async {
    state = state.copyWith(isMinting: true, error: null, statusMessage: 'Retrying mint...');
    try {
      final result = await NftService.instance.retryMint(
        tagId: tagId,
        record: record,
        chain: chain,
        walletSource: walletSource,
      );
      state = state.copyWith(isMinting: false, statusMessage: null);
      return result;
    } catch (e) {
      state = state.copyWith(isMinting: false, error: _friendlyError(e.toString()), statusMessage: null);
      return null;
    }
  }

  /// Burn an NFT, releasing locked FULA to the creator
  Future<String?> burnNft({
    required int chainId,
    required int tokenId,
    required int amount,
    WalletSource walletSource = WalletSource.external,
  }) async {
    state = state.copyWith(isBurning: true, error: null, statusMessage: 'Burning NFT...');
    try {
      final txHash = await NftService.instance.burnNft(
        chainId: chainId,
        tokenId: tokenId,
        amount: amount,
        walletSource: walletSource,
      );
      state = state.copyWith(isBurning: false, statusMessage: null);
      return txHash;
    } catch (e) {
      state = state.copyWith(isBurning: false, error: _friendlyError(e.toString()), statusMessage: null);
      return null;
    }
  }

  /// Transfer an NFT to another address (no FULA released)
  Future<String?> transferNft({
    required int chainId,
    required int tokenId,
    required String toAddress,
    required int amount,
    WalletSource walletSource = WalletSource.external,
  }) async {
    state = state.copyWith(isTransferring: true, error: null, statusMessage: 'Transferring NFT...');
    try {
      final txHash = await NftService.instance.transferNft(
        chainId: chainId,
        tokenId: tokenId,
        toAddress: toAddress,
        amount: amount,
        walletSource: walletSource,
      );
      state = state.copyWith(isTransferring: false, statusMessage: null);
      return txHash;
    } catch (e) {
      state = state.copyWith(isTransferring: false, error: _friendlyError(e.toString()), statusMessage: null);
      return null;
    }
  }

  /// Delete an NFT collection and all its data
  Future<void> deleteCollection(String tagId) async {
    try {
      await NftService.instance.deleteCollection(tagId);
      await ref.read(tagProvider.notifier).deleteTag(tagId);
    } catch (e) {
      state = state.copyWith(error: _friendlyError(e.toString()));
    }
  }
}

/// Provider for the NFT notifier
final nftProvider =
    NotifierProvider<NftNotifier, NftState>(() => NftNotifier());
