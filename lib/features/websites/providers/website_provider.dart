import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/services/tag_storage_service.dart';
import 'package:fula_files/core/services/website_service.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';

/// Provider for all website tags (tags with "websites-" prefix)
final websiteTagsProvider = Provider<List<FileTag>>((ref) {
  final tagState = ref.watch(tagProvider);
  return tagState.tags
      .where((t) => t.name.startsWith('websites-'))
      .toList();
});

/// Provider for generations of a specific website tag
final websiteGenerationsProvider =
    StreamProvider.family<List<WebsiteGeneration>, String>((ref, tagId) {
  // Get initial data
  final initial = WebsiteService.instance.getGenerationsForTag(tagId);

  // Create a controller that emits initial data then listens to updates
  final controller = StreamController<List<WebsiteGeneration>>();
  controller.add(initial);

  final subscription = WebsiteService.instance.statusStream.listen((generation) {
    if (generation.tagId == tagId) {
      controller.add(WebsiteService.instance.getGenerationsForTag(tagId));
    }
  });

  ref.onDispose(() {
    subscription.cancel();
    controller.close();
  });

  return controller.stream;
});

/// State for the website notifier
class WebsiteState {
  final bool isCreating;
  final bool isGenerating;
  final String? error;

  const WebsiteState({
    this.isCreating = false,
    this.isGenerating = false,
    this.error,
  });

  WebsiteState copyWith({
    bool? isCreating,
    bool? isGenerating,
    String? error,
  }) {
    return WebsiteState(
      isCreating: isCreating ?? this.isCreating,
      isGenerating: isGenerating ?? this.isGenerating,
      error: error,
    );
  }
}

/// Notifier for website operations
class WebsiteNotifier extends Notifier<WebsiteState> {
  // M1: Track in-flight generations per tagId to prevent duplicates
  final Set<String> _generatingTagIds = {};

  @override
  WebsiteState build() => const WebsiteState();

  /// Create a new website (tag with "websites-" prefix)
  Future<FileTag?> createWebsite(String name) async {
    state = state.copyWith(isCreating: true, error: null);
    try {
      final tag = await ref.read(tagProvider.notifier).createTag(
        name: 'websites-$name',
        colorValue: TagColors.getRandomColor(),
      );
      state = state.copyWith(isCreating: false);
      return tag;
    } catch (e) {
      state = state.copyWith(isCreating: false, error: e.toString());
      return null;
    }
  }

  /// Delete a website and all its generations
  Future<void> deleteWebsite(String tagId) async {
    try {
      await WebsiteService.instance.deleteGenerationsForTag(tagId);
      await ref.read(tagProvider.notifier).deleteTag(tagId);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Whether a generation is in-flight for the given tag
  bool isGeneratingForTag(String tagId) => _generatingTagIds.contains(tagId);

  /// Start website generation for a tag
  Future<WebsiteGeneration?> startGeneration({
    required String tagId,
    required String tagName,
    required String prompt,
    required List<TaggedFile> files,
  }) async {
    // M1: Prevent duplicate generation for the same tag
    if (_generatingTagIds.contains(tagId)) {
      return null;
    }

    _generatingTagIds.add(tagId);
    state = state.copyWith(isGenerating: true, error: null);
    try {
      final generation = await WebsiteService.instance.startGeneration(
        tagId: tagId,
        tagName: tagName,
        prompt: prompt,
        files: files,
      );
      state = state.copyWith(isGenerating: false);
      return generation;
    } catch (e) {
      state = state.copyWith(isGenerating: false, error: e.toString());
      return null;
    } finally {
      _generatingTagIds.remove(tagId);
    }
  }
}

/// Provider for the website notifier
final websiteProvider =
    NotifierProvider<WebsiteNotifier, WebsiteState>(() => WebsiteNotifier());
