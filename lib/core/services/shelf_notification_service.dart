import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fula_files/core/models/shelf_item.dart';

/// Posts Shelf-specific notifications via platform-specific channels:
/// Android `fxfiles_dump_channel` (single-stage update-in-place UX)
/// or iOS via `UNUserNotificationCenter` through `AppDelegate`
/// (two-stage queued → uploaded UX — see Shelf plan Phase 8).
///
/// Notification authorization is requested by the main app, never by
/// the Share Extension (R5).
class ShelfNotificationService {
  ShelfNotificationService._();
  static final ShelfNotificationService instance = ShelfNotificationService._();

  static const MethodChannel _androidChannel =
      MethodChannel('land.fx.files/dump_notification');
  static const MethodChannel _iosChannel =
      MethodChannel('land.fx.files/dump_notification_ios');

  /// Notification body cap. One shared notification id on Android,
  /// per-call ids on iOS.
  static const int _bodyMaxChars = 80;

  /// Test seam — set to `true` to force the Android channel under any
  /// host platform. Production code leaves this `null`.
  @visibleForTesting
  static bool? debugForceAndroid;

  /// Test seam — set to `true` to force the iOS channel under any
  /// host platform. Production code leaves this `null`.
  @visibleForTesting
  static bool? debugForceIos;

  static bool get _isAndroidEnabled =>
      debugForceAndroid ?? Platform.isAndroid;
  static bool get _isIosEnabled => debugForceIos ?? Platform.isIOS;

  /// Android stage-1: "Processing N item(s)…" — overwritten by
  /// [showComplete] using the same notification ID. iOS: no-op,
  /// because the Share Extension itself posted the queued
  /// notification at share time.
  Future<void> showReceived({required int count}) async {
    if (!_isAndroidEnabled) return;
    final body = count == 1
        ? 'Processing 1 item…'
        : 'Processing $count items…';
    await _invokeAndroid('showShelfReceived', {
      'title': 'Shelf',
      'body': body,
      'count': count,
    });
  }

  /// Posts the "Saved to Shelf: …" finished-event notification on the
  /// platform's channel.
  ///
  /// On iOS the call also dismisses any stage-1 "queued" notification
  /// posted by the Share Extension (the only way to keep the
  /// notification tray tidy when the two notifications can't share
  /// an identifier — they're created from different processes).
  Future<void> showComplete({
    required List<ShelfItem> items,
    bool hasErrors = false,
  }) async {
    if (items.isEmpty) return;
    final title = hasErrors ? 'Some Shelf uploads failed' : 'Saved to Shelf';
    final body = _bodyForItems(items);
    final args = <String, dynamic>{
      'title': title,
      'body': body,
      'count': items.length,
      'deepLink': 'fxfiles://shelf',
      'hasErrors': hasErrors,
    };

    if (_isAndroidEnabled) {
      await _invokeAndroid('showShelfComplete', args);
    }
    if (_isIosEnabled) {
      await _invokeIos('showShelfComplete', args);
      // Dismiss the extension's queued notification(s) so the user
      // sees only the final state.
      await _invokeIos('dismissQueued', const <String, dynamic>{});
    }
  }

  /// Update-in-place when a share batch turned out to be entirely
  /// duplicates (R8 dedup already in your Shelf). Without this, the
  /// "Processing N item(s)…" notification posted by Kotlin
  /// `DumpShareActivity` would hang indefinitely because neither
  /// `showComplete` nor `showFailed` ever fires for the duplicates.
  /// Reuses `DUMP_RECEIVED_NOTIFICATION_ID` on Android so the OS
  /// swaps the body in the same slot rather than stacking a second
  /// notification. iOS posts a fresh one (extensions can't share an
  /// id with the main app process).
  Future<void> showDuplicate({required int count}) async {
    final body = count == 1
        ? 'This item is already in your Shelf'
        : '$count items already in your Shelf';
    final args = <String, dynamic>{
      'title': 'Already in Shelf',
      'body': body,
      'count': count,
      'deepLink': 'fxfiles://shelf',
    };
    if (_isAndroidEnabled) {
      await _invokeAndroid('showShelfDuplicate', args);
    }
    if (_isIosEnabled) {
      await _invokeIos('showShelfDuplicate', args);
      // Dismiss the queued notification posted by the Share Extension
      // since we no longer expect a follow-up "uploaded" notification.
      await _invokeIos('dismissQueued', const <String, dynamic>{});
    }
  }

  Future<void> showPendingAuth({required int count}) async {
    final body = count == 1
        ? 'Sign in to upload 1 saved item'
        : 'Sign in to upload $count saved items';
    final args = <String, dynamic>{
      'title': 'Shelf saved — sign in to upload',
      'body': body,
      'count': count,
      'deepLink': 'fxfiles://shelf',
    };
    if (_isAndroidEnabled) {
      await _invokeAndroid('showShelfPendingAuth', args);
    }
    if (_isIosEnabled) {
      await _invokeIos('showShelfPendingAuth', args);
    }
  }

  Future<void> showFailed({required ShelfItem item}) async {
    final body = _truncate(
      item.errorMessage ??
          'Could not upload ${item.autoTitle ?? item.originalName}',
    );
    final args = <String, dynamic>{
      'title': 'Shelf upload failed',
      'body': body,
      'deepLink': 'fxfiles://shelf',
    };
    if (_isAndroidEnabled) {
      await _invokeAndroid('showShelfFailed', args);
    }
    if (_isIosEnabled) {
      await _invokeIos('showShelfFailed', args);
    }
  }

  Future<void> hide() async {
    if (_isAndroidEnabled) {
      await _invokeAndroid('hideShelfNotification', const <String, dynamic>{});
    }
    if (_isIosEnabled) {
      await _invokeIos('hideShelfNotification', const <String, dynamic>{});
    }
  }

  /// iOS-only — request user permission for local notifications.
  /// Returns the granted bool (false if the user denied or the
  /// channel isn't wired up). Per R5 this lives on the main app, not
  /// in the Share Extension.
  Future<bool> requestAuthorization() async {
    if (!_isIosEnabled) return true;
    try {
      final granted = await _iosChannel
          .invokeMethod<bool>('requestAuthorization');
      return granted ?? false;
    } catch (e) {
      debugPrint('ShelfNotificationService.requestAuthorization failed: $e');
      return false;
    }
  }

  // ---- helpers ---------------------------------------------------------

  String _bodyForItems(List<ShelfItem> items) {
    if (items.length == 1) {
      final i = items.first;
      return _truncate(i.autoTitle ?? i.originalName);
    }
    return '${items.length} items saved to Shelf';
  }

  String _truncate(String s) {
    if (s.length <= _bodyMaxChars) return s;
    return '${s.substring(0, _bodyMaxChars - 1)}…';
  }

  Future<void> _invokeAndroid(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      await _androidChannel.invokeMethod(method, args);
    } catch (e) {
      debugPrint('ShelfNotificationService[android].$method failed: $e');
    }
  }

  Future<void> _invokeIos(String method, Map<String, dynamic> args) async {
    try {
      await _iosChannel.invokeMethod(method, args);
    } catch (e) {
      debugPrint('ShelfNotificationService[ios].$method failed: $e');
    }
  }

  /// Test-only — Android channel name (so MethodChannel mocks can
  /// hook the correct name without scattering magic strings).
  @visibleForTesting
  static String get androidChannelName => _androidChannel.name;

  /// Test-only — iOS channel name.
  @visibleForTesting
  static String get iosChannelName => _iosChannel.name;

  /// Backwards-compat alias for existing Session 2 tests.
  @visibleForTesting
  static String get channelName => _androidChannel.name;
}
