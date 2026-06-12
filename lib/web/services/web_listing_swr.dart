import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';
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
    if (!r.stale) {
      await WebListingCache.instance
          .writeListing(bucket, r.objects, fetchedAt: r.fetchedAt);
    }
    return SwrListing(
      objects: r.objects,
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
        final objects = await FulaApiService.instance
            .listObjects(bucket)
            .timeout(const Duration(seconds: 30));
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
    final v8Blob = await _manifestHalf(
      bucket: v8,
      key: key,
      encryptionKey: encryptionKey,
      force: force,
      refetchForest: refetchForest,
      frozen: false,
    );
    if (v8Blob != null) blobs.add(v8Blob);

    // ----- legacy half (only when managed) -----
    if (v8 != base) {
      final legacyBlob = await _manifestHalf(
        bucket: base,
        key: key,
        encryptionKey: encryptionKey,
        force: false, // frozen — force never re-fetches legacy
        refetchForest: false,
        frozen: true,
      );
      if (legacyBlob != null) blobs.add(legacyBlob);
    }
    return blobs;
  }

  Future<Uint8List?> _manifestHalf({
    required String bucket,
    required String key,
    required Uint8List encryptionKey,
    required bool force,
    required bool refetchForest,
    required bool frozen,
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
          .timeout(const Duration(seconds: 30));
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
  static bool _isConfirmedAbsence(Object e) {
    final s = '$e';
    return s.contains('NoSuchKey') || s.contains('NoSuchBucket');
  }

  void _refreshManifestBehind(
      String bucket, String key, Uint8List encryptionKey) {
    final k = '$bucket|$key';
    if (_manifestRefreshes.containsKey(k)) return;
    final future = () async {
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
