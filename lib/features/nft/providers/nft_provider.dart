import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/core/services/nft_service.dart';
import 'package:fula_files/core/services/nft_wallet_service.dart';
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

/// Provider for received (claimed) NFTs
final receivedNftsProvider = Provider<List<ReceivedNft>>((ref) {
  // Re-read whenever NFT state changes (e.g. after claim/burn)
  ref.watch(nftProvider);
  return NftService.instance.getReceivedNfts();
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

  /// Reset all in-progress flags so the UI is unblocked.
  /// The on-chain transaction will still complete in the background.
  void cancelOperation() {
    state = const NftState();
  }

  /// Create a new NFT collection (tag with "nft-" prefix)
  Future<FileTag?> createCollection(String name) async {
    state = state.copyWith(isCreating: true, error: null);
    try {
      final tag = await ref.read(tagProvider.notifier).createTag(
        name: 'nft-$name',
        colorValue: TagColors.getRandomColor(),
      );

      if (tag != null) {
        final walletAddress = await NftWalletService.instance.getAddress();
        await NftService.instance.ensureCollection(
          tagId: tag.id,
          name: name,
          creatorWalletAddress: walletAddress,
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
    int royaltyBps = 0,
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
        royaltyBps: royaltyBps,
        walletSource: walletSource,
        onStatus: (msg) => state = state.copyWith(statusMessage: msg),
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
    final msg = walletSource == WalletSource.external
        ? 'Confirm claim offer in your wallet...'
        : 'Creating claim offer...';
    state = state.copyWith(isClaiming: true, error: null, statusMessage: msg);
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
    final msg = walletSource == WalletSource.external
        ? 'Confirm claim in your wallet...'
        : 'Claiming NFT...';
    state = state.copyWith(isClaiming: true, error: null, statusMessage: msg);
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
    final burnMsg = walletSource == WalletSource.external
        ? 'Confirm burn in your wallet...'
        : 'Burning NFT...';
    state = state.copyWith(isBurning: true, error: null, statusMessage: burnMsg);
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
    final transferMsg = walletSource == WalletSource.external
        ? 'Confirm transfer in your wallet...'
        : 'Transferring NFT...';
    state = state.copyWith(isTransferring: true, error: null, statusMessage: transferMsg);
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

  /// Cancel a pending claim offer, returning NFT to creator
  Future<bool> cancelClaimOffer({
    required String tagId,
    required NftMintRecord mint,
    required NftClaimRecord claim,
    WalletSource walletSource = WalletSource.external,
  }) async {
    final cancelMsg = walletSource == WalletSource.external
        ? 'Confirm cancellation in your wallet...'
        : 'Cancelling claim...';
    state = state.copyWith(isClaiming: true, error: null, statusMessage: cancelMsg);
    try {
      await NftService.instance.cancelClaimOffer(
        tagId: tagId,
        mint: mint,
        claim: claim,
        walletSource: walletSource,
      );
      state = state.copyWith(isClaiming: false, statusMessage: null);
      return true;
    } catch (e) {
      state = state.copyWith(isClaiming: false, error: _friendlyError(e.toString()), statusMessage: null);
      return false;
    }
  }

  /// Refresh claim statuses from on-chain data
  Future<void> refreshClaimStatuses({
    required String tagId,
    required NftMintRecord mint,
  }) async {
    try {
      await NftService.instance.refreshClaimStatuses(
        tagId: tagId,
        mint: mint,
      );
    } catch (e) {
      debugPrint('NftProvider: refreshClaimStatuses error: $e');
    }
  }

  /// Refresh collections from on-chain data (reconstruction fallback)
  Future<int> refreshFromChain() async {
    state = state.copyWith(isCreating: true, statusMessage: 'Syncing from blockchain...');
    try {
      final count = await NftService.instance.reconstructFromChain();
      ref.invalidateSelf();
      state = state.copyWith(isCreating: false, statusMessage: null);
      return count;
    } catch (e) {
      state = state.copyWith(isCreating: false, error: _friendlyError(e.toString()));
      return 0;
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
