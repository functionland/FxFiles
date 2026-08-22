import 'package:flutter/foundation.dart';

/// Per-bucket circuit breaker for forest-root loads.
///
/// WHY THIS EXISTS (measured, not theoretical — two Chrome net-export
/// captures from a phone, 2026-08-22):
///
/// The gc-damaged legacy buckets (`tag-metadata`, `archives`, …  see
/// [BucketVersionResolver]'s header) return HTTP 500
/// `block store error: operation timed out after 30s` for their forest
/// ROOT object. The client had no memory of that, so every screen open
/// re-issued the identical request for the identical CID and paid another
/// 30 s. In one 224 s capture, **five such requests accounted for 151 s
/// (68 %) of the whole session**, all re-fetching just two CIDs.
///
/// That is much worse than wasted latency, because of two amplifiers:
///
///  1. `load_forest` in the FRB bridge holds an EXCLUSIVE writer guard on
///     a single per-client `RwLock` across the entire network fetch
///     (`fula-api/crates/fula-flutter/src/api/forest.rs:29`; `get_flat` is
///     a reader on the same lock at `:148`). FxFiles uses one singleton
///     client, so a 30 s doomed load blocks EVERY other fula call —
///     listings, downloads, share-token creation. A Dart `.timeout()`
///     cannot help: the FRB binding exposes no cancel handle, so the Rust
///     future keeps running and keeps the lock after Dart gives up.
///  2. The 500 trips the SDK health gate, which marks the whole master
///     down for `healthGateTtlSeconds` (30 s).
///
/// Since the request cannot be cancelled once issued, the only effective
/// remedy is to NOT ISSUE IT. This class remembers a bucket that just
/// failed and short-circuits the next attempts for a bounded, expiring
/// window.
///
/// Relationship to the deliberate no-caching comment in
/// `FulaApiService._ensureForestLoaded`: that comment says a failed forest
/// load must NOT be remembered, so a transient outage self-heals when
/// master returns. This is the bounded refinement of that rule, not a
/// reversal — the cooldown EXPIRES (30 s → 2 min → 5 min), and any success
/// clears it outright. Self-healing is preserved; the 30 s-per-read tax is
/// not.
///
/// COVERAGE BOUNDARY: this sits at the forest-ROOT load. Every 500 in both
/// captures is exactly that. A 500 on an individual block mid-walk, after
/// the forest is already loaded, is NOT covered — don't claim otherwise.
///
/// Pure Dart + injectable clock by design: no `package:web`, no
/// FulaApiService import, so this and its tests run under the VM (same
/// pattern as `web_l1_budget.dart` / `web_swr_policy.dart`).
class BucketHealthBreaker {
  BucketHealthBreaker();

  static final BucketHealthBreaker instance = BucketHealthBreaker();

  /// Master switch. **Off by default so native behaviour is byte-identical**
  /// — only the web shell bootstrap (`main_web.dart`) turns it on. The
  /// stalls this fixes are a web-shell problem (one wasm client, one lock,
  /// a prefetcher walking every bucket); native has its own block cache and
  /// storage tiers and is out of scope here.
  static bool enabled = false;

  /// Cooldown ladder, indexed by consecutive-failure count. Capped at the
  /// last entry. Deliberately short at the start: a genuinely transient
  /// blip costs at most one skipped read, while a permanently broken
  /// bucket backs off hard and stops dominating every session.
  ///
  /// The 1h tail exists because the damage is not transient — the same
  /// `tag-metadata` forest-root CID has failed identically across three
  /// phone captures weeks apart. Paired with [exportState]/[importState]
  /// persistence, that turns "30s on every page load" into "30s once an
  /// hour, worst case".
  ///
  /// TRADE-OFF, stated plainly: once the gateway is repaired the client
  /// can sit in a stale cooldown for up to an hour before it notices.
  /// Signing out clears it immediately (see [reset]).
  static const List<Duration> cooldownLadder = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 10),
    Duration(hours: 1),
  ];

  /// Fired after any state change so a shell can persist the result.
  /// The web shell sets this; native leaves it null. Deliberately NOT
  /// fired by [importState] — restoring at boot must not write back.
  void Function()? onChanged;

  /// Overridable for tests — production always uses the wall clock.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  final Map<String, _BucketState> _state = <String, _BucketState>{};

  /// True when [bucket] is inside a cooldown window and the caller should
  /// throw [BucketCooldownException] instead of touching the network.
  /// Always false while [enabled] is false.
  bool shouldSkip(String bucket) {
    if (!enabled) return false;
    final s = _state[bucket];
    if (s == null) return false;
    if (clock().isBefore(s.until)) return true;
    // Window elapsed — let the next attempt through, but KEEP the failure
    // count so a still-broken bucket escalates up the ladder instead of
    // restarting at 30 s every time.
    return false;
  }

  /// When [bucket] is cooling down, how much longer. Null otherwise.
  /// Diagnostics only.
  Duration? remaining(String bucket) {
    final s = _state[bucket];
    if (s == null) return null;
    final now = clock();
    return now.isBefore(s.until) ? s.until.difference(now) : null;
  }

  /// Consecutive failures recorded for [bucket] (0 when healthy).
  int failureCount(String bucket) => _state[bucket]?.failures ?? 0;

  /// Record a transport/server failure and open (or extend) the cooldown.
  /// Callers must gate this on [isBreakerWorthyFailure] — a structural
  /// absence must never cool a bucket down.
  void recordFailure(String bucket) {
    final prev = _state[bucket];
    final failures = (prev?.failures ?? 0) + 1;
    final step = cooldownLadder[
        failures - 1 < cooldownLadder.length ? failures - 1 : cooldownLadder.length - 1];
    _state[bucket] = _BucketState(failures: failures, until: clock().add(step));
    debugPrint('BucketHealthBreaker: $bucket cooling down for '
        '${step.inSeconds}s (consecutive failures: $failures)');
    onChanged?.call();
  }

  /// Clear [bucket]'s state — it answered, so the ladder restarts.
  void recordSuccess(String bucket) {
    if (_state.remove(bucket) != null) {
      debugPrint('BucketHealthBreaker: $bucket recovered');
      onChanged?.call();
    }
  }

  /// Drop all state. Call on sign-out / user-switch so one account's
  /// bucket health never carries into another's session (same hygiene rule
  /// as `WebPrefetchScheduler.reset()`).
  ///
  /// Fires [onChanged] even when already empty, so the shell's persisted
  /// copy is cleared too — a stored cooldown that outlived the account it
  /// was learned in would be a bug that survives sign-out.
  void reset() {
    final had = _state.isNotEmpty;
    _state.clear();
    if (had) debugPrint('BucketHealthBreaker: reset');
    onChanged?.call();
  }

  // ------------------------------------------------------- persistence

  /// Snapshot for the shell to persist. The in-memory map alone is not
  /// enough: the stall this guards against is paid on the FIRST read of a
  /// session, so without surviving a page load the user re-pays 30s on
  /// every reload (measured — capture 3, 2026-08-22).
  Map<String, ({int failures, DateTime until})> exportState() => {
        for (final e in _state.entries)
          e.key: (failures: e.value.failures, until: e.value.until),
      };

  /// Restore a snapshot at boot. Entries whose cooldown expired long ago
  /// are dropped so a bucket that has since recovered isn't held back by
  /// ancient history; a recently-expired entry is KEPT so its failure
  /// count still drives the ladder upward instead of restarting at 30s.
  /// Never fires [onChanged].
  void importState(Map<String, ({int failures, DateTime until})> saved,
      {Duration keepExpiredFor = const Duration(hours: 6)}) {
    final now = clock();
    for (final e in saved.entries) {
      if (now.difference(e.value.until) > keepExpiredFor) continue;
      _state[e.key] =
          _BucketState(failures: e.value.failures, until: e.value.until);
    }
    if (_state.isNotEmpty) {
      debugPrint('BucketHealthBreaker: restored ${_state.length} bucket(s): '
          '${_state.keys.join(", ")}');
    }
  }
}

class _BucketState {
  const _BucketState({required this.failures, required this.until});
  final int failures;
  final DateTime until;
}

/// Thrown INSTEAD of performing a forest load, when the bucket is inside a
/// [BucketHealthBreaker] cooldown window.
///
/// This type is load-bearing for write-safety. Callers that merge a
/// `[v8, legacy]` manifest pair must treat a cooldown skip EXACTLY like a
/// failed read — i.e. "the legacy half is incomplete" — so that a
/// read-modify-write mutation aborts rather than uploading a manifest with
/// the legacy-resident entries silently missing. Tried-and-failed and
/// skipped-by-breaker are indistinguishable to the write path on purpose.
class BucketCooldownException implements Exception {
  const BucketCooldownException(this.bucket, this.retryIn);

  final String bucket;
  final Duration retryIn;

  @override
  String toString() =>
      'BucketCooldownException: skipped "$bucket" — it failed recently and '
      'is cooling down for another ${retryIn.inSeconds}s. '
      '(Not an absence: treat as an incomplete/unavailable read.)';
}

/// Whether [e] is a transport/server failure worth opening the breaker for.
///
/// Deliberately EXCLUDES structural absence: a new or empty bucket reports
/// `NoSuchKey` / `NoSuchBucket` / `Object not found: <bucket>/<key>`, and
/// cooling those down would break first-use for a brand-new account.
/// (The colon in `Object not found:` is load-bearing — it separates
/// fula-client's structured `FulaError::ObjectNotFound` from the SERVER
/// damage messages `Object not found (gc-orphaned index; …)` and
/// `Object not found in this bucket`; see the reasoning already written in
/// `lib/web/services/web_shelf_write_logic.dart`.)
///
/// Also deliberately NARROW on the positive side: it matches the specific
/// markers the gc-damaged buckets actually emit, never a bare `500` /
/// `error` substring — a CID can contain any digits, and proxies emit
/// generic text on unrelated transport blips.
bool isBreakerWorthyFailure(Object e) {
  final s = '$e';
  if (s.contains('NoSuchKey') ||
      s.contains('NoSuchBucket') ||
      s.contains('Object not found:')) {
    return false;
  }
  for (final marker in _breakerWorthyMarkers) {
    if (s.contains(marker)) return true;
  }
  return false;
}

/// Markers observed on the gc-damaged buckets, e.g.
/// `AnyhowException(S3 error (InternalError): Core error: block store
/// error: operation timed out after 30s)` and the Dart-side
/// `TimeoutException after 0:00:30.000000`.
const List<String> _breakerWorthyMarkers = <String>[
  'block store error',
  'operation timed out',
  'TimeoutException',
  'InternalError',
  'ServiceUnavailable',
  'GatewayTimeout',
  'SlowDown',
];
