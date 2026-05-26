import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:fula_files/core/utils/hive_cipher.dart';

/// Device-local persistence for "user said no thanks to suggesting this
/// tag for this dump". Keyed by dump id, value is a JSON-encoded list
/// of dismissed tag ids.
///
/// Intentionally NOT cloud-synced — dismissals are UX preference, not
/// content; replicating them across devices would just mask better
/// suggestions on a second device with a different mental model. If
/// this assumption changes later, the box shape is already a small
/// JSON map and can be promoted to a cloud manifest the same way
/// `TagStorageService` syncs its metadata.
class ShelfSuggestionDismissalsService {
  ShelfSuggestionDismissalsService._();
  static final ShelfSuggestionDismissalsService instance =
      ShelfSuggestionDismissalsService._();

  static const String _boxName = 'dump_suggestion_dismissals';

  Box<String>? _box;
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized && (_box?.isOpen ?? false);

  /// Mirrors the listener pattern used by [TagStorageService] so the
  /// Riverpod provider can re-evaluate when dismissals change without
  /// fighting Hive's per-key streams.
  final List<VoidCallback> _listeners = <VoidCallback>[];

  Future<void> init() async {
    if (isInitialized) return;
    try {
      final cipher = await getHiveMetadataCipher();
      _box = await _openEncryptedBox(cipher);
      _isInitialized = true;
      debugPrint(
        'ShelfSuggestionDismissalsService initialized with ${_box!.length} entries',
      );
    } catch (e) {
      debugPrint('ShelfSuggestionDismissalsService init failed: $e');
    }
  }

  Future<Box<String>> _openEncryptedBox(HiveAesCipher cipher) async {
    try {
      return await Hive.openBox<String>(_boxName, encryptionCipher: cipher);
    } catch (e) {
      debugPrint(
        'ShelfSuggestionDismissalsService: reopening "$_boxName" fresh after open error: $e',
      );
      await Hive.deleteBoxFromDisk(_boxName);
      return await Hive.openBox<String>(_boxName, encryptionCipher: cipher);
    }
  }

  void addListener(VoidCallback cb) => _listeners.add(cb);
  void removeListener(VoidCallback cb) => _listeners.remove(cb);

  void _notify() {
    for (final cb in List<VoidCallback>.from(_listeners)) {
      try {
        cb();
      } catch (e) {
        debugPrint('ShelfSuggestionDismissalsService listener threw: $e');
      }
    }
  }

  /// Sync read. Empty set if no entry exists (or service is not yet
  /// initialised — caller treats absence as "no dismissals so far").
  Set<String> getDismissedFor(String dumpId) {
    if (!isInitialized) return const <String>{};
    final raw = _box!.get(dumpId);
    if (raw == null || raw.isEmpty) return const <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>{};
      return decoded.cast<String>().toSet();
    } catch (e) {
      debugPrint('ShelfSuggestionDismissalsService: decode failed for $dumpId: $e');
      return const <String>{};
    }
  }

  Future<void> dismiss(String dumpId, String tagId) async {
    if (!isInitialized) return;
    final current = getDismissedFor(dumpId).toSet();
    if (!current.add(tagId)) return; // already dismissed — no-op
    await _box!.put(dumpId, jsonEncode(current.toList()));
    _notify();
  }

  Future<void> undismiss(String dumpId, String tagId) async {
    if (!isInitialized) return;
    final current = getDismissedFor(dumpId).toSet();
    if (!current.remove(tagId)) return;
    if (current.isEmpty) {
      await _box!.delete(dumpId);
    } else {
      await _box!.put(dumpId, jsonEncode(current.toList()));
    }
    _notify();
  }

  /// Called when a dump item is deleted — drops the whole entry so
  /// the box doesn't accumulate orphan keys.
  Future<void> clearAll(String dumpId) async {
    if (!isInitialized) return;
    if (!_box!.containsKey(dumpId)) return;
    await _box!.delete(dumpId);
    _notify();
  }
}
