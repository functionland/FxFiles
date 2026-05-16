import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fula_files/core/models/ai_task.dart';
import 'package:fula_files/features/ai_tasks/utils/target_uri_builder.dart';
import 'package:url_launcher/url_launcher.dart';

/// Probes which messaging apps the target device can open via URL scheme.
///
/// Uses `canLaunchUrl` per scheme. Android requires matching `<queries>`
/// entries in `AndroidManifest.xml`; iOS requires the schemes to appear in
/// `LSApplicationQueriesSchemes` in `Info.plist`. Both are set up as part
/// of this feature.
///
/// SMS and Email are system-handled and always considered available
/// (the OS will use the default Messages and Mail apps).
class InstalledAppsService {
  InstalledAppsService._();
  static final InstalledAppsService instance = InstalledAppsService._();

  Set<TargetApp>? _cached;
  DateTime? _cachedAt;
  static const _cacheTtl = Duration(minutes: 5);

  /// Returns the set of [TargetApp]s the user can actually launch from
  /// this device. Cached for [_cacheTtl] so navigating in/out of the
  /// picker doesn't hit `canLaunchUrl` repeatedly.
  Future<Set<TargetApp>> detect({bool refresh = false}) async {
    final cached = _cached;
    final cachedAt = _cachedAt;
    if (!refresh &&
        cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _cacheTtl) {
      return cached;
    }
    final result = <TargetApp>{};
    for (final target in TargetApp.values) {
      if (await _canLaunch(target)) result.add(target);
    }
    _cached = result;
    _cachedAt = DateTime.now();
    return result;
  }

  /// Force the next [detect] call to re-probe (e.g. when returning from a
  /// "Install WhatsApp" jump to the Play Store).
  void invalidate() {
    _cached = null;
    _cachedAt = null;
  }

  Future<bool> _canLaunch(TargetApp target) async {
    // SMS and email are universally available — every OS ships a default
    // handler. Skip the probe; `canLaunchUrl` on these can return false on
    // some Android variants even when a handler is installed.
    if (target == TargetApp.sms || target == TargetApp.email) {
      // On desktop Windows, SMS doesn't exist; email does via mailto.
      if (target == TargetApp.sms && !Platform.isAndroid && !Platform.isIOS) {
        return false;
      }
      return true;
    }
    try {
      final uri = Uri.parse(TargetUriBuilder.probeScheme(target));
      return await canLaunchUrl(uri);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('InstalledAppsService.canLaunch($target) error: $e');
      }
      return false;
    }
  }

  /// Store URL for the official install of a missing target. Returns null
  /// when no good install URL exists (e.g. SMS — it's part of the OS).
  String? installStoreUrl(TargetApp target) {
    switch (target) {
      case TargetApp.whatsapp:
        if (Platform.isIOS) {
          return 'https://apps.apple.com/app/whatsapp-messenger/id310633997';
        }
        return 'https://play.google.com/store/apps/details?id=com.whatsapp';
      case TargetApp.telegram:
        if (Platform.isIOS) {
          return 'https://apps.apple.com/app/telegram-messenger/id686449807';
        }
        return 'https://play.google.com/store/apps/details?id=org.telegram.messenger';
      case TargetApp.sms:
      case TargetApp.email:
        return null;
    }
  }
}
