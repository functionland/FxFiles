// Persistent cache of a LEGACY bucket's object listing (v8 migration, Phase 3).
//
// Legacy buckets are FROZEN once the migration is on — no new writes ever land
// there (new uploads go to `<base>-v8`). So their listing is loaded ONCE (the
// slow gc-recovery read) and cached forever; thereafter only the fresh v8
// bucket is queried live. See docs/v8-bucket-migration-plan.md §3.2/§4.1.
//
// Safety (per advisor review):
//   * Freeze only a FRESH (non-stale) load — never a stale/SDK-fallback or a
//     failed one — so we don't enshrine a partial/empty listing while the
//     master is unreachable. (A fresh EMPTY result IS frozen, so new users —
//     who have no legacy bucket — don't pay a timeout on every open.)
//   * `clear()` is the manual-refresh escape hatch if a frozen listing ever
//     turns out to have been incomplete.
//   * The Hive box is VERSION-KEYED (`legacy_listing_v1`) so a future
//     FulaObject schema change can't read stale-shaped JSON.
//
// Testability: the in-memory map is the source of truth; `init()` (which opens
// the encrypted Hive box) is optional — unit tests construct the cache and use
// it in-memory without Hive.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/utils/hive_cipher.dart';

class LegacyListingCache {
  LegacyListingCache._();
  static final LegacyListingCache instance = LegacyListingCache._();

  /// Visible for testing — construct an isolated, Hive-less instance.
  @visibleForTesting
  LegacyListingCache.forTest();

  /// Bump the suffix if the cached JSON shape changes. v2 wraps the object
  /// list with a freeze timestamp (TTL).
  static const String boxName = 'legacy_listing_v2';

  /// A frozen legacy listing self-expires after this (the B1 escape hatch): a
  /// one-off incomplete freeze self-heals within a day, while an immutable
  /// legacy bucket is otherwise re-fetched at most once/day (cheap — ~0.5-1s
  /// when healthy). Mutable so tests can force expiry. Tunable.
  static Duration freezeTtl = const Duration(days: 1);

  /// Each entry carries WHEN it was frozen, so [getFrozen] can expire it.
  final Map<String, ({DateTime frozenAt, List<FulaObject> objects})> _mem =
      <String, ({DateTime frozenAt, List<FulaObject> objects})>{};
  Box<String>? _box;
  bool _initialized = false;
  Future<void>? _initFuture;

  String _k(String userId, String bucket) => '$userId:$bucket';

  /// Open the encrypted box and hydrate the in-memory map. Idempotent AND
  /// single-flight: concurrent callers (an initial category load racing a
  /// pull-to-refresh, or two category screens opening at once) share ONE
  /// in-flight open, so the Hive box is never opened twice (a concurrent
  /// double-open can throw). `_init` swallows all errors, so the memoized
  /// future never rejects. Production calls this once at startup; tests skip
  /// it (in-memory only).
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    if (_initialized) return;
    try {
      final cipher = await getHiveMetadataCipher();
      _box = await Hive.openBox<String>(boxName, encryptionCipher: cipher);
      // Best-effort: drop the orphaned pre-TTL v1 box (superseded by v2).
      try {
        await Hive.deleteBoxFromDisk('legacy_listing_v1');
      } catch (_) {/* never block startup on cleanup */}
      for (final key in _box!.keys) {
        final raw = _box!.get(key);
        if (raw == null) continue;
        try {
          final decoded = jsonDecode(raw) as Map;
          final frozenAt = DateTime.fromMillisecondsSinceEpoch(
              (decoded['frozenAt'] as num).toInt());
          final list = (decoded['objects'] as List)
              .map((e) => FulaObject.fromJson(
                  (e as Map).cast<String, dynamic>()))
              .toList();
          _mem[key as String] = (
            frozenAt: frozenAt,
            objects: List<FulaObject>.unmodifiable(list),
          );
        } catch (e) {
          // Corrupt/old-shape entry — drop it; it'll re-freeze on next load.
          debugPrint('LegacyListingCache: dropping bad entry "$key": $e');
        }
      }
      _initialized = true;
    } catch (e) {
      // Never block startup on the cache — fall back to in-memory only.
      debugPrint('LegacyListingCache: init failed, in-memory only: $e');
      _initialized = true;
    }
  }

  /// The frozen legacy listing for (user, bucket), or null if not frozen (or
  /// the freeze has EXPIRED past [freezeTtl] — treated as never-frozen so the
  /// caller reloads + re-freezes). An EMPTY list means "frozen, genuinely
  /// empty" (do NOT re-load); null means "never frozen / expired — load it".
  List<FulaObject>? getFrozen(String userId, String bucket) {
    final entry = _mem[_k(userId, bucket)];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.frozenAt) >= freezeTtl) return null;
    return entry.objects;
  }

  /// Freeze a fresh listing. Callers MUST only call this for a non-stale,
  /// successful load (see the file header).
  Future<void> freeze(
      String userId, String bucket, List<FulaObject> objects) async {
    final key = _k(userId, bucket);
    final now = DateTime.now();
    _mem[key] =
        (frozenAt: now, objects: List<FulaObject>.unmodifiable(objects));
    try {
      await _box?.put(
        key,
        jsonEncode(<String, dynamic>{
          'frozenAt': now.millisecondsSinceEpoch,
          'objects': objects.map((o) => o.toJson()).toList(),
        }),
      );
    } catch (e) {
      debugPrint('LegacyListingCache: persist failed for "$key": $e');
    }
  }

  /// Manual-refresh escape hatch — drop the frozen listing so the next open
  /// re-loads (and re-freezes) it.
  Future<void> clear(String userId, String bucket) async {
    final key = _k(userId, bucket);
    _mem.remove(key);
    try {
      await _box?.delete(key);
    } catch (_) {
      // best-effort
    }
  }
}
