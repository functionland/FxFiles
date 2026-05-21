import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;

import 'package:fula_files/core/models/dump_item.dart';

/// Persistence for the Dump feature. Singleton, mirrors the repo's
/// existing `*Service` convention (see [SyncService], [AuthService]).
///
/// `init()` is idempotent and safe to call from both the main isolate
/// and the WorkManager background isolate (revision R1 in the Dump
/// plan).
class DumpStorageService {
  DumpStorageService._();
  static final DumpStorageService instance = DumpStorageService._();

  static const String _boxName = 'dump_items';

  /// Threshold below which `findDuplicate` does a full-file SHA-256
  /// verification (R8 in the Dump plan). Above this, we accept the
  /// candidate match (size + 1MB-prefix sha) and document the
  /// false-dedup risk for large media.
  static const int fullHashThresholdBytes = 50 * 1024 * 1024;

  Box<DumpItem>? _box;
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized && (_box?.isOpen ?? false);

  Future<void> init() async {
    if (isInitialized) return;

    if (!Hive.isAdapterRegistered(60)) {
      Hive.registerAdapter(DumpCategoryAdapter());
    }
    if (!Hive.isAdapterRegistered(61)) {
      Hive.registerAdapter(DumpUploadStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(62)) {
      Hive.registerAdapter(DumpItemAdapter());
    }
    if (!Hive.isAdapterRegistered(63)) {
      Hive.registerAdapter(DumpEnrichmentStatusAdapter());
    }

    try {
      _box = await Hive.openBox<DumpItem>(_boxName)
          .timeout(const Duration(milliseconds: 1500));
      _isInitialized = true;
    } catch (e) {
      debugPrint('Failed to open dump_items box: $e');
    }
  }

  Future<void> add(DumpItem item) async {
    final box = _box;
    if (box == null) return;
    await box.put(item.id, item);
  }

  Future<void> update(DumpItem item) async {
    final box = _box;
    if (box == null) return;
    await box.put(item.id, item);
  }

  DumpItem? getById(String id) => _box?.get(id);

  List<DumpItem> getAll() => _box?.values.toList() ?? const <DumpItem>[];

  /// Candidate-only dedup lookup by contentSha. Callers must additionally
  /// verify size + (for files ≤ [fullHashThresholdBytes]) full SHA-256
  /// via [findDuplicate].
  List<DumpItem> findByContentSha(String contentSha) {
    final box = _box;
    if (box == null) return const <DumpItem>[];
    return box.values.where((i) => i.contentSha == contentSha).toList();
  }

  /// Returns an existing item whose content matches [sourceFilePath]
  /// per R8 in the Dump plan:
  ///   - same `contentSha` candidate AND same `sizeBytes`
  ///   - AND (if `sizeBytes <= fullHashThresholdBytes`) full SHA-256
  ///     of both files matches
  ///   - else (> threshold): accept candidate (documented false-dedup
  ///     risk for large media)
  ///
  /// Returns `null` when no duplicate is found.
  Future<DumpItem?> findDuplicate({
    required String contentSha,
    required int sizeBytes,
    required String sourceFilePath,
  }) async {
    final candidates = findByContentSha(contentSha)
        .where((c) => c.sizeBytes == sizeBytes)
        .toList();
    if (candidates.isEmpty) return null;

    if (sizeBytes > fullHashThresholdBytes) {
      return candidates.first;
    }

    final sourceFullSha = await _fullSha256OfFile(sourceFilePath);
    if (sourceFullSha == null) {
      // Couldn't read source — fall back to candidate match.
      return candidates.first;
    }
    for (final c in candidates) {
      final candidateFullSha = await _fullSha256OfFile(c.localCachePath);
      if (candidateFullSha == sourceFullSha) return c;
    }
    return null;
  }

  Future<void> updateStatus(
    String id,
    DumpUploadStatus status, {
    String? remoteKey,
    String? errorMessage,
  }) async {
    final existing = getById(id);
    if (existing == null) return;
    final updated = existing.copyWith(
      uploadStatus: status,
      remoteKey: remoteKey ?? existing.remoteKey,
      errorMessage: errorMessage,
    );
    await update(updated);
  }

  Future<void> updateEnrichment(
    String id, {
    String? title,
    String? description,
    String? thumbnailPath,
    List<String>? mlLabels,
    required DumpEnrichmentStatus status,
  }) async {
    final existing = getById(id);
    if (existing == null) return;
    final updated = existing.copyWith(
      autoTitle: title ?? existing.autoTitle,
      autoDescription: description ?? existing.autoDescription,
      thumbnailPath: thumbnailPath ?? existing.thumbnailPath,
      mlLabels: mlLabels ?? existing.mlLabels,
      enrichmentStatus: status,
    );
    await update(updated);
  }

  Future<void> delete(String id) async {
    final box = _box;
    if (box == null) return;
    await box.delete(id);
  }

  /// Items left in [DumpUploadStatus.pendingAuth] — picked up by the
  /// DumpService after a successful session restore (R10).
  List<DumpItem> getPendingAuthItems() {
    final box = _box;
    if (box == null) return const <DumpItem>[];
    return box.values
        .where((i) => i.uploadStatus == DumpUploadStatus.pendingAuth)
        .toList();
  }

  /// Stream of the current list. Emits the current snapshot first, then
  /// re-emits the full list on every box mutation.
  Stream<List<DumpItem>> watch() async* {
    final box = _box;
    if (box == null) {
      yield const <DumpItem>[];
      return;
    }
    yield box.values.toList();
    yield* box.watch().map((_) => box.values.toList());
  }

  /// Sweep stale files under [pendingDir] that do not correspond to any
  /// item in the box. Used on init to recover from a partial share
  /// receiver crash (R7 in the Dump plan).
  ///
  /// Paths are canonicalized via `package:path` before comparison so a
  /// `localCachePath` saved with one separator style (or relative form)
  /// still matches the absolute path returned by `Directory.list()`.
  /// On Windows this also normalises drive-letter case.
  Future<int> garbageCollectOrphans(Directory pendingDir) async {
    if (!await pendingDir.exists()) return 0;
    final box = _box;
    if (box == null) return 0;
    final knownPaths = box.values
        .map((i) => p.canonicalize(i.localCachePath))
        .toSet();
    var deleted = 0;
    await for (final entity in pendingDir.list()) {
      if (entity is! File) continue;
      if (knownPaths.contains(p.canonicalize(entity.path))) continue;
      try {
        await entity.delete();
        deleted++;
      } catch (e) {
        debugPrint('Failed to delete orphan ${entity.path}: $e');
      }
    }
    return deleted;
  }

  /// Convenience for tests / hot-restart: close the box. After this,
  /// `init()` must be called again.
  Future<void> close() async {
    await _box?.close();
    _box = null;
    _isInitialized = false;
  }

  /// Test-only: closes the box and resets initialization state so the
  /// next test can call `init()` against a fresh Hive directory.
  /// Mirrors the convention in `AutomateTaskService.resetForTesting`.
  @visibleForTesting
  Future<void> resetForTesting() => close();

  Future<String?> _fullSha256OfFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString();
    } catch (e) {
      debugPrint('Failed to hash $path: $e');
      return null;
    }
  }
}
