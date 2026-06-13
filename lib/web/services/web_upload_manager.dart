import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/web/services/web_cache_sync.dart';
import 'package:fula_files/web/services/web_device_class.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_listing_swr.dart';
import 'package:fula_files/web/services/web_unload_guard.dart';

/// Threshold below which we use the single-shot [FulaApiService.uploadObject]
/// instead of the chunked [FulaApiService.uploadLargeFile] — mirrors the
/// original inline upload path in WebBucketScreen.
const int _kSmallUploadBytes = 768 * 1024;

enum WebUploadStatus { queued, uploading, done, failed, skipped }

/// One queued file. Owns its bytes until the upload finishes; the bytes
/// are freed the instant the job leaves the active state so a low-RAM
/// phone doesn't hold a big [Uint8List] longer than necessary.
class WebUploadJob {
  WebUploadJob({
    required this.id,
    required this.base,
    required this.bucket,
    required this.key,
    required this.name,
    required this.size,
    required Uint8List bytes,
  }) : _bytes = bytes;

  final int id;

  /// Category base (`images`/`videos`/…) — drives the tray label and which
  /// bucket screen refreshes on completion.
  final String base;

  /// The `-v8` write bucket this file goes to.
  final String bucket;

  /// Object key (`/filename`).
  final String key;

  /// Display name.
  final String name;

  /// Byte length (kept after [_bytes] is freed, for the tray).
  final int size;

  Uint8List? _bytes;
  WebUploadStatus status = WebUploadStatus.queued;

  /// 0..1 while uploading; null means indeterminate (small upload or not
  /// yet started).
  double? progress;

  /// User-facing reason when [status] is failed or skipped.
  String? error;

  bool get isActive =>
      status == WebUploadStatus.queued || status == WebUploadStatus.uploading;
}

/// App-level, navigation-independent upload queue for the web shell.
///
/// The whole point: uploads used to live inside `WebBucketScreen`'s State,
/// so navigating away (or to an external page) tore down the progress UI
/// and skipped the post-upload refresh. Hoisting the work here — a
/// ChangeNotifier singleton created at app boot — means an upload survives
/// any in-app navigation (client-side routing never reloads the page) and
/// stays visible through the shell-level [WebUploadTray].
///
/// Design notes:
///  * **Sequential** (concurrency 1): bounds wasm linear-memory growth and
///    keeps the per-file Rust chunker the only thing in flight — important
///    for older/low-RAM phones (Gemini-flagged OOM-kill risk).
///  * **Frees bytes ASAP**: a finished/failed job drops its [Uint8List]
///    immediately.
///  * **Foreground span**: holds one [WebForegroundActivity] ref for the
///    whole drain so background prefetch yields (bandwidth + wasm locks).
///  * **Unload guard**: holds one [WebUnloadGuard] ref so a real tab close /
///    refresh / external-link navigation prompts instead of silently
///    dropping an in-flight upload (web can't resume an in-memory upload
///    across a reload).
///  * Cannot truly continue while a MOBILE tab is suspended — iOS Safari /
///    Android Chrome freeze backgrounded-tab JS; the upload pauses and
///    resumes when the tab is foregrounded again. There is no web API that
///    changes that for in-memory uploads on iOS.
class WebUploadManager extends ChangeNotifier {
  WebUploadManager._();
  static final WebUploadManager instance = WebUploadManager._();

  /// Hard per-file cap. Picked files are held fully in memory before the
  /// encrypted upload; on low-RAM/older devices a big buffer in a possibly
  /// backgrounded tab is a prime target for the OS to reclaim, so the cap
  /// is lower there.
  static const int _capDesktopBytes = 200 * 1024 * 1024;
  static const int _capLowEndBytes = 75 * 1024 * 1024;

  int get capBytes =>
      WebDeviceClass.lowEnd ? _capLowEndBytes : _capDesktopBytes;

  String get capLabel => '${(capBytes / (1024 * 1024)).round()} MB';

  final List<WebUploadJob> _jobs = [];
  List<WebUploadJob> get jobs => List.unmodifiable(_jobs);

  int _seq = 0;
  bool _pumping = false;

  /// Bumped by [reset] (sign-out / user-switch). The pump captures it at
  /// start and bails its post-upload side effects if it changed mid-drain,
  /// so an in-flight upload can never refresh the NEW user's cache or fire
  /// a completion for them.
  int _epoch = 0;

  bool get isActive => _jobs.any((j) => j.isActive);
  int get activeCount => _jobs.where((j) => j.isActive).length;
  int get totalActiveAndQueued => activeCount;

  WebUploadJob? get current {
    for (final j in _jobs) {
      if (j.status == WebUploadStatus.uploading) return j;
    }
    return null;
  }

  /// Emits a category `base` once its uploads in a drain have completed and
  /// the same-tab listing cache has been refreshed — a visible bucket
  /// screen listens and re-reads (cheap, from the now-fresh cache).
  final StreamController<String> _completed =
      StreamController<String>.broadcast();
  Stream<String> get onBucketCompleted => _completed.stream;

  /// Queue [files] (already read into memory) for [base]'s [bucket].
  /// Over-cap files are recorded as `skipped` with a reason so the user
  /// sees why in the tray rather than silently losing them.
  void enqueue({
    required String base,
    required String bucket,
    required List<({String name, Uint8List bytes})> files,
  }) {
    if (files.isEmpty) return;
    // Tidy: drop previously-finished SUCCESS rows so the tray reflects the
    // new batch. Failed/skipped rows are kept until the user dismisses them.
    _jobs.removeWhere((j) => j.status == WebUploadStatus.done);

    for (final f in files) {
      final job = WebUploadJob(
        id: _seq++,
        base: base,
        bucket: bucket,
        key: '/${f.name}',
        name: f.name,
        size: f.bytes.length,
        bytes: f.bytes,
      );
      if (f.bytes.length > capBytes) {
        job.status = WebUploadStatus.skipped;
        job.error =
            'Larger than the $capLabel web upload limit — use the desktop '
            'or mobile app for very large files.';
        job._bytes = null;
      }
      _jobs.add(job);
    }
    notifyListeners();
    unawaited(_pump());
  }

  WebUploadJob? _nextQueued() {
    for (final j in _jobs) {
      if (j.status == WebUploadStatus.queued) return j;
    }
    return null;
  }

  Future<void> _pump() async {
    if (_pumping) return;
    if (_nextQueued() == null) return;
    _pumping = true;
    final epoch = _epoch;

    // One span for the whole drain: prefetch yields, and a page-unload is
    // guarded, until every queued file is done. Both acquire calls are
    // non-throwing (counter increments; addRef's listener install is
    // internally try/caught), so placing them before the try can't strand
    // `_pumping` or unbalance the refs released in the finally.
    WebForegroundActivity.instance.begin();
    WebUnloadGuard.instance.addRef();

    // base -> bucket for the categories that gained a file this drain, so
    // we refresh each one's same-tab cache exactly once at the end.
    final completedBuckets = <String, String>{};
    final ensuredBuckets = <String>{};

    try {
      while (true) {
        final job = _nextQueued();
        if (job == null) break;

        job.status = WebUploadStatus.uploading;
        job.progress = null;
        notifyListeners();

        final bytes = job._bytes;
        if (bytes == null) {
          job.status = WebUploadStatus.failed;
          job.error = 'No data to upload.';
          notifyListeners();
          continue;
        }

        try {
          // First upload into a fresh vault/category: the bucket may not
          // exist yet. Same ensure-pattern as the native cloud services
          // (create, tolerate already-exists). Once per bucket per drain.
          if (ensuredBuckets.add(job.bucket)) {
            try {
              await FulaApiService.instance.createBucket(job.bucket);
            } catch (_) {}
          }

          if (bytes.length <= _kSmallUploadBytes) {
            await FulaApiService.instance
                .uploadObject(job.bucket, job.key, bytes);
          } else {
            await FulaApiService.instance.uploadLargeFile(
              job.bucket,
              job.key,
              bytes,
              onProgress: (p) {
                // A reset() during this upload orphans the job; ignore late
                // progress so we don't rebuild the tray for a dead session.
                if (_epoch != epoch) return;
                job.progress = p.percentage / 100;
                notifyListeners();
              },
            );
          }

          // Sign-out / user-switch landed while this file was uploading:
          // abandon the rest. The finally still runs (epoch-guarded) and
          // releases the foreground + unload refs.
          if (_epoch != epoch) break;

          job.status = WebUploadStatus.done;
          job.progress = 1.0;
          job._bytes = null; // free the buffer immediately (low-RAM)
          completedBuckets[job.base] = job.bucket;
          // Other tabs drop their cached listing for this bucket.
          WebCacheSync.instance.sendInvalidateListing(job.bucket);
          notifyListeners();
        } catch (e) {
          job.status = WebUploadStatus.failed;
          job.error = '$e';
          job._bytes = null;
          notifyListeners();
        }
      }
    } finally {
      // Refresh this tab's listing cache once per category that gained a
      // file — from the SESSION forest (own-write → keep it; it's ahead of
      // the server for a few seconds). Done even if no screen is mounted,
      // so returning to the category shows the new file without a manual
      // refresh. Then nudge any visible screen. Skipped entirely if a
      // sign-out/user-switch happened mid-drain (don't touch a new session).
      if (_epoch == epoch) {
        for (final entry in completedBuckets.entries) {
          try {
            await WebListingSwr.instance
                .getListing(entry.value, force: true, refetchForest: false);
          } catch (_) {}
          _completed.add(entry.key);
        }
      }

      WebUnloadGuard.instance.removeRef();
      WebForegroundActivity.instance.end();
      _pumping = false;
      notifyListeners();

      // A file enqueued during the drain's tail (after the last
      // _nextQueued() returned null) would otherwise be stranded. There is
      // no await between that check and clearing _pumping, so this is
      // belt-and-suspenders — but cheap and safe.
      if (_nextQueued() != null) unawaited(_pump());
    }
  }

  /// Remove finished rows (done/failed/skipped) from the tray.
  void clearFinished() {
    _jobs.removeWhere((j) => !j.isActive);
    notifyListeners();
  }

  /// Sign-out / user-switch: abandon the queue so a new user never sees or
  /// continues the previous user's uploads. An already-in-flight Rust call
  /// can't be cancelled (web has no resumable handle), but clearing the
  /// queue stops anything new from starting; the pump's `_nextQueued()`
  /// then returns null and it winds down cleanly.
  void reset() {
    _epoch++;
    _jobs.clear();
    notifyListeners();
  }
}
