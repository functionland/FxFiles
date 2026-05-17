import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/automate_task.dart';
import 'package:fula_files/core/models/messaging_target.dart';

/// Persistence + business-logic layer for the Automate feature.
///
/// One [AutomateTask] per tag. The tag's name is the user-facing task
/// name, prefixed `automate-tasks-`. The tag holds the attached CSV
/// file(s) (via the existing TagStorageService); this service stores
/// the task configuration (TO field template, message template, target
/// app, per-row send plan after rendering).
///
/// Mirrors `AiTaskService` in shape — same per-asset comment store,
/// same statusStream + getOrCreate pattern. The Hive adapters for the
/// shared `TargetApp` / `SendStatus` / `SendPlanRow` types are
/// idempotently registered here too (guarded by
/// `Hive.isAdapterRegistered(typeId)`), so this service is safe to
/// initialise regardless of whether AiTaskService also ran.
class AutomateTaskService {
  AutomateTaskService._();
  static final AutomateTaskService instance = AutomateTaskService._();

  static const _uuid = Uuid();

  late Box<AutomateTask> _tasksBox;
  late Box<String> _commentsBox;
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  final _statusController = StreamController<AutomateTask>.broadcast();
  Stream<AutomateTask> get statusStream => _statusController.stream;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      // Shared adapters (also registered by AiTaskService when the AI
      // feature is enabled). Both paths guard with isAdapterRegistered.
      if (!Hive.isAdapterRegistered(41)) {
        Hive.registerAdapter(TargetAppAdapter());
      }
      if (!Hive.isAdapterRegistered(42)) {
        Hive.registerAdapter(SendStatusAdapter());
      }
      if (!Hive.isAdapterRegistered(44)) {
        Hive.registerAdapter(SendPlanRowAdapter());
      }
      // Automate-specific adapter.
      if (!Hive.isAdapterRegistered(50)) {
        Hive.registerAdapter(AutomateTaskAdapter());
      }
      _tasksBox = await Hive.openBox<AutomateTask>('automate_tasks');
      _commentsBox =
          await Hive.openBox<String>('automate_task_asset_comments');
      _isInitialized = true;
      debugPrint(
          'AutomateTaskService initialized: ${_tasksBox.length} tasks, '
          '${_commentsBox.length} comments');
    } catch (e) {
      debugPrint('AutomateTaskService init failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Task CRUD
  // ---------------------------------------------------------------------

  /// Get the (single) task for a given tagId, creating a blank one when
  /// none exists. Single-task-per-tag — same pattern as AiTaskService.
  Future<AutomateTask> getOrCreate({
    required String tagId,
    required String tagName,
  }) async {
    if (!_isInitialized) await init();
    final existing = _tasksBox.values.firstWhere(
      (t) => t.tagId == tagId,
      orElse: () => _placeholder(tagId: tagId, tagName: tagName),
    );
    if (existing.id.isEmpty) {
      final fresh = AutomateTask(
        id: _uuid.v4(),
        tagId: tagId,
        tagName: tagName,
        targetApp: TargetApp.whatsapp,
        toFieldTemplate: '',
        messageTemplate: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        rows: const [],
      );
      await _tasksBox.put(fresh.id, fresh);
      _statusController.add(fresh);
      return fresh;
    }
    return existing;
  }

  /// Returns the task for [tagId] or null if none exists.
  AutomateTask? findByTagId(String tagId) {
    if (!_isInitialized) return null;
    for (final t in _tasksBox.values) {
      if (t.tagId == tagId) return t;
    }
    return null;
  }

  Future<void> save(AutomateTask task) async {
    if (!_isInitialized) await init();
    task.updatedAt = DateTime.now();
    await _tasksBox.put(task.id, task);
    _statusController.add(task);
  }

  Future<void> deleteTasksForTag(String tagId) async {
    if (!_isInitialized) await init();
    final toRemove = _tasksBox.values
        .where((t) => t.tagId == tagId)
        .map((t) => t.id)
        .toList();
    for (final id in toRemove) {
      await _tasksBox.delete(id);
    }
    await deleteAssetCommentsForTag(tagId);
  }

  List<AutomateTask> getAllTasks() {
    if (!_isInitialized) return const [];
    return _tasksBox.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  // ---------------------------------------------------------------------
  // Per-asset comments (composite-key shape — same as WebsiteService and
  // AiTaskService so the existing TagAssetPickerDialog comment flow can
  // be reused without modification).
  // ---------------------------------------------------------------------

  String _commentKey(String tagId, String taggedFileId) =>
      '$tagId|$taggedFileId';

  String? getAssetComment(String tagId, String taggedFileId) {
    if (!_isInitialized) return null;
    final v = _commentsBox.get(_commentKey(tagId, taggedFileId));
    if (v == null || v.isEmpty) return null;
    return v;
  }

  Future<void> setAssetComment(
      String tagId, String taggedFileId, String comment) async {
    if (!_isInitialized) await init();
    final key = _commentKey(tagId, taggedFileId);
    final trimmed = comment.trim();
    if (trimmed.isEmpty) {
      await _commentsBox.delete(key);
    } else {
      await _commentsBox.put(key, trimmed);
    }
  }

  Future<void> deleteAssetComment(
      String tagId, String taggedFileId) async {
    if (!_isInitialized) return;
    await _commentsBox.delete(_commentKey(tagId, taggedFileId));
  }

  Future<void> deleteAssetCommentsForTag(String tagId) async {
    if (!_isInitialized) return;
    final prefix = '$tagId|';
    final toRemove = <String>[
      for (final key in _commentsBox.keys)
        if (key is String && key.startsWith(prefix)) key,
    ];
    for (final k in toRemove) {
      await _commentsBox.delete(k);
    }
  }

  // ---------------------------------------------------------------------

  AutomateTask _placeholder(
      {required String tagId, required String tagName}) {
    return AutomateTask(
      id: '', // empty id signals "not yet in box"
      tagId: tagId,
      tagName: tagName,
      targetApp: TargetApp.whatsapp,
      toFieldTemplate: '',
      messageTemplate: '',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      rows: const [],
    );
  }
}
