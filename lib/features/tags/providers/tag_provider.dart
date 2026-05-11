import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/services/sharing_service.dart';
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/tag_storage_service.dart';

/// State for tag management
class TagState {
  final List<FileTag> tags;
  final bool isLoading;
  final String? error;

  const TagState({
    this.tags = const [],
    this.isLoading = false,
    this.error,
  });

  TagState copyWith({
    List<FileTag>? tags,
    bool? isLoading,
    String? error,
  }) {
    return TagState(
      tags: tags ?? this.tags,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// Notifier for managing tags state
class TagNotifier extends Notifier<TagState> {
  VoidCallback? _serviceListener;

  @override
  TagState build() {
    // Listen to tag storage changes
    _serviceListener = () {
      _loadTags();
    };
    TagStorageService.instance.addListener(_serviceListener!);

    // Clean up listener on dispose
    ref.onDispose(() {
      if (_serviceListener != null) {
        TagStorageService.instance.removeListener(_serviceListener!);
      }
    });

    // Initial load
    Future.microtask(_loadTags);

    return const TagState(isLoading: true);
  }

  Future<void> _loadTags() async {
    try {
      final tags = await TagStorageService.instance.getAllTags();
      state = TagState(tags: tags);
    } catch (e) {
      state = TagState(error: e.toString());
    }
  }

  /// Refresh tags from storage
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true);
    await _loadTags();
  }

  /// Create a new tag
  Future<FileTag?> createTag({
    required String name,
    required int colorValue,
  }) async {
    try {
      final tag = await TagStorageService.instance.createTag(
        name: name,
        colorValue: colorValue,
      );
      return tag;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  /// Update tag name
  Future<void> updateTagName(String tagId, String newName) async {
    try {
      await TagStorageService.instance.updateTagName(tagId, newName);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Update tag color
  Future<void> updateTagColor(String tagId, int newColorValue) async {
    try {
      await TagStorageService.instance.updateTagColor(tagId, newColorValue);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Delete a tag. Any active shares targeting this tag are revoked first so
  /// recipients get a clean 403 instead of a stale-empty manifest.
  Future<void> deleteTag(String tagId) async {
    try {
      // Revoke before deleting — revokeShare needs the share record but does
      // not depend on the tag still existing.
      try {
        final shares = await SharingService.instance.getOutgoingShares();
        for (final s in shares) {
          if (s.tagId == tagId && !s.isRevoked) {
            await SharingService.instance.revokeShare(s.token.id);
          }
        }
      } catch (e) {
        // Non-fatal: tag deletion proceeds even if share revocation fails.
        debugPrint('TagNotifier.deleteTag: revokeShare cleanup failed: $e');
      }
      await TagStorageService.instance.deleteTag(tagId);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Search tags by name
  Future<List<FileTag>> searchTags(String query) async {
    return TagStorageService.instance.searchTags(query);
  }
}

/// Provider for all tags
final tagProvider = NotifierProvider<TagNotifier, TagState>(() {
  return TagNotifier();
});

/// Provider for tags on a specific file
final fileTagsProvider = FutureProvider.family<List<FileTag>, FileTagQuery>((ref, query) async {
  // Watch tag state to refresh when tags change
  ref.watch(tagProvider);

  return TagStorageService.instance.getTagsForFile(
    localPath: query.localPath,
    remoteKey: query.remoteKey,
    iosAssetId: query.iosAssetId,
  );
});

/// Provider for files with a specific tag
final taggedFilesProvider = FutureProvider.family<List<TaggedFile>, String>((ref, tagId) async {
  // Watch tag state to refresh when files are tagged/untagged
  ref.watch(tagProvider);

  return TagStorageService.instance.getFilesWithTag(tagId);
});

/// Query object for file tags lookup
class FileTagQuery {
  final String? localPath;
  final String? remoteKey;
  final String? iosAssetId;

  const FileTagQuery({
    this.localPath,
    this.remoteKey,
    this.iosAssetId,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FileTagQuery &&
        other.localPath == localPath &&
        other.remoteKey == remoteKey &&
        other.iosAssetId == iosAssetId;
  }

  @override
  int get hashCode => Object.hash(localPath, remoteKey, iosAssetId);
}

/// Extension methods for tagging files
extension TaggingExtension on WidgetRef {
  /// Tag a file with a tag
  Future<void> tagFile({
    required String tagId,
    String? localPath,
    String? remoteKey,
    String? iosAssetId,
    required String fileName,
  }) async {
    await TagStorageService.instance.tagFile(
      tagId: tagId,
      localPath: localPath,
      remoteKey: remoteKey,
      iosAssetId: iosAssetId,
      fileName: fileName,
    );
    // Invalidate providers so UI refreshes
    invalidate(fileTagsProvider(FileTagQuery(
      localPath: localPath,
      remoteKey: remoteKey,
      iosAssetId: iosAssetId,
    )));
    invalidate(taggedFilesProvider(tagId));
    // Refresh any active share for this tag (latest mode).
    SyncService.instance.checkTagShareUpdate(tagId);
  }

  /// Remove a tag from a file
  Future<void> untagFile({
    required String tagId,
    String? localPath,
    String? remoteKey,
    String? iosAssetId,
  }) async {
    await TagStorageService.instance.untagFile(
      tagId: tagId,
      localPath: localPath,
      remoteKey: remoteKey,
      iosAssetId: iosAssetId,
    );
    // Invalidate providers so UI refreshes
    invalidate(fileTagsProvider(FileTagQuery(
      localPath: localPath,
      remoteKey: remoteKey,
      iosAssetId: iosAssetId,
    )));
    invalidate(taggedFilesProvider(tagId));
    // Refresh any active share for this tag so the file disappears from the
    // recipient view.
    SyncService.instance.checkTagShareUpdate(tagId);
  }

  /// Remove all tags from a file
  Future<void> removeAllTagsFromFile({
    String? localPath,
    String? remoteKey,
    String? iosAssetId,
  }) async {
    // Capture the affected tag ids BEFORE removal so we can refresh their
    // shares afterwards.
    final affected = await TagStorageService.instance.getTagsForFile(
      localPath: localPath,
      remoteKey: remoteKey,
      iosAssetId: iosAssetId,
    );
    await TagStorageService.instance.removeAllTagsFromFile(
      localPath: localPath,
      remoteKey: remoteKey,
      iosAssetId: iosAssetId,
    );
    // Invalidate the file tags provider
    invalidate(fileTagsProvider(FileTagQuery(
      localPath: localPath,
      remoteKey: remoteKey,
      iosAssetId: iosAssetId,
    )));
    for (final t in affected) {
      SyncService.instance.checkTagShareUpdate(t.id);
    }
  }
}
