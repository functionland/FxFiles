import 'package:web/web.dart' as web;

import 'package:fula_files/web/services/web_file_view_mode.dart';

/// Persistence for the file screens' view-mode toggle.
///
/// Deliberately `localStorage`, NOT the Hive/IndexedDB cache the rest of
/// the web shell uses: this is a ~5-byte UI preference read during
/// `initState`, and a SYNCHRONOUS read means the screen paints in its
/// remembered mode on the very first frame — no async gap, no flash of
/// the wrong layout, and no queueing behind IndexedDB work at exactly
/// the moment a screen is opening (the same contention that made the
/// websites screen hang). It also holds no user content, so it needs
/// none of the cache's AES-GCM machinery.
///
/// Every call is fail-soft: Safari private mode and "block all cookies"
/// throw on localStorage access, and a broken preference must never
/// break a file screen — it just falls back to list view.
class WebViewModeStore {
  WebViewModeStore._();
  static final WebViewModeStore instance = WebViewModeStore._();

  WebFileViewMode read(String screenKey) {
    try {
      return parseWebFileViewMode(
          web.window.localStorage.getItem(webFileViewModeKey(screenKey)));
    } catch (_) {
      return WebFileViewMode.list;
    }
  }

  void write(String screenKey, WebFileViewMode mode) {
    try {
      web.window.localStorage
          .setItem(webFileViewModeKey(screenKey), webFileViewModeName(mode));
    } catch (_) {
      // Storage denied/full — the choice still applies for this visit.
    }
  }
}
