import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/core/services/bucket_health_breaker.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';

/// Persists [BucketHealthBreaker] state across page loads.
///
/// WHY: the breaker's whole value is "don't issue a request we know will
/// fail", but the stall it prevents is paid on the FIRST read of a
/// session. Measured on the phone (capture 3, 2026-08-22): a fresh load of
/// /app/#/websites issued the legacy `tag-metadata` forest-root GET at
/// t=7.1s, it 500'd after 30.6s, and NOTHING else on the wire moved until
/// it returned — `load_forest` holds the wasm bridge's exclusive
/// per-client lock the entire time and the FRB binding gives Dart no
/// cancel handle, so the 5s Dart timeout freed our future but not the
/// lock. In-memory-only state meant every reload re-paid that 30s.
///
/// Storage: plain `localStorage`, NOT the encrypted Hive cache. The
/// payload is bucket names (app constants) plus timestamps — no user
/// content — and it must be readable synchronously at boot, before the
/// KEK-derived cache key exists.
///
/// Identity: stamped with the same `ownerHash` the listing cache uses; a
/// mismatch reads as empty. Belt and braces, because [BucketHealthBreaker.reset]
/// (called from `FulaApiService.reset()` on sign-out) fires `onChanged`
/// and therefore clears the stored copy as well — a persisted cooldown
/// must never outlive the account it was learned in.
class WebBreakerPersistence {
  WebBreakerPersistence._();
  static final WebBreakerPersistence instance = WebBreakerPersistence._();

  static const String _key = 'fxfiles_bucket_breaker_v1';

  String? _owner;
  bool _wired = false;

  /// Restore any saved cooldowns and start persisting future changes.
  /// Safe to call before sign-in (no owner → nothing restored, and the
  /// first post-sign-in change re-stamps the record).
  Future<void> init() async {
    _owner = await _ownerHash();
    _restore();
    if (!_wired) {
      _wired = true;
      BucketHealthBreaker.instance.onChanged = _save;
    }
  }

  /// Re-read identity after sign-in so writes are stamped for the right
  /// account (init() runs before the session is restored on a cold load).
  Future<void> refreshOwner() async {
    final owner = await _ownerHash();
    if (owner == _owner) return;
    _owner = owner;
    _restore();
  }

  Future<String?> _ownerHash() async {
    try {
      // Reuse the listing cache's identity rule rather than reinventing it
      // — same sha256-of-derivation-email the rest of the web shell scopes
      // by, so the two records agree about who they belong to, and no
      // email (encoded or otherwise) lands in localStorage.
      return await WebListingCache.instance.ownerHash();
    } catch (_) {
      return null;
    }
  }

  void _restore() {
    try {
      final raw = web.window.localStorage.getItem(_key);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['owner'] != _owner) {
        // Another account's record (or pre-sign-in). Never apply it.
        return;
      }
      final buckets = j['buckets'] as Map<String, dynamic>? ?? const {};
      final saved = <String, ({int failures, DateTime until})>{};
      buckets.forEach((bucket, v) {
        final m = v as Map<String, dynamic>;
        saved[bucket] = (
          failures: (m['n'] as num).toInt(),
          until: DateTime.fromMillisecondsSinceEpoch((m['u'] as num).toInt()),
        );
      });
      BucketHealthBreaker.instance.importState(saved);
    } catch (e) {
      // A malformed/legacy record is a miss, never an error.
      debugPrint('WebBreakerPersistence: restore skipped: $e');
    }
  }

  void _save() {
    try {
      final state = BucketHealthBreaker.instance.exportState();
      if (state.isEmpty || _owner == null) {
        web.window.localStorage.removeItem(_key);
        return;
      }
      web.window.localStorage.setItem(
        _key,
        jsonEncode({
          'v': 1,
          'owner': _owner,
          'buckets': {
            for (final e in state.entries)
              e.key: {
                'n': e.value.failures,
                'u': e.value.until.millisecondsSinceEpoch,
              },
          },
        }),
      );
    } catch (e) {
      // Quota/private-mode failures must never break a read path.
      debugPrint('WebBreakerPersistence: save skipped: $e');
    }
  }
}
