import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/ai_task.dart';

/// Persistence + business-logic layer for the AI Automation feature.
///
/// One [AiTask] per tag (the tag's name is the user-facing task name,
/// prefixed `ai-tasks-`). The tag holds the attached CSV/asset files (via
/// the existing TagStorageService); this service stores the task
/// configuration (prompt, target, rendered template, per-row send plan).
///
/// Parallels `WebsiteService` in shape — same lazy init, same status
/// stream, same per-asset comment store keyed by `tagId|taggedFileId`.
class AiTaskService {
  AiTaskService._();
  static final AiTaskService instance = AiTaskService._();

  static const _uuid = Uuid();

  late Box<AiTask> _tasksBox;
  late Box<String> _commentsBox;
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  final _statusController = StreamController<AiTask>.broadcast();
  Stream<AiTask> get statusStream => _statusController.stream;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      if (!Hive.isAdapterRegistered(40)) {
        Hive.registerAdapter(AiTaskTypeAdapter());
      }
      if (!Hive.isAdapterRegistered(41)) {
        Hive.registerAdapter(TargetAppAdapter());
      }
      if (!Hive.isAdapterRegistered(42)) {
        Hive.registerAdapter(SendStatusAdapter());
      }
      if (!Hive.isAdapterRegistered(43)) {
        Hive.registerAdapter(AiTaskAdapter());
      }
      if (!Hive.isAdapterRegistered(44)) {
        Hive.registerAdapter(SendPlanRowAdapter());
      }
      _tasksBox = await Hive.openBox<AiTask>('ai_tasks');
      _commentsBox = await Hive.openBox<String>('ai_task_asset_comments');
      _isInitialized = true;
      debugPrint(
          'AiTaskService initialized: ${_tasksBox.length} tasks, '
          '${_commentsBox.length} comments');
    } catch (e) {
      debugPrint('AiTaskService init failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Task CRUD
  // ---------------------------------------------------------------------

  /// Get the (single) task for a given tagId, creating a blank one when
  /// none exists. Single-task-per-tag matches the website pattern: the
  /// tag IS the task; rerunning overwrites the rows on the same record.
  Future<AiTask> getOrCreate({
    required String tagId,
    required String tagName,
  }) async {
    if (!_isInitialized) await init();
    final existing = _tasksBox.values.firstWhere(
      (t) => t.tagId == tagId,
      orElse: () => _placeholder(tagId: tagId, tagName: tagName),
    );
    if (existing.id.isEmpty) {
      // Placeholder isn't in the box yet — persist now so subsequent
      // mutations have a stable key.
      final fresh = AiTask(
        id: _uuid.v4(),
        tagId: tagId,
        tagName: tagName,
        taskType: AiTaskType.crmAutomation,
        targetApp: TargetApp.whatsapp,
        userPrompt: '',
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

  /// Returns the task for [tagId] or null if none exists. Use this when
  /// "no task yet" is a meaningful state (e.g. the browser screen list).
  AiTask? findByTagId(String tagId) {
    if (!_isInitialized) return null;
    for (final t in _tasksBox.values) {
      if (t.tagId == tagId) return t;
    }
    return null;
  }

  Future<void> save(AiTask task) async {
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

  List<AiTask> getAllTasks() {
    if (!_isInitialized) return const [];
    return _tasksBox.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  // ---------------------------------------------------------------------
  // Per-asset comments (mirrors WebsiteService — same composite-key shape
  // so the existing TagAssetPickerDialog comment flow can be reused).
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

  Map<String, String> getAssetCommentsForTag(String tagId) {
    if (!_isInitialized) return const {};
    final prefix = '$tagId|';
    final out = <String, String>{};
    for (final key in _commentsBox.keys) {
      if (key is String && key.startsWith(prefix)) {
        final v = _commentsBox.get(key);
        if (v != null && v.isNotEmpty) {
          out[key.substring(prefix.length)] = v;
        }
      }
    }
    return out;
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

  AiTask _placeholder({required String tagId, required String tagName}) {
    return AiTask(
      id: '', // empty id signals "not yet in box"
      tagId: tagId,
      tagName: tagName,
      taskType: AiTaskType.crmAutomation,
      targetApp: TargetApp.whatsapp,
      userPrompt: '',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      rows: const [],
    );
  }
}
