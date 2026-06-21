import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/web/services/web_cache_sync.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_listing_swr.dart';
import 'package:fula_files/web/services/web_streaming_file.dart';
import 'package:fula_files/web/services/web_unload_guard.dart';

/// Files at or below this size take the single-shot [FulaApiService.uploadObject]
/// path (read once, one PUT). Larger files stream chunk-by-chunk so they never
/// have to fit in the tab's heap.
const int _kSmallUploadBytes = 768 * 1024;

/// How much plaintext to read per slice during pass 1 (the plan/commit pass).
/// Only one slice is in memory at a time; the value just trades syscalls for a
/// slightly bigger transient buffer.
const int _kPlanReadBytes = 4 * 1024 * 1024;

enum WebUploadStatus { queued, uploading, done, failed, skipped, cancelled }

/// Raised internally to unwind a streaming upload when the user cancels or the
/// session is reset mid-flight — distinguishes a clean abandon from a failure.
class _AbandonedUpload implements Exception {
  const _AbandonedUpload();
}

/// One queued file. Holds a lazily-readable [WebPickedFile] (a browser Blob
/// reference) — NOT the file bytes — so even a multi-GB file costs ~nothing in
/// the tray; slices are read on demand during the upload.
class WebUploadJob {
  WebUploadJob({
    required this.id,
    required this.base,
    required this.bucket,
    required this.key,
    required this.name,
    required this.size,
    required WebPickedFile picked,
  }) : _picked = picked;

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

  /// Byte length (from the Blob; available without reading the file).
  final int size;

  /// The lazily-readable file handle; dropped once the job leaves the active
  /// state. It's only a reference, so this is about tidiness, not memory.
  WebPickedFile? _picked;

  WebUploadStatus status = WebUploadStatus.queued;

  /// 0..1 while uploading; null means indeterminate (small upload, or pass 1
  /// of a streaming upload where total progress isn't known yet).
  double? progress;

  /// User-facing reason when [status] is failed or skipped.
  String? error;

  bool get isActive =>
      status == WebUploadStatus.queued || status == WebUploadStatus.uploading;
}

/// App-level, navigation-independent upload queue for the web shell.
///
/// Hoisted out of `WebBucketScreen` so an upload survives in-app navigation and
/// stays visible through the shell-level `WebUploadTray`.
///
/// Design notes:
///  * **Streaming, memory-bounded**: large files are read from the picked Blob
///    in slices and pushed through the fula_client streaming handle
///    (`streamingUploadBegin` → plan → `finalizePlan` → `uploadChunk` ×N →
///    `finish`). Peak memory is ~one chunk, independent of file size — so there
///    is no longer a per-file size cap, and a large file on a low-RAM phone no
///    longer OOMs the tab the way the old `withData: true` read did.
///  * **Sequential** (concurrency 1 across files, and chunks within a file go
///    one at a time): bounds wasm linear-memory growth on older/low-RAM phones.
///  * **Foreground span / unload guard**: held for the whole drain so prefetch
///    yields and a real tab close prompts instead of silently dropping a file.
///  * Cannot truly continue while a MOBILE tab is suspended (iOS Safari freezes
///    backgrounded-tab JS); the upload pauses and resumes when foregrounded.
///    Resume across a full reload lands in a later release.
class WebUploadManager extends ChangeNotifier {
  WebUploadManager._();
  static final WebUploadManager instance = WebUploadManager._();

  final List<WebUploadJob> _jobs = [];
  List<WebUploadJob> get jobs => List.unmodifiable(_jobs);

  int _seq = 0;
  bool _pumping = false;

  /// Bumped by [reset] (sign-out / user-switch). The pump captures it at start
  /// and bails its post-upload side effects if it changed mid-drain.
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

  /// Emits a category `base` once its uploads in a drain have completed and the
  /// same-tab listing cache has been refreshed.
  final StreamController<String> _completed =
      StreamController<String>.broadcast();
  Stream<String> get onBucketCompleted => _completed.stream;

  /// Queue lazily-readable picked [files] for [base]'s [bucket]. No size cap —
  /// large files stream without being loaded into memory.
  void enqueue({
    required String base,
    required String bucket,
    required List<WebPickedFile> files,
    String keyPrefix = '',
  }) {
    if (files.isEmpty) return;
    // Tidy: drop previously-finished SUCCESS rows so the tray reflects the new
    // batch. Failed/cancelled rows are kept until the user dismisses them.
    _jobs.removeWhere((j) => j.status == WebUploadStatus.done);

    // Normalize the folder prefix: no leading slash, exactly one trailing
    // slash. Empty → bucket root (key stays "/<name>", as before). Cloud Files
    // passes the current folder so files land under it.
    var p = keyPrefix.trim();
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    final dir = p.isEmpty ? '' : '$p/';

    for (final f in files) {
      _jobs.add(WebUploadJob(
        id: _seq++,
        base: base,
        bucket: bucket,
        key: '/$dir${f.name}',
        name: f.name,
        size: f.size,
        picked: f,
      ));
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

    WebForegroundActivity.instance.begin();
    WebUnloadGuard.instance.addRef();

    final completedBuckets = <String, String>{};
    // bucket -> keys this drain uploaded, so we can record their listing
    // objects as recent own-writes (kept visible through a Refresh during the
    // gateway's post-write forest propagation window).
    final completedKeys = <String, List<String>>{};
    final ensuredBuckets = <String>{};

    try {
      while (true) {
        final job = _nextQueued();
        if (job == null) break;

        job.status = WebUploadStatus.uploading;
        job.progress = null;
        notifyListeners();

        final picked = job._picked;
        if (picked == null) {
          job.status = WebUploadStatus.failed;
          job.error = 'No data to upload.';
          notifyListeners();
          continue;
        }

        try {
          // First upload into a fresh vault/category: the bucket may not exist
          // yet. Create-and-tolerate-already-exists, once per bucket per drain.
          if (ensuredBuckets.add(job.bucket)) {
            try {
              await FulaApiService.instance.createBucket(job.bucket);
            } catch (_) {}
          }

          if (job.size <= _kSmallUploadBytes) {
            // Small file: one read, one PUT (streaming overhead isn't worth it).
            final bytes = await picked.readSlice(0, job.size);
            if (_epoch != epoch || job.status == WebUploadStatus.cancelled) {
              throw const _AbandonedUpload();
            }
            await FulaApiService.instance
                .uploadObject(job.bucket, job.key, bytes);
          } else {
            await _streamUpload(job, picked, epoch);
          }

          // Sign-out / user-switch landed mid-upload: abandon the rest.
          if (_epoch != epoch) break;

          job.status = WebUploadStatus.done;
          job.progress = 1.0;
          job._picked = null;
          completedBuckets[job.base] = job.bucket;
          (completedKeys[job.bucket] ??= <String>[]).add(job.key);
          WebCacheSync.instance.sendInvalidateListing(job.bucket);
          notifyListeners();
        } catch (e) {
          // A user cancel or a session reset is a clean abandon, not a failure
          // (the partial chunks are unreferenced and get swept later).
          final abandoned = e is _AbandonedUpload ||
              job.status == WebUploadStatus.cancelled ||
              _epoch != epoch;
          if (abandoned) {
            if (job.status != WebUploadStatus.cancelled &&
                _epoch == epoch) {
              // Shouldn't happen, but never leave a row stuck "uploading".
              job.status = WebUploadStatus.cancelled;
            }
            job._picked = null;
            notifyListeners();
          } else {
            job.status = WebUploadStatus.failed;
            job.error = '$e';
            job._picked = null;
            notifyListeners();
          }
        }
      }
    } finally {
      if (_epoch == epoch) {
        for (final entry in completedBuckets.entries) {
          try {
            // Own-write reload (refetchForest:false keeps the session forest,
            // which already has the new files). Capture the listing so we can
            // record each uploaded file's real object as a recent own-write —
            // that's what keeps it visible through a manual Refresh during the
            // gateway's post-write propagation window.
            final listing = await WebListingSwr.instance
                .getListing(entry.value, force: true, refetchForest: false);
            final keys = completedKeys[entry.value];
            if (keys != null) {
              final byKey = {for (final o in listing.objects) o.key: o};
              for (final k in keys) {
                final obj = byKey[k];
                if (obj != null) {
                  WebListingSwr.instance.recordRecentUpload(entry.value, obj);
                }
              }
            }
          } catch (_) {}
          _completed.add(entry.key);
        }
      }

      WebUnloadGuard.instance.removeRef();
      WebForegroundActivity.instance.end();
      _pumping = false;
      notifyListeners();

      if (_nextQueued() != null) unawaited(_pump());
    }
  }

  /// Stream one large file through the fula_client streaming handle, reading it
  /// from the Blob in slices so the whole file never lands in memory.
  ///
  /// Pass 1 (plan) reads the file once to commit the per-chunk nonces +
  /// integrity root; pass 2 re-encrypts each chunk from its committed nonce and
  /// PUTs it (the SDK retries a transient chunk-PUT internally, so a single drop
  /// doesn't fail the whole upload). Throws [_AbandonedUpload] on cancel/reset.
  Future<void> _streamUpload(
      WebUploadJob job, WebPickedFile picked, int epoch) async {
    final api = FulaApiService.instance;
    void checkAbandon() {
      if (_epoch != epoch || job.status == WebUploadStatus.cancelled) {
        throw const _AbandonedUpload();
      }
    }

    final handle = await api.streamingUploadBegin(job.bucket, job.key);

    // Pass 1 — plan/commit. Read the file in slices (indeterminate progress).
    var offset = 0;
    while (offset < job.size) {
      checkAbandon();
      final end = (offset + _kPlanReadBytes) > job.size
          ? job.size
          : offset + _kPlanReadBytes;
      final slice = await picked.readSlice(offset, end);
      await api.streamingUploadPlanChunk(handle, slice);
      offset = end;
    }

    final info = await api.streamingUploadFinalizePlan(handle);

    // Pass 2 — upload each chunk from its committed nonce.
    final cs = info.chunkSize;
    for (var i = 0; i < info.numChunks; i++) {
      checkAbandon();
      final start = i * cs;
      final end = (start + cs) > job.size ? job.size : start + cs;
      final slice = await picked.readSlice(start, end);
      await api.streamingUploadChunk(handle, i, slice);
      job.progress = (i + 1) / info.numChunks;
      if (_epoch == epoch) notifyListeners();
    }

    checkAbandon();
    await api.streamingUploadFinish(handle);
  }

  /// Remove finished rows (done/failed/skipped/cancelled) from the tray.
  void clearFinished() {
    _jobs.removeWhere((j) => !j.isActive);
    notifyListeners();
  }

  /// Cancel a job. A queued job is dropped before it starts; an in-flight
  /// streaming upload stops feeding chunks at the next boundary (the partial,
  /// unreferenced chunks are swept later — there is no SDK-level abort for the
  /// streaming path yet). Marking it `cancelled` makes [_pump] treat the unwind
  /// as a clean cancel, not an error.
  void cancelJob(int id) {
    final idx = _jobs.indexWhere((j) => j.id == id);
    if (idx < 0) return;
    final job = _jobs[idx];
    if (!job.isActive) return;
    job.status = WebUploadStatus.cancelled;
    job.error = null;
    job._picked = null;
    notifyListeners();
  }

  /// Prioritize a queued job so it uploads next ("Upload next"). No-op for the
  /// active or finished rows.
  void moveJobToFront(int id) {
    final idx = _jobs.indexWhere((j) => j.id == id);
    if (idx < 0) return;
    final job = _jobs[idx];
    if (job.status != WebUploadStatus.queued) return;
    _jobs.removeAt(idx);
    var insertAt = 0;
    while (insertAt < _jobs.length &&
        _jobs[insertAt].status != WebUploadStatus.queued) {
      insertAt++;
    }
    _jobs.insert(insertAt, job);
    notifyListeners();
  }

  /// Sign-out / user-switch: abandon the queue so a new user never sees or
  /// continues the previous user's uploads. The in-flight streaming loop checks
  /// the epoch at each chunk boundary and unwinds cleanly.
  void reset() {
    _epoch++;
    _jobs.clear();
    WebListingSwr.instance.clearRecentUploads();
    notifyListeners();
  }
}
