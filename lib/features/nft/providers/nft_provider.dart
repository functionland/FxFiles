import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/core/services/nft_service.dart';
import 'package:fula_files/core/services/tag_storage_service.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';

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
  final String? error;
  final String? statusMessage;

  const NftState({
    this.isCreating = false,
    this.isMinting = false,
    this.isClaiming = false,
    this.error,
    this.statusMessage,
  });

  NftState copyWith({
    bool? isCreating,
    bool? isMinting,
    bool? isClaiming,
    String? error,
    String? statusMessage,
  }) {
    return NftState(
      isCreating: isCreating ?? this.isCreating,
      isMinting: isMinting ?? this.isMinting,
      isClaiming: isClaiming ?? this.isClaiming,
      error: error,
      statusMessage: statusMessage,
    );
  }
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
      state = state.copyWith(isCreating: false, error: e.toString());
      return null;
    }
  }

  /// Delete an NFT collection and all its data
  Future<void> deleteCollection(String tagId) async {
    try {
      await NftService.instance.deleteCollection(tagId);
      await ref.read(tagProvider.notifier).deleteTag(tagId);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }
}

/// Provider for the NFT notifier
final nftProvider =
    NotifierProvider<NftNotifier, NftState>(() => NftNotifier());
