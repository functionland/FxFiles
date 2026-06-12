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

  /// Notifies listeners when the browser regains connectivity —
  /// screens respond with a silent forced revalidate (Copilot's
  /// connection-regain pick: cross-device changes are most likely
  /// exactly then).
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
  }

  // ------------------------------------------------------- listings

  /// SWR read of one bucket's listing.
  ///
  /// force=true is the mutation/refresh semantic: bypass the cache READ
  /// entirely and await the live listing (exactly today's behavior),
  /// then update the cache. Cache-hit paths return immediately and
  /// carry an optional [SwrListing.revalidation] future per the tiers.
  Future<SwrListing> getListing(String bucket, {bool force = false}) async {
    // Frecency signal for the prefetch queue — user-driven reads only
    // (the scheduler's own warm-ups must not self-reinforce).
    unawaited(WebListingCache.instance.recordUsage('cat|$bucket'));
    return _getListing(bucket, force: force);
  }

  Future<SwrListing> _getListing(String bucket,
      {required bool force}) async {
    if (!force) {
      final cached = await WebListingCache.instance.readListing(bucket);
      if (cached != null) {
        final age = DateTime.now().difference(cached.fetchedAt);
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
  /// completion always counts as done.
  Future<void> prefetchManifest(
      String base, String key, Uint8List encryptionKey) {
    return downloadMetadataMergedSwr(base, key, encryptionKey,
        force: true, recordUsage: false);
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
  Future<List<Uint8List>> downloadMetadataMergedSwr(
    String base,
    String key,
    Uint8List encryptionKey, {
    bool force = false,
    bool recordUsage = true,
  }) async {
    if (recordUsage) {
      // recordUsage doubles as "user-driven": frecency signal AND a
      // foreground-activity window so the prefetcher yields. The
      // scheduler passes recordUsage=false and stays out of both.
      unawaited(WebListingCache.instance.recordUsage('man|$base'));
      return WebForegroundActivity.instance.run(
          () => _downloadMetadataMergedSwr(base, key, encryptionKey,
              force: force));
    }
    return _downloadMetadataMergedSwr(base, key, encryptionKey,
        force: force);
  }

  Future<List<Uint8List>> _downloadMetadataMergedSwr(
    String base,
    String key,
    Uint8List encryptionKey, {
    required bool force,
  }) async {
    final v8 = BucketVersionResolver.writeBucket(base);
    final blobs = <Uint8List>[];

    // ----- v8 (or sole unmanaged bucket) half -----
    final v8Blob = await _manifestHalf(
      bucket: v8,
      key: key,
      encryptionKey: encryptionKey,
      force: force,
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
    required bool frozen,
  }) async {
    final cached = await WebListingCache.instance.readManifest(bucket, key);

    if (cached != null && !force) {
      if (!frozen) {
        final age = DateTime.now().difference(cached.fetchedAt);
        if (swrTierForAge(age) != SwrTier.fresh) {
          _refreshManifestBehind(bucket, key, encryptionKey);
        }
      }
      return cached.blob;
    }

    // Miss, or force on the mutable half: live fetch.
    final started = DateTime.now();
    try {
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
