import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Refcounted `beforeunload` guard.
///
/// While any caller holds a ref — e.g. an in-flight upload that cannot
/// survive a full page unload (the picked bytes live only in this page's
/// memory; there is no resumable handle on web) — the browser shows its
/// native "Leave site? / Reload site?" confirmation when the user closes
/// the tab, refreshes, or follows an external link (the Settings →
/// cloud.fx.land link). No-op once every ref is released.
///
/// This does NOT make the upload survive the unload — nothing can, short
/// of Background Fetch + a service worker (Chrome/Android only, and we
/// deliberately ship `--pwa-strategy=none`). It only stops the upload
/// from being thrown away silently.
class WebUnloadGuard {
  WebUnloadGuard._();
  static final WebUnloadGuard instance = WebUnloadGuard._();

  int _refs = 0;
  JSFunction? _handler;

  bool get armed => _refs > 0;

  void addRef() {
    _refs++;
    if (_refs == 1) _install();
  }

  void removeRef() {
    if (_refs == 0) return;
    _refs--;
    if (_refs == 0) _remove();
  }

  void _install() {
    if (_handler != null) return;
    // Modern browsers ignore any custom string and show their own generic
    // prompt; the spec only requires preventDefault() and/or a non-empty
    // returnValue to trigger it.
    final h = ((web.BeforeUnloadEvent e) {
      e.preventDefault();
      e.returnValue = 'Uploads are still in progress.';
    }).toJS;
    _handler = h;
    try {
      web.window.addEventListener('beforeunload', h);
    } catch (e) {
      debugPrint('WebUnloadGuard: addEventListener failed: $e');
      _handler = null;
    }
  }

  void _remove() {
    final h = _handler;
    if (h == null) return;
    _handler = null;
    try {
      web.window.removeEventListener('beforeunload', h);
    } catch (e) {
      debugPrint('WebUnloadGuard: removeEventListener failed: $e');
    }
  }
}
