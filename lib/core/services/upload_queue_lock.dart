import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Cross-isolate exclusion for the upload queue.
///
/// Two isolates can drain the same persistent SyncTask queue at the
/// same time on Android: the main UI isolate (MainActivity-hosted) and
/// the background isolate hosted by `SyncForegroundService`. Each has
/// its own `EncryptedClient` with its own DEK generator. If both pick
/// up the same task, the file ends up encrypted twice with two
/// different keys; the forest registers only one, the other becomes
/// orphaned cloud bytes — and the server typically rejects the
/// Frankenstein assembly mid-upload (surfaces as `os error 103
/// Software caused connection abort` at a random chunk).
///
/// **Previous implementation was broken.** It used `dart:io`
/// `RandomAccessFile.lock(FileLock.exclusive)`, which on Linux/Android
/// is a POSIX `fcntl` advisory record-lock. POSIX advisory locks are
/// **per-process**, not per-fd: multiple isolates inside the same OS
/// process all see the same lock as "already owned by this process"
/// and acquire successfully. Dart's own docs spell this out: "several
/// isolates in the same process can obtain an exclusive lock on the
/// same file."
/// (api.dart.dev/dart-io/RandomAccessFile/lock.html)
///
/// **Current implementation** delegates to a Kotlin process-singleton
/// `UploadOwnershipRegistry` over the
/// `land.fx.files/upload_ownership` MethodChannel. Kotlin holds the
/// authoritative ownership state and a hold count; each Dart-side
/// `tryAcquire` / `release` is a pass-through round-trip.
///
/// **Why stateless on the Dart side?** Two callers within the same
/// instance acquiring concurrently (e.g. `processUploadQueue` and
/// `processQueueWithTimeout` racing in `SyncService`) would otherwise
/// either (a) double-count without local tracking, or (b) coalesce
/// into one native acquire and have the first caller's release clear
/// ownership while the second is still inside the critical section.
/// Stateless pass-through avoids both: each call is an independent
/// native operation, the native ref count is the only source of
/// truth, and callers are required to balance acquire/release
/// themselves (the usual try/finally pattern).
///
/// **Ownership token = per-isolate UUID.** All `UploadQueueLock`
/// instances inside one isolate share the same token, so layered
/// acquires (outer + inner) are recognised as re-entrant by the
/// native registry (ref count bumps). Distinct isolates get distinct
/// tokens; native treats them as separate owners and serialises.
///
/// **Fail-closed on Android.** If the native channel can't be reached
/// for any reason on Android, [tryAcquire] returns `false` rather than
/// degrading to "no-lock mode". The previous fail-open behaviour
/// silently re-enabled the dual-isolate race in the exact scenarios
/// the lock exists to prevent.
class UploadQueueLock {
  /// Per-isolate token used as the ownership identity. Generated
  /// lazily on first use so it captures isolate-local memory: each
  /// isolate (main / BG service / WorkManager) gets a distinct value.
  /// All `UploadQueueLock` instances inside one isolate share it, so
  /// layered acquires are recognised as re-entrant by the native
  /// registry (ref-counted on the Kotlin side).
  static String? _isolateToken;

  static String _ensureIsolateToken() {
    final cached = _isolateToken;
    if (cached != null) return cached;
    final ts = DateTime.now().microsecondsSinceEpoch;
    final rand = math.Random.secure().nextInt(1 << 32);
    final fresh = '$ts-$rand';
    _isolateToken = fresh;
    return fresh;
  }

  static const String _channelName = 'land.fx.files/upload_ownership';
  static const MethodChannel _channel = MethodChannel(_channelName);

  /// Test seam — when non-null, overrides the runtime `Platform.isAndroid`
  /// check so unit tests can exercise both the pass-through (host) and
  /// channel-driven (Android) branches from a single `flutter test` run.
  /// `null` in production. Flutter's `debugDefaultTargetPlatformOverride`
  /// is **not** sufficient here: it changes the framework's `TargetPlatform`
  /// but does NOT affect `dart:io`'s `Platform.isAndroid`, which still
  /// reports the host OS.
  @visibleForTesting
  static bool? debugIsAndroidOverride;

  static bool get _isAndroid =>
      debugIsAndroidOverride ?? Platform.isAndroid;

  @visibleForTesting
  static Duration debugPollInterval = const Duration(milliseconds: 250);

  /// Register this isolate's token with the Kotlin side so the
  /// service can force-release on engine destroy. Returns `true` on
  /// success. Returns `false` on any failure — callers MUST check
  /// and refuse to start a BG upload if this returns false, because
  /// the engine-destroy safety net depends on this registration.
  ///
  /// Only the BG-isolate path needs this; main isolate releases via
  /// its own try/finally and we deliberately don't tie main's release
  /// to any Android lifecycle event (Activity destroy != isolate
  /// destroy on rotation).
  static Future<bool> registerAsBackgroundIsolate() async {
    if (!_isAndroid) return true;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'registerBackgroundToken',
        <String, dynamic>{'token': _ensureIsolateToken()},
      );
      return ok == true;
    } catch (e) {
      debugPrint(
        'UploadQueueLock.registerAsBackgroundIsolate: native channel '
        'unavailable ($e). Refusing to mark this isolate as BG owner.',
      );
      return false;
    }
  }

  final String _ownerTag; // diagnostics only

  UploadQueueLock({String? ownerTag}) : _ownerTag = ownerTag ?? 'unknown';

  /// `true` when this build's lock primitive can't reach the native
  /// registry on a platform that requires it. Set on non-Android
  /// platforms (intentional no-op). On Android, channel errors do
  /// NOT mark the lock as unavailable — they fail-closed and the
  /// caller sees `tryAcquire` return `false`.
  bool get isUnavailable => !_isAndroid;

  /// Try to acquire the lock without blocking. On Android, returns
  /// `false` if another isolate currently holds it OR if the native
  /// channel is unreachable. On non-Android, always returns `true`
  /// (no cross-isolate concern exists outside Android).
  ///
  /// **Caller contract:** Every successful `tryAcquire` MUST be
  /// matched by exactly one `release` in a `try/finally`. The lock
  /// is stateless on the Dart side; no idempotence guard.
  Future<bool> tryAcquire() async {
    if (!_isAndroid) return true;
    try {
      final acquired = await _channel.invokeMethod<bool>(
        'tryAcquire',
        <String, dynamic>{'token': _ensureIsolateToken()},
      );
      return acquired == true;
    } catch (e) {
      debugPrint(
        'UploadQueueLock.tryAcquire ($_ownerTag): native channel '
        'unreachable ($e). Refusing to acquire — caller should '
        'retry or skip this drain pass.',
      );
      return false;
    }
  }

  /// Acquire the lock, waiting at most [timeout] for another isolate
  /// to release it. Returns `true` on success, `false` on timeout.
  Future<bool> acquireWithTimeout(Duration timeout) async {
    if (!_isAndroid) return true;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await tryAcquire()) return true;
      await Future<void>.delayed(debugPollInterval);
    }
    return false;
  }

  /// Release the lock. Should be called exactly once for each
  /// successful `tryAcquire`. Idempotent on the native side — a
  /// release call against a token that no longer owns is a no-op.
  Future<void> release() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>(
        'release',
        <String, dynamic>{'token': _ensureIsolateToken()},
      );
    } catch (e) {
      debugPrint(
        'UploadQueueLock.release ($_ownerTag): native channel failed: $e. '
        'Lock may be stuck until the holding isolate or process exits.',
      );
    }
  }
}
