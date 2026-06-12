import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Device-class detection for the prefetch policy
/// (docs/web-listing-prefetch-cache-plan.md §8.1).
///
/// Low-RAM / older phones get a minimal prefetch footprint — the
/// failure mode there is not slowness but Android Chrome silently
/// OOM-killing the tab. Classification is deliberately biased TOWARD
/// low-end: misclassifying a mid phone down costs a little warm-up;
/// misclassifying up can cost a tab kill.
class WebDeviceClass {
  WebDeviceClass._();

  static bool? _lowEnd;

  /// Harness override (unit tests + the e2e low-end gate runs) —
  /// takes precedence over detection. Never set in production code.
  static bool? debugOverrideLowEnd;

  static bool get lowEnd {
    final override = debugOverrideLowEnd;
    if (override != null) return override;
    return _lowEnd ??= _compute();
  }

  static bool _compute() {
    try {
      final mem = deviceMemoryGB;
      if (mem != null) return mem <= 2;
      // deviceMemory is Chromium-only. Fallback (Safari/Firefox):
      // phone-width viewport + few cores.
      final narrow = web.window.innerWidth < 700;
      final cores = web.window.navigator.hardwareConcurrency;
      return narrow && cores <= 4;
    } catch (_) {
      return false;
    }
  }

  /// `navigator.deviceMemory` in GB (0.25/0.5/1/2/4/8) — null where
  /// unsupported.
  static double? get deviceMemoryGB {
    try {
      final v = (web.window.navigator as JSObject)
          .getProperty('deviceMemory'.toJS);
      if (v.isUndefinedOrNull) return null;
      return (v as JSNumber).toDartDouble;
    } catch (_) {
      return null;
    }
  }

  /// `navigator.connection.saveData` — the user asked the browser to
  /// minimize data use; prefetch is disabled entirely then.
  static bool get saveData {
    try {
      final conn = (web.window.navigator as JSObject)
          .getProperty('connection'.toJS);
      if (conn.isUndefinedOrNull) return false;
      final v = (conn as JSObject).getProperty('saveData'.toJS);
      if (v.isUndefinedOrNull) return false;
      return (v as JSBoolean).toDart;
    } catch (_) {
      return false;
    }
  }

  /// Free origin-storage estimate in bytes (null when unavailable).
  static Future<int?> freeStorageBytes() async {
    try {
      final est = await web.window.navigator.storage.estimate().toDart;
      final usage = est.usage;
      final quota = est.quota;
      return (quota - usage).clamp(0, quota);
    } catch (_) {
      return null;
    }
  }
}
