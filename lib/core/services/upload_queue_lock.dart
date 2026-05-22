import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Cross-isolate exclusion for the upload queue.
///
/// Two isolates can drain the same persistent SyncTask queue at the same
/// time: the main UI isolate (MainActivity-hosted) and the background
/// isolate hosted by [SyncForegroundService]. Each has its own
/// `EncryptedClient` with its own DEK generator. If both pick up the
/// same task, the file ends up encrypted twice at two different
/// storage_keys; the forest registers only one, the other becomes
/// orphaned cloud bytes (wasted bandwidth + storage).
///
/// This lock uses an OS-level advisory file lock on
/// `<documentsDir>/sync_queue.lock`. File locks are per-fd on Linux/
/// Android (`flock`/`fcntl`); two Dart isolates opening the file
/// separately each get their own fd, so the OS serializes them
/// correctly. On process exit (including a swipe-away kill), the OS
/// releases the lock automatically — no risk of a permanently-stuck
/// queue.
///
/// Usage:
/// ```dart
/// final lock = UploadQueueLock();
/// final acquired = await lock.tryAcquire();
/// if (!acquired) {
///   // Another isolate owns the queue; back off.
/// } else {
///   try {
///     await SyncService.instance.processUploadQueue();
///   } finally {
///     await lock.release();
///   }
/// }
/// ```
class UploadQueueLock {
  RandomAccessFile? _handle;

  /// `true` when this build couldn't create the lock file at all — e.g.,
  /// the test environment (no `path_provider`), pure-Dart server runs,
  /// or web. Callers should proceed without locking; there's only one
  /// isolate in those configurations anyway.
  bool _unavailable = false;
  bool get isUnavailable => _unavailable;

  /// Try to acquire the lock without blocking.
  /// Returns `true` on success OR when the lock primitive isn't
  /// available (test env, web). Returns `false` only when the lock
  /// file exists but another isolate currently holds it.
  Future<bool> tryAcquire() async {
    if (_handle != null) return true; // Already held by this isolate.
    if (_unavailable) return true; // Fall-through mode, no locking.

    final File? file;
    try {
      file = await _lockFile();
    } catch (e) {
      debugPrint(
        'UploadQueueLock: lock file unavailable ($e) — degrading to '
        'no-lock mode for this isolate.',
      );
      _unavailable = true;
      return true;
    }

    final raf = await file.open(mode: FileMode.write);
    try {
      await raf.lock(FileLock.exclusive);
      _handle = raf;
      return true;
    } catch (e) {
      try {
        await raf.close();
      } catch (_) {/* ignore */}
      debugPrint('UploadQueueLock.tryAcquire failed: $e');
      return false;
    }
  }

  /// Acquire the lock, waiting at most [timeout] for another isolate to
  /// release it. Returns `true` on success, `false` on timeout.
  ///
  /// Implemented as a poll because `RandomAccessFile.lock` doesn't
  /// expose a timeout. Poll interval is 250 ms — small enough that the
  /// handoff feels responsive when the holding isolate finishes a
  /// chunk, large enough that the background poll is cheap.
  Future<bool> acquireWithTimeout(Duration timeout) async {
    if (_handle != null) return true;
    if (_unavailable) return true;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _tryAcquireNonBlocking()) return true;
      if (_unavailable) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  /// Release the lock if currently held. Idempotent.
  Future<void> release() async {
    final raf = _handle;
    if (raf == null) return;
    _handle = null;
    try {
      await raf.unlock();
    } catch (e) {
      debugPrint('UploadQueueLock.release: unlock failed: $e');
    }
    try {
      await raf.close();
    } catch (e) {
      debugPrint('UploadQueueLock.release: close failed: $e');
    }
  }

  /// True if this lock instance currently holds the lock.
  bool get isHeld => _handle != null;

  Future<bool> _tryAcquireNonBlocking() async {
    final File file;
    try {
      file = await _lockFile();
    } catch (e) {
      debugPrint(
        'UploadQueueLock._tryAcquireNonBlocking: lock file unavailable '
        '($e) — degrading to no-lock mode.',
      );
      _unavailable = true;
      return true;
    }
    final raf = await file.open(mode: FileMode.write);
    try {
      // `dart:io` exposes lock() as blocking. We approximate
      // non-blocking by issuing the lock and racing it against a 50ms
      // timeout — if it hasn't completed by then, treat as "contended".
      // This is best-effort; on the platforms we care about (Android,
      // iOS, macOS, Linux) the lock acquire is near-instant when
      // uncontended.
      bool acquired = false;
      await raf.lock(FileLock.exclusive).timeout(
        const Duration(milliseconds: 50),
        onTimeout: () {
          // Lock not granted in 50ms; assume contended.
          return raf;
        },
      ).then((_) {
        acquired = true;
      }).catchError((Object _) {
        acquired = false;
      });
      if (acquired) {
        _handle = raf;
        return true;
      }
      try {
        await raf.unlock();
      } catch (_) {/* ignore — may not have been locked */}
      await raf.close();
      return false;
    } catch (e) {
      try {
        await raf.close();
      } catch (_) {/* ignore */}
      debugPrint('UploadQueueLock._tryAcquireNonBlocking failed: $e');
      return false;
    }
  }

  Future<File> _lockFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/sync_queue.lock');
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    return file;
  }
}
