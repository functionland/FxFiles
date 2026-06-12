import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/web/services/web_device_class.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';
import 'package:fula_files/web/services/web_listing_swr.dart';
import 'package:fula_files/web/services/web_tag_service.dart';

/// Background cache warmer (docs/web-listing-prefetch-cache-plan.md §6
/// + §8.1). After sign-in + idle delay it walks a frecency-ordered
/// queue — one task at a time, each task = one bucket listing or one
/// manifest pair — warming both the SWR cache and the wasm forest
/// memos, so even the FIRST open of a screen this session is instant.
///
/// Hard rules:
///  - never runs while ANY foreground operation is in flight
///    (WebForegroundActivity counter == 0, with a 1 s settle), and
///    pauses while the tab is hidden;
///  - Data Saver or a low storage quota disables it entirely;
///  - one prefetcher across tabs (BroadcastChannel query/alive);
///  - low-end devices (§8.1) prefetch only the top 3 categories;
///  - failed tasks are poison-marked 5 min; 3 consecutive listing
///    failures stop the run (master likely down).
class WebPrefetchScheduler {
  WebPrefetchScheduler._();
  static final WebPrefetchScheduler instance = WebPrefetchScheduler._();

  static const _categories = [
    'images',
    'documents',
    'videos',
    'audio',
    'downloads',
    'archives',
  ];

  /// base → manifest object keys (relative to the per-user id).
  static const _manifestGroups = <String, List<String>>{
    'tag-metadata': ['.fula/tags/{uid}.json'],
    'dump-metadata': ['.fula/dumps/{uid}.json'],
    'website-metadata': [
      '.fula/websites/{uid}.json',
      '.fula/website_pointers/{uid}.json',
    ],
    'nft-metadata': ['.fula/nfts/{uid}.json'],
  };

  static const _maxQueueDesktop = 10;
  static const _maxQueueLowEnd = 3;
  static const _poisonWindow = Duration(minutes: 5);
  static const _maxConsecutiveFailures = 3;
  static const _interTaskGap = Duration(milliseconds: 200);
  static const _settleAfterBusy = Duration(seconds: 1);
  static const _minFreeStorageBytes = 25 * 1024 * 1024;

  bool _started = false;
  bool _cancelled = false;
  String? _disabledReason;
  DateTime? _startedAt;

  /// Random per-tab token for the cross-tab tiebreak: when two tabs'
  /// query windows overlap, the LOWER token responds 'alive' and the
  /// higher one stands down — exactly one prefetcher survives.
  final int _tabToken = Random().nextInt(1 << 30);
  bool _queryWindowOpen = false;

  int totalTasks = 0;
  int startedTasks = 0;
  int completedTasks = 0;
  int failedTasks = 0;
  int skippedTasks = 0;
  bool get finished =>
      _started &&
      totalTasks > 0 &&
      (completedTasks + failedTasks + skippedTasks) >= totalTasks;
  String? get disabledReason => _disabledReason;

  final Map<String, DateTime> _poison = {};
  int _consecutiveFailures = 0;

  web.BroadcastChannel? _channel;
  bool _remoteAlive = false;
  bool _visible = true;
  Completer<void>? _visibleWaiter;
  bool _lifecycleHooked = false;

  /// Sign-out hook (called by WebSession): a fresh sign-in must get a
  /// fresh prefetch run — and none of the previous account's poison
  /// marks, counters or disabled state (cross-user residue,
  /// Gemini-flagged). The frecency log itself is owner-scoped in the
  /// cache box, so it never crosses users.
  void reset() {
    _started = false;
    _cancelled = false;
    _disabledReason = null;
    _startedAt = null;
    totalTasks = 0;
    startedTasks = 0;
    completedTasks = 0;
    failedTasks = 0;
    skippedTasks = 0;
    _poison.clear();
    _consecutiveFailures = 0;
    _remoteAlive = false;
    debugPrint('[prefetch] reset');
  }

  /// Idempotent. [delay] defaults to the §8.1 policy (2 s desktop /
  /// 5 s low-end); the e2e harness passes Duration.zero.
  Future<void> start({Duration? delay}) async {
    if (_started) return;
    _started = true;
    _startedAt = DateTime.now();

    final wait = delay ??
        (WebDeviceClass.lowEnd
            ? const Duration(seconds: 5)
            : const Duration(seconds: 2));
    if (wait > Duration.zero) {
      await Future<void>.delayed(wait);
    }
    if (_cancelled) return;

    // ---- kill switches -------------------------------------------------
    if (WebDeviceClass.saveData) {
      _disable('data-saver');
      return;
    }
    final free = await WebDeviceClass.freeStorageBytes();
    if (free != null && free < _minFreeStorageBytes) {
      _disable('low-storage-quota ($free B free)');
      return;
    }
    _openChannel();
    if (await _anotherTabPrefetching()) {
      _disable('another-tab');
      return;
    }
    _hookLifecycle();

    // ---- queue ---------------------------------------------------------
    final queue = await _buildQueue();
    totalTasks = queue.length;
    debugPrint('[prefetch] queue=${queue.map((t) => t.key).join(',')}');

    for (final task in queue) {
      if (_cancelled) break;
      final until = _poison[task.key];
      if (until != null && DateTime.now().isBefore(until)) {
        skippedTasks++;
        debugPrint('[prefetch] skip poisoned ${task.key}');
        continue;
      }
      await _waitForIdle();
      if (_cancelled) break;

      // Quota can shrink mid-run (other tabs writing); re-check every
      // third task so an out-of-quota write stays unreachable.
      if (startedTasks > 0 && startedTasks % 3 == 0) {
        final freeNow = await WebDeviceClass.freeStorageBytes();
        if (freeNow != null && freeNow < _minFreeStorageBytes) {
          _disable('low-storage-quota mid-run ($freeNow B free)');
          return;
        }
      }

      startedTasks++;
      debugPrint('[prefetch] start ${task.key}');
      var ok = true;
      try {
        ok = await task.run();
      } catch (e) {
        ok = false;
        debugPrint('[prefetch] ${task.key} threw: $e');
      }
      if (ok) {
        completedTasks++;
        _consecutiveFailures = 0;
        debugPrint('[prefetch] done ${task.key}');
      } else {
        failedTasks++;
        _consecutiveFailures++;
        _poison[task.key] = DateTime.now().add(_poisonWindow);
        debugPrint('[prefetch] fail ${task.key} '
            '(consecutive=$_consecutiveFailures)');
        if (_consecutiveFailures >= _maxConsecutiveFailures) {
          _disable('consecutive-failures');
          return;
        }
      }
      await Future<void>.delayed(_interTaskGap);
    }
    debugPrint('[prefetch] finished '
        '($completedTasks ok / $failedTasks failed of $totalTasks)');
  }

  void _disable(String reason) {
    _disabledReason = reason;
    _cancelled = true;
    debugPrint('[prefetch] disabled: $reason');
  }

  // ------------------------------------------------------------ queue

  Future<List<_PrefetchTask>> _buildQueue() async {
    final usage = await WebListingCache.instance.readUsage();

    int byFrecency(String a, String b) {
      final ua = usage[a];
      final ub = usage[b];
      if (ua == null && ub == null) return 0;
      if (ua == null) return 1;
      if (ub == null) return -1;
      final recency = ub.lastAt.compareTo(ua.lastAt);
      if (recency != 0) return recency;
      return ub.n.compareTo(ua.n);
    }

    final catBuckets = [
      for (final base in _categories) BucketVersionResolver.writeBucket(base)
    ]..sort((a, b) => byFrecency('cat|$a', 'cat|$b'));

    final tasks = <_PrefetchTask>[
      for (final bucket in catBuckets)
        _PrefetchTask('cat|$bucket',
            () => WebListingSwr.instance.prefetchListing(bucket)),
    ];

    if (WebDeviceClass.lowEnd) {
      // §8.1: top categories only — no feature manifests on low-end.
      return tasks.take(_maxQueueLowEnd).toList();
    }

    // Manifests need the per-user id + KEK; missing either (shouldn't
    // happen signed-in) just skips the manifest tasks.
    try {
      final uid = await WebTagService.userId();
      final kekB64 = await SecureStorageService.instance
          .read(SecureStorageKeys.encryptionKey);
      if (kekB64 != null && kekB64.isNotEmpty) {
        final kek = Uint8List.fromList(base64Decode(kekB64));
        final bases = _manifestGroups.keys.toList()
          ..sort((a, b) => byFrecency('man|$a', 'man|$b'));
        for (final base in bases) {
          tasks.add(_PrefetchTask('man|$base', () async {
            for (final keyTpl in _manifestGroups[base]!) {
              await WebListingSwr.instance.prefetchManifest(
                  base, keyTpl.replaceFirst('{uid}', uid), kek);
            }
            return true;
          }));
        }
      }
    } catch (e) {
      debugPrint('[prefetch] manifest tasks skipped: $e');
    }

    return tasks.take(_maxQueueDesktop).toList();
  }

  // ------------------------------------------------- idle / lifecycle

  Future<void> _waitForIdle() async {
    while (!_cancelled) {
      if (_visible && WebForegroundActivity.instance.idle) return;
      if (!_visible) {
        // Event-driven wait — no timer wakeups in a hidden tab
        // (browsers throttle them anyway; Gemini-flagged battery
        // smell). The visibilitychange handler completes this.
        final waiter = _visibleWaiter ??= Completer<void>();
        await waiter.future;
        continue;
      }
      await WebForegroundActivity.instance.whenIdle();
      // Settle: a burst of taps shouldn't interleave with a task.
      await Future<void>.delayed(_settleAfterBusy);
      if (WebForegroundActivity.instance.idle) return;
    }
  }

  void _hookLifecycle() {
    if (_lifecycleHooked) return;
    _lifecycleHooked = true;
    web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        _visible = web.document.visibilityState == 'visible';
        debugPrint('[prefetch] visibility=$_visible');
        if (_visible) {
          _visibleWaiter?.complete();
          _visibleWaiter = null;
        }
      }).toJS,
    );
    // Frozen/navigating-away tabs abandon cleanly — the cache state on
    // disk is the only thing that persists (plan §8.1). (bfcache
    // restores stay cancelled — documented limitation.)
    web.window.addEventListener(
      'pagehide',
      ((web.Event _) => _cancelled = true).toJS,
    );
  }

  // ---------------------------------------------------- multi-tab dedup

  void _openChannel() {
    if (_channel != null) return;
    try {
      final ch = web.BroadcastChannel('fxfiles-cache');
      _channel = ch;
      ch.onmessage = ((web.MessageEvent e) {
        final data = e.data;
        if (data == null) return;
        final s = (data.dartify() ?? '').toString();
        if (s == 'prefetch-alive') {
          _remoteAlive = true;
        } else if (s.startsWith('prefetch-query:')) {
          final theirToken = int.tryParse(s.substring(15)) ?? 0;
          final at = _startedAt;
          // "Owning" = past our own query gate and genuinely
          // running/ran recently. A tab still inside its own query
          // window must NOT claim ownership — both tabs would politely
          // stand down and nobody prefetches; that case is decided by
          // the token tiebreak below instead.
          final owning = _started &&
              !_queryWindowOpen &&
              _disabledReason == null &&
              at != null &&
              DateTime.now().difference(at) < _poisonWindow;
          // Tiebreak for overlapping query windows: the lower token
          // answers, the higher one stands down — exactly one
          // prefetcher when several tabs open together.
          final winsTiebreak = _queryWindowOpen && _tabToken < theirToken;
          if (owning || winsTiebreak) {
            ch.postMessage('prefetch-alive'.toJS);
          }
        }
      }).toJS;
    } catch (e) {
      debugPrint('[prefetch] BroadcastChannel unavailable: $e');
    }
  }

  Future<bool> _anotherTabPrefetching() async {
    final ch = _channel;
    if (ch == null) return false;
    _remoteAlive = false;
    _queryWindowOpen = true;
    try {
      ch.postMessage('prefetch-query:$_tabToken'.toJS);
    } catch (_) {
      _queryWindowOpen = false;
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    _queryWindowOpen = false;
    return _remoteAlive;
  }
}

class _PrefetchTask {
  final String key;
  final Future<bool> Function() run;
  _PrefetchTask(this.key, this.run);
}
