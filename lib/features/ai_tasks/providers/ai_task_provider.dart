import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fula_files/core/models/ai_task.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/services/ai_task_service.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';

/// Tags that represent AI tasks (those whose name starts with the
/// "ai-tasks-" prefix). Mirrors `websiteTagsProvider`.
final aiTagsProvider = Provider<List<FileTag>>((ref) {
  final tagState = ref.watch(tagProvider);
  return tagState.tags
      .where((t) => t.name.startsWith('ai-tasks-'))
      .toList();
});

/// Live task record for a specific tag. Emits the latest AiTask after
/// every save() — used by the detail and run screens to react to
/// LLM-output and send-status changes without manual refresh.
final aiTaskForTagProvider =
    StreamProvider.family<AiTask?, String>((ref, tagId) {
  final controller = StreamController<AiTask?>();
  controller.add(AiTaskService.instance.findByTagId(tagId));

  final sub = AiTaskService.instance.statusStream.listen((task) {
    if (task.tagId == tagId) {
      controller.add(task);
    }
  });
  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });
  return controller.stream;
});

class AiTaskState {
  final bool isCreating;
  final bool isRunning;
  final String? error;
  const AiTaskState({
    this.isCreating = false,
    this.isRunning = false,
    this.error,
  });
  AiTaskState copyWith({bool? isCreating, bool? isRunning, String? error}) =>
      AiTaskState(
        isCreating: isCreating ?? this.isCreating,
        isRunning: isRunning ?? this.isRunning,
        error: error,
      );
}

class AiTaskNotifier extends Notifier<AiTaskState> {
  @override
  AiTaskState build() => const AiTaskState();

  /// Create a fresh AI task — adds an `ai-tasks-<name>` tag and an empty
  /// AiTask record bound to it. Returns the created tag (the screen then
  /// pushes `/ai-tasks/{tag.id}`).
  Future<FileTag?> createTask(String name) async {
    state = state.copyWith(isCreating: true, error: null);
    try {
      final tag = await ref.read(tagProvider.notifier).createTag(
            name: 'ai-tasks-$name',
            colorValue: TagColors.getRandomColor(),
          );
      if (tag != null) {
        await AiTaskService.instance.getOrCreate(
          tagId: tag.id,
          tagName: tag.name,
        );
      }
      state = state.copyWith(isCreating: false);
      return tag;
    } catch (e) {
      state = state.copyWith(isCreating: false, error: e.toString());
      return null;
    }
  }

  /// Delete an AI task — removes the persisted AiTask record, then the
  /// tag itself (so attached files lose this tag).
  Future<void> deleteTask(String tagId) async {
    try {
      await AiTaskService.instance.deleteTasksForTag(tagId);
      await ref.read(tagProvider.notifier).deleteTag(tagId);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }
}

final aiTaskProvider = NotifierProvider<AiTaskNotifier, AiTaskState>(
    () => AiTaskNotifier());
