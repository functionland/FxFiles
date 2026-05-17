import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fula_files/core/models/automate_task.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/services/automate_task_service.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';

/// Tags that represent Automate tasks (those whose name starts with the
/// "automate-tasks-" prefix). Mirrors `aiTagsProvider`.
final automateTagsProvider = Provider<List<FileTag>>((ref) {
  final tagState = ref.watch(tagProvider);
  return tagState.tags
      .where((t) => t.name.startsWith('automate-tasks-'))
      .toList();
});

/// Live task record for a specific tag. Emits the latest AutomateTask
/// after every save() — used by the detail and run screens to react to
/// edits and send-status changes without manual refresh.
final automateTaskForTagProvider =
    StreamProvider.family<AutomateTask?, String>((ref, tagId) {
  final controller = StreamController<AutomateTask?>();
  controller.add(AutomateTaskService.instance.findByTagId(tagId));

  final sub = AutomateTaskService.instance.statusStream.listen((task) {
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

class AutomateTaskState {
  final bool isCreating;
  final bool isRunning;
  final String? error;
  const AutomateTaskState({
    this.isCreating = false,
    this.isRunning = false,
    this.error,
  });
  AutomateTaskState copyWith(
          {bool? isCreating, bool? isRunning, String? error}) =>
      AutomateTaskState(
        isCreating: isCreating ?? this.isCreating,
        isRunning: isRunning ?? this.isRunning,
        error: error,
      );
}

class AutomateTaskNotifier extends Notifier<AutomateTaskState> {
  @override
  AutomateTaskState build() => const AutomateTaskState();

  /// Create a fresh Automate task — adds an `automate-tasks-<name>` tag
  /// and an empty AutomateTask record bound to it. Returns the created
  /// tag (the screen then pushes `/automate-tasks/{tag.id}`).
  Future<FileTag?> createTask(String name) async {
    state = state.copyWith(isCreating: true, error: null);
    try {
      final tag = await ref.read(tagProvider.notifier).createTag(
            name: 'automate-tasks-$name',
            colorValue: TagColors.getRandomColor(),
          );
      if (tag != null) {
        await AutomateTaskService.instance.getOrCreate(
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

  /// Delete an Automate task — removes the persisted AutomateTask
  /// record, then the tag itself (so attached files lose this tag).
  Future<void> deleteTask(String tagId) async {
    try {
      await AutomateTaskService.instance.deleteTasksForTag(tagId);
      await ref.read(tagProvider.notifier).deleteTag(tagId);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }
}

final automateTaskProvider =
    NotifierProvider<AutomateTaskNotifier, AutomateTaskState>(
        () => AutomateTaskNotifier());
