import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/bucket_health_breaker.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/web/services/web_device_class.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';
import 'package:fula_files/web/services/web_shelf_write_logic.dart'
    show isConfirmedObjectAbsence;
import 'package:fula_files/web/services/web_swr_policy.dart';

export 'package:fula_files/web/services/web_swr_policy.dart';

/// Stale-while-revalidate read path for the web shell
/// (docs/web-listing-prefetch-cache-plan.md §5.2/§5.3). Tier policy
/// lives in web_swr_policy.dart (pure Dart, VM-testable).

class SwrListing {
  /// What to render right now.
  final List<FulaObject> objects;
  final DateTime? fetchedAt;

  /// True when [objects] came from the cache (any tier).
  final bool fromCache;

  /// True when the cache entry is in the ≥ 1 h tier (stale banner).
  final bool staleTier;

  /// The live path's "served from offline fallback" flag (master down).
  final bool offlineStale;

  /// Non-null when a background revalidation was started: resolves with
  /// the fresh listing (already written to cache), or null when the
  /// revalidation failed (keep rendering the cached copy). Never throws.
  final Future<({List<FulaObject> objects, bool offlineStale})?>?
      revalidation;

  const SwrListing({
    required this.objects,
    required this.fetchedAt,
    required this.fromCache,
    required this.staleTier,
    required this.offlineStale,
    this.revalidation,
  });
}

class WebListingSwr extends ChangeNotifier {
  WebListingSwr._();
  static final WebListingSwr instance = WebListingSwr._();

  /// Single-flight per bucket — a user open and (later, P2) a prefetch
  /// of the same bucket share one network listing.
  final Map<String,
          Future<({List<FulaObject> objects, bool offlineStale})?>>
      _inFlight = {};

  /// Single-flight for background manifest refreshes, keyed bucket|key.
  final Map<String, Future<void>> _manifestRefreshes = {};

  /// This session's recent own-uploads, per bucket: the file's listing object
  /// keyed by its object key, plus when it was uploaded. The gateway's forest
  /// index has a post-write PROPAGATION WINDOW — a server forest refetch right
  /// after an upload can come back WITHOUT the just-uploaded file (the delete
  /// path documents the same window: a refetch there would *resurrect* a
  /// just-deleted file). A manual Refresh / background revalidate does exactly
  /// that refetch, so without this the file the user just uploaded vanishes
  /// from the listing until the server catches up. We merge these back into a
  /// server-fetched listing until the server shows the file or it ages out.
  /// Per-session + own-writes only, so cross-device changes still flow through
  /// and a cross-device delete wins once the window passes.
  final Map<String, Map<String, ({FulaObject obj, DateTime ts})>>
      _recentUploads = {};

  /// Safety cap: stop merging an own-upload after this long even if the server
  /// still hasn't shown it (guards against a never-propagating write).
  static const Duration _ownWriteWindow = Duration(minutes: 5);

  /// Record a file this session just uploaded so a Refresh during the
  /// propagation window doesn't hide it. [obj] is the real listing object
  /// (full metadata) captured from the own-write listing.
  void recordRecentUpload(String bucket, FulaObject obj) {
    (_recentUploads[bucket] ??= {})[obj.key] = (obj: obj, ts: DateTime.now());
  }

  /// Drop all recorded own-uploads — call on sign-out / user-switch so one
  /// user's just-uploaded filenames can never merge into another user's
  /// listing.
  void clearRecentUploads() => _recentUploads.clear();

  /// Merge this session's recent own-uploads into a freshly server-fetched
  /// [serverObjects] listing for [bucket]: first drop entries the server now
  /// shows or that have aged past [_ownWriteWindow], then re-add whatever
  /// remains (recent + still missing from the server). Returns the list to
  /// cache + render. A no-op once the server has caught up.
  List<FulaObject> _mergeRecentUploads(
      String bucket, List<FulaObject> serverObjects) {
    final recent = _recentUploads[bucket];
    if (recent == null || recent.isEmpty) return serverObjects;
    final now = DateTime.now();
    final serverKeys = serverObjects.map((o) => o.key).toSet();
    recent.removeWhere((key, v) =>
        serverKeys.contains(key) || now.difference(v.ts) > _ownWriteWindow);
    if (recent.isEmpty) return serverObjects;
    return [...serverObjects, for (final v in recent.values) v.obj];
  }

  bool _onlineHooked = false;
  DateTime? _hiddenAt;

  /// How long a tab must have been hidden before its resume triggers a
  /// forced revalidate (short app switches shouldn't re-list).
  static const Duration kResumeRefreshAfter = Duration(minutes: 5);

  /// Notifies listeners when the browser regains connectivity, OR when
  /// the tab resumes after being hidden ≥ [kResumeRefreshAfter] —
  /// screens respond with a silent forced revalidate. The resume
  /// trigger is what heals a LONG-LIVED mobile tab: cross-device
  /// changes accumulate exactly while it sleeps (real two-client bug,
  /// 2026-06-12).
  void ensureOnlineHook() {
    if (_onlineHooked) return;
    _onlineHooked = true;
    web.window.addEventListener(
      'online',
      ((web.Event _) {
        debugPrint('WebListingSwr: online again — notifying screens');
        notifyListeners();
      }).toJS,
    );
    web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        if (web.document.visibilityState == 'visible') {
          final hiddenAt = _hiddenAt;
          _hiddenAt = null;
          if (hiddenAt != null &&
              DateTime.now().difference(hiddenAt) > kResumeRefreshAfter) {
            debugPrint('WebListingSwr: tab resumed after long sleep — '
                'notifying screens');
            notifyListeners();
          }
        } else {
          _hiddenAt = DateTime.now();
        }
      }).toJS,
    );
    // (The 0.6.7-era interim — rebuilding the whole wasm client on
    // these triggers — is gone: since fula_client 0.6.9 the force
    // path's per-bucket invalidateForestCache gives true cross-device
    // freshness at a fraction of the cost.)
  }

  // ------------------------------------------------------- listings

  /// SWR read of one bucket's listing.
  ///
  /// force=true bypasses the cache READ and awaits the live listing,
  /// then updates the cache. [refetchForest] (default: follows force)
  /// additionally drops the session forest so the listing comes from
  /// the SERVER: right for cross-device intent (Refresh button,
  /// resume, reconnect), WRONG after this client's OWN mutation — the
  /// uploader's in-memory forest is AHEAD of the server for a few
  /// seconds after a write, and refetching during that window made a
  /// just-uploaded file vanish (real regression, 2026-06-12). Mutation
  /// callers pass refetchForest: false.
  Future<SwrListing> getListing(String bucket,
      {bool force = false, bool? refetchForest}) async {
    // Frecency signal for the prefetch queue — user-driven reads only
    // (the scheduler's own warm-ups must not self-reinforce).
    unawaited(WebListingCache.instance.recordUsage('cat|$bucket'));
    return _getListing(bucket,
        force: force, refetchForest: refetchForest ?? force);
  }

  Future<SwrListing> _getListing(String bucket,
      {required bool force, required bool refetchForest}) async {
    if (!force) {
      final cached = await WebListingCache.instance.readListing(bucket);
      if (cached != null) {
        var age = DateTime.now().difference(cached.fetchedAt);
        // A FUTURE stamp (device clock moved back after the write)
        // would otherwise pin the entry in the fresh tier forever and
        // make the monotonic write guard reject every update. Treat
        // it as maximally stale instead.
        if (age.isNegative) age = const Duration(days: 365);
        final tier = swrTierForAge(age);
        return SwrListing(
          objects: cached.objects,
          fetchedAt: cached.fetchedAt,
          fromCache: true,
          staleTier: tier == SwrTier.stale,
          offlineStale: false,
          revalidation: tier == SwrTier.fresh ? null : _revalidate(bucket),
        );
      }
    }

    // Miss: if a background flight for this bucket is already running
    // (revalidation now, prefetch in P2), join it instead of starting
    // a second full listing. Its failure (null) falls through to the
    // owned live-first path so error semantics stay the screen's.
    if (!force) {
      final shared = _inFlight[bucket];
      if (shared != null) {
        final r = await shared;
        if (r != null) {
          return SwrListing(
            objects: r.objects,
            fetchedAt: DateTime.now(),
            fromCache: false,
            staleTier: false,
            offlineStale: r.offlineStale,
          );
        }
      }
    }

    // Miss (or force): live-first — same semantics the screen had
    // before SWR, including listObjectsCached's offline fallback.
    // refetchForest drops the session's forest (Dart memo + the Rust
    // client's copy, 0.6.9): cross-device refreshes only — own-write
    // reloads keep the session forest, which is the freshest copy.
    if (refetchForest) {
      await FulaApiService.instance.invalidateForestCache(bucket);
    }
    final r = await FulaApiService.instance.listObjectsCached(bucket);
    // Keep this session's just-uploaded files visible through the gateway's
    // post-write forest propagation window. Merge for the render regardless of
    // freshness (the merge dedups, so it's a no-op once the server shows the
    // file); only PERSIST when we actually got a fresh server listing — an
    // offline-stale result leaves the good cache untouched.
    final objects = _mergeRecentUploads(bucket, r.objects);
    if (!r.stale) {
      await WebListingCache.instance
          .writeListing(bucket, objects, fetchedAt: r.fetchedAt);
    }
    return SwrListing(
      objects: objects,
      fetchedAt: r.fetchedAt,
      fromCache: false,
      staleTier: false,
      offlineStale: r.stale,
    );
  }

  // ------------------------------------------------------- prefetch

  /// Scheduler entry (P2): always-live listing through the shared
  /// single-flight — warms the bucket's forest in wasm AND rewrites
  /// the cache. Returns false on failure (drives the scheduler's
  /// poison/3-strike logic). Never records usage.
  Future<bool> prefetchListing(String bucket) async {
    final r = await _revalidate(bucket);
    return r != null;
  }

  /// Scheduler entry (P2): warm one manifest pair — awaited live v8
  /// half (tiny GET; the win is the metadata bucket's forest), frozen
  /// legacy half as usual. Failures self-heal through normal SWR, so
  /// completion always counts as done. Cross-device warm-up →
  /// refetchForest.
  Future<void> prefetchManifest(
      String base, String key, Uint8List encryptionKey) {
    return downloadMetadataMergedSwr(base, key, encryptionKey,
        force: true, recordUsage: false, refetchForest: true);
  }

  /// Background revalidate: plain live listing (no offline-fallback
  /// double-jeopardy — on failure the caller keeps the cached render).
  /// NoSuchBucket counts as a successful EMPTY listing (the category
  /// has no -v8 bucket yet — the screen's normal empty state).
  Future<({List<FulaObject> objects, bool offlineStale})?> _revalidate(
      String bucket) {
    final existing = _inFlight[bucket];
    if (existing != null) return existing;
    final future = () async {
      // Stamp at fetch START: if a forced mutation write lands while
      // this is in flight, its newer stamp wins the cache and this
      // result is discarded by the monotonic guard.
      final started = DateTime.now();
      try {
        // Revalidation MUST be fresh-from-server: without dropping the
        // forest (Dart memo + Rust copy), a long-lived session lists
        // its stale in-memory forest and re-stamps pre-existing data
        // as fresh — the cache could then never pick up another
        // device's uploads (real two-client bug, 2026-06-12).
        await FulaApiService.instance.invalidateForestCache(bucket);
        final fetched = await FulaApiService.instance
            .listObjects(bucket)
            .timeout(const Duration(seconds: 30));
        // Same propagation-window protection as the live path: don't let a
        // background revalidate drop a file this session just uploaded.
        final objects = _mergeRecentUploads(bucket, fetched);
        await WebListingCache.instance
            .writeListing(bucket, objects, fetchedAt: started);
        return (objects: objects, offlineStale: false);
      } catch (e) {
        final msg = '$e';
        if (msg.contains('NoSuchBucket') ||
            msg.contains('bucket not found')) {
          await WebListingCache.instance.writeListing(
              bucket, const <FulaObject>[],
              fetchedAt: started);
          return (objects: const <FulaObject>[], offlineStale: false);
        }
        debugPrint('WebListingSwr: revalidate($bucket) failed: $e');
        return null;
      }
    }()
        // Block body, NOT an arrow: Map.remove returns the removed
        // value — this very future — and whenComplete AWAITS a future
        // returned from its callback, deadlocking the future on
        // itself. (Found live by the e2e=swr gate.)
        .whenComplete(() {
      _inFlight.remove(bucket);
    });
    _inFlight[bucket] = future;
    return future;
  }

  // ------------------------------------------------------ manifests

  /// SWR sibling of FulaApiService.downloadMetadataMerged, same
  /// [v8, legacy] blob order and same never-throws contract:
  ///
  ///  - v8 half: served from cache when present; refreshed in the
  ///    background past the fresh window (cache-only update — the next
  ///    open reads it; in-place screen patching arrives with P2's
  ///    notifications). force=true awaits the live fetch (mutation
  ///    paths need read-modify-write freshness), falling back to the
  ///    cached blob on a live failure — strictly safer than the
  ///    uncached behavior, which would have dropped the blob.
  ///  - legacy half: immutable post-migration → fetched ONCE per user
  ///    and frozen forever (including frozen absence). Steady-state
  ///    cost is one GET instead of two.
  /// [refetchForest] defaults FALSE here (opposite of listings): the
  /// dominant force callers are SERVICE MUTATIONS doing
  /// merge-before-overwrite, where a server-lagging manifest read
  /// could clobber this client's own recent writes. Only explicit
  /// cross-device refreshes (screen Refresh buttons) pass true.
  Future<List<Uint8List>> downloadMetadataMergedSwr(
    String base,
    String key,
    Uint8List encryptionKey, {
    bool force = false,
    bool recordUsage = true,
    bool refetchForest = false,
  }) async {
    if (recordUsage) {
      // recordUsage doubles as "user-driven": frecency signal AND a
      // foreground-activity window so the prefetcher yields. The
      // scheduler passes recordUsage=false and stays out of both.
      unawaited(WebListingCache.instance.recordUsage('man|$base'));
      return WebForegroundActivity.instance.run(
          () => _downloadMetadataMergedSwr(base, key, encryptionKey,
              force: force, refetchForest: refetchForest));
    }
    return _downloadMetadataMergedSwr(base, key, encryptionKey,
        force: force, refetchForest: refetchForest);
  }

  Future<List<Uint8List>> _downloadMetadataMergedSwr(
    String base,
    String key,
    Uint8List encryptionKey, {
    required bool force,
    required bool refetchForest,
  }) async {
    final v8 = BucketVersionResolver.writeBucket(base);
    final blobs = <Uint8List>[];

    // ----- v8 (or sole unmanaged bucket) half -----
    // Keeps the full budget: this is the live, authoritative half, and a
    // legitimately slow mobile link needs the headroom.
    final v8Blob = await _manifestHalf(
      bucket: v8,
      key: key,
      encryptionKey: encryptionKey,
      force: force,
      refetchForest: refetchForest,
      frozen: false,
      budget: _kManifestBudget,
    );
    if (v8Blob != null) blobs.add(v8Blob);

    // ----- legacy half (only when managed) -----
    // Best-effort by construction: legacy metadata buckets are immutable
    // post-migration and NEVER written (writes route to `-v8`, and
    // isForbiddenWriteTarget throws otherwise), so a missing legacy half
    // can only delay what the user SEES — it can never change what gets
    // written. That is what makes the short budget safe.
    //
    // The short budget applies to EVERY read, forced or not. An earlier
    // version kept the full 30s for forced reads "so a mutation gets the
    // real answer" — that was wrong twice over:
    //
    //  * `force` is about getting FRESH data, and this half is frozen and
    //    immutable (note the hardcoded `force: false` below — the outer
    //    force flag was never meant to reach it). "Fresh legacy" is a
    //    contradiction, so there is nothing to wait 30s for.
    //  * every forced path therefore re-paid the stall. The website DETAIL
    //    screen forces on open, so opening a site still hung for 30s even
    //    after the list itself was fixed (user report + capture 6).
    if (v8 != base) {
      final legacyBlob = await _manifestHalf(
        bucket: base,
        key: key,
        encryptionKey: encryptionKey,
        force: false, // frozen — force never re-fetches legacy
        refetchForest: false,
        frozen: true,
        budget: _kLegacyRenderBudget,
      );
      if (legacyBlob != null) blobs.add(legacyBlob);
    }
    return blobs;
  }

  /// Full budget for the live/authoritative half.
  static const Duration _kManifestBudget = Duration(seconds: 30);

  /// Budget for the frozen legacy half — every read, forced or not. The gateway
  /// takes ~30s to fail a gc-damaged legacy forest root, and that whole
  /// time is spent holding the wasm bridge's exclusive per-client lock —
  /// so the old shared 30s budget put a 30s stall in front of every
  /// screen that reads a manifest. Five seconds is generous for a healthy
  /// legacy read (every healthy request in both phone captures finished
  /// in under 0.9s) and cheap when it is broken. After the first failure
  /// BucketHealthBreaker skips the call entirely.
  static const Duration _kLegacyRenderBudget = Duration(seconds: 5);

  Future<Uint8List?> _manifestHalf({
    required String bucket,
    required String key,
    required Uint8List encryptionKey,
    required bool force,
    required bool refetchForest,
    required bool frozen,
    required Duration budget,
  }) async {
    final cached = await WebListingCache.instance.readManifest(bucket, key);

    if (cached != null && !force) {
      if (!frozen) {
        var age = DateTime.now().difference(cached.fetchedAt);
        if (age.isNegative) age = const Duration(days: 365);
        if (swrTierForAge(age) != SwrTier.fresh) {
          _refreshManifestBehind(bucket, key, encryptionKey);
        }
      }
      return cached.blob;
    }

    // FROZEN LEGACY HALF, not cached: NEVER fetch it on the caller's path.
    //
    // Reading a manifest goes through its bucket's forest, and
    // `load_forest` takes the wasm bridge's EXCLUSIVE per-client lock for
    // the whole fetch. On a gc-damaged legacy bucket that is ~30s, during
    // which every other fula call in the tab is stuck behind it. Captured
    // live on the phone:
    //
    //   loadForest: ENTER tag-metadata          <- doomed, holds the lock
    //   getFlat:    ENTER website-metadata-v8/… <- never completes
    //   loadForest: ENTER tag-metadata-v8       <- never completes (healthy
    //                                              bucket, normally 0.1s!)
    //   WebsiteDetail: loadWebsites ENTER       <- never completes
    //
    // So one dead LEGACY bucket froze a screen that only needed HEALTHY
    // v8 data. Deferring the fetch to idle is not merely tidier — it is
    // the difference between the screen painting and not.
    //
    // What this costs: legacy-only entries appear one screen-open later
    // instead of immediately. That is the SWR contract the rest of this
    // file already follows, and for the bucket that motivated it the cost
    // is zero — it has returned 500 on every capture, so those entries do
    // not arrive today either. A `force` read (mutation read-modify-write)
    // still takes the live path below; correctness is unchanged because
    // managed metadata services only ever WRITE to the `-v8` bucket.
    if (frozen && !force) {
      _backfillFrozenHalf(bucket, key, encryptionKey);
      return null;
    }

    // Miss, or force on the mutable half: live fetch. Cross-device
    // refreshes drop the forest first (manifests are read THROUGH the
    // bucket's forest); mutation reads keep the session forest — it
    // already reflects this client's own writes.
    final started = DateTime.now();
    try {
      if (refetchForest) {
        await FulaApiService.instance.invalidateForestCache(bucket);
      }
      final blob = await FulaApiService.instance
          .downloadAndDecrypt(bucket, key, encryptionKey)
          .timeout(budget);
      final value = blob.isEmpty ? null : blob;
      await WebListingCache.instance
          .writeManifest(bucket, key, value, fetchedAt: started);
      return value;
    } catch (e) {
      debugPrint('WebListingSwr: manifest $bucket/$key miss: $e');
      if (cached != null) {
        // force-path live failure: the cached blob is still the best
        // truth available — never worse than the uncached code path.
        return cached.blob;
      }
      // Negative-cache ONLY a structurally confirmed absence. A
      // transient transport error (or any generic message that merely
      // contains "404"/"not found" — proxies do that) must not be
      // remembered: on the frozen legacy half it would freeze a false
      // "doesn't exist" forever (Gemini-flagged).
      if (_isConfirmedAbsence(e)) {
        await WebListingCache.instance
            .writeManifest(bucket, key, null, fetchedAt: started);
      }
      return null;
    }
  }

  /// Strict S3-style absence codes only — used to gate NEGATIVE cache
  /// writes (including the legacy freeze). Deliberately narrower than
  /// FulaApiService._isNotFoundError's broad match.
  ///
  /// Single-sourced from `web_shelf_write_logic.dart` (2026-08-22). This
  /// used to be a second, DIVERGENT copy that matched only NoSuchKey /
  /// NoSuchBucket — it missed fula-client's actual structured absence
  /// string `Object not found: <bucket>/<key>`. Consequence: a legacy
  /// manifest that genuinely does not exist was never frozen as absent,
  /// so every single read re-fetched it live, and on a gc-damaged bucket
  /// that cost 30s each time. A cooldown skip is NOT an absence — it is
  /// an unavailable read — so BucketCooldownException must never reach
  /// here as "confirmed".
  static bool _isConfirmedAbsence(Object e) {
    if (e is BucketCooldownException) return false;
    return isConfirmedObjectAbsence(e);
  }

  /// One-shot background fetch of a FROZEN (legacy, immutable) manifest
  /// half that isn't cached yet. Runs only once the tab is idle, so its
  /// forest load can't hold the wasm bridge's per-client lock while the
  /// user is waiting on a screen. Result lands in the cache, so the NEXT
  /// read serves it instantly and this never runs again for that key.
  ///
  /// Single-flighted on the same map as [_refreshManifestBehind], under a
  /// distinct key prefix so the two can't collide.
  /// How long a known-bad bucket is left completely alone by the
  /// backfill. A probe is not free here: it costs every other fula call
  /// in the tab ~30s behind the wasm bridge's per-client lock, so once a
  /// bucket has failed the correct number of speculative retries is
  /// approximately zero. A user-driven `force` read still bypasses this.
  static const Duration _kFrozenBackfillQuiet = Duration(hours: 6);

  /// Settle before backfilling. `whenIdle()` alone is NOT a deferral:
  /// the foreground counter hits zero in the microseconds BETWEEN two
  /// screen operations, so a naive `await whenIdle()` fires immediately
  /// and lands the lock-holding forest load right in the middle of the
  /// screen load it was supposed to avoid (observed on the phone,
  /// 2026-08-22 — the backfill's 5s timeout expired while the detail
  /// screen was still loading). A wall-clock delay plus a re-check is
  /// what actually moves it out of the way.
  static const Duration _kFrozenBackfillDelay = Duration(seconds: 15);

  void _backfillFrozenHalf(
      String bucket, String key, Uint8List encryptionKey) {
    final k = 'frozen|$bucket|$key';
    if (_manifestRefreshes.containsKey(k)) return;
    // Known bad → don't probe at all. This is what stops the ladder from
    // re-authorising a 30s tab freeze every time a cooldown lapses.
    if (BucketHealthBreaker.instance
        .failedRecently(bucket, _kFrozenBackfillQuiet)) {
      return;
    }
    final future = () async {
      // Wall-clock first, THEN idle — see _kFrozenBackfillDelay.
      await Future<void>.delayed(_kFrozenBackfillDelay);
      await WebForegroundActivity.instance
          .whenIdle()
          .timeout(const Duration(seconds: 60), onTimeout: () {});
      // A burst of taps shouldn't interleave with this (same settle the
      // prefetch scheduler uses).
      await Future<void>.delayed(const Duration(seconds: 1));
      // Re-check: the bucket may have been marked bad while we waited,
      // and the whole point is to not touch it once we know.
      if (BucketHealthBreaker.instance
          .failedRecently(bucket, _kFrozenBackfillQuiet)) {
        return;
      }
      // Stamp AFTER the wait (monotonic guard rule: stamp at fetch START),
      // so a mutation write-through landing during the wait still wins.
      final started = DateTime.now();
      try {
        final blob = await FulaApiService.instance
            .downloadAndDecrypt(bucket, key, encryptionKey)
            .timeout(_kLegacyRenderBudget);
        await WebListingCache.instance.writeManifest(
            bucket, key, blob.isEmpty ? null : blob,
            fetchedAt: started);
        debugPrint('WebListingSwr: backfilled frozen half $bucket/$key');
      } catch (e) {
        debugPrint('WebListingSwr: frozen-half backfill $bucket/$key: $e');
        // Only a STRUCTURALLY confirmed absence may be frozen as "gone" —
        // a transport failure here must stay retryable (the breaker is
        // what stops it from being retried in a tight loop).
        if (_isConfirmedAbsence(e)) {
          await WebListingCache.instance
              .writeManifest(bucket, key, null, fetchedAt: started);
        }
      }
    }()
        // Same whenComplete-returns-the-removed-future trap as
        // _revalidate — keep the block body.
        .whenComplete(() {
      _manifestRefreshes.remove(k);
    });
    _manifestRefreshes[k] = future;
  }

  void _refreshManifestBehind(
      String bucket, String key, Uint8List encryptionKey) {
    final k = '$bucket|$key';
    if (_manifestRefreshes.containsKey(k)) return;
    final future = () async {
      // Low-end devices: DEFER (never skip) until the foreground work
      // that triggered this read has finished — a behind-refresh's
      // forest drop + fetch + wasm decrypt competing with a screen open
      // is part of the mobile freeze. Bounded so a busy screen can't
      // starve refreshes forever. The single-flight map above keeps
      // holding this future during the wait, so repeat triggers no-op.
      if (WebDeviceClass.lowEnd) {
        await WebForegroundActivity.instance
            .whenIdle()
            .timeout(const Duration(seconds: 30), onTimeout: () {});
      }
      // Stamp AFTER the deferral (monotonic guard rule: "stamp at fetch
      // START") — a mutation write-through landing during the wait
      // carries a newer stamp and must win the cache.
      final started = DateTime.now();
      try {
        await FulaApiService.instance.invalidateForestCache(bucket);
        final blob = await FulaApiService.instance
            .downloadAndDecrypt(bucket, key, encryptionKey)
            .timeout(const Duration(seconds: 30));
        await WebListingCache.instance.writeManifest(
            bucket, key, blob.isEmpty ? null : blob,
            fetchedAt: started);
      } catch (e) {
        debugPrint('WebListingSwr: behind-refresh $bucket/$key: $e');
        if (_isConfirmedAbsence(e)) {
          await WebListingCache.instance
              .writeManifest(bucket, key, null, fetchedAt: started);
        }
      }
    }()
        // Same whenComplete-returns-the-removed-future trap as
        // _revalidate — keep the block body.
        .whenComplete(() {
      _manifestRefreshes.remove(k);
    });
    _manifestRefreshes[k] = future;
  }
}
