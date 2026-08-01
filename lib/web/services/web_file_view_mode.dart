// View-mode policy for the web file screens (list / 2-col grid / 3-col
// grid), mirroring the native file browser's cycling view toggle
// (lib/features/browser/screens/file_browser_screen.dart ViewMode).
//
// Pure + VM-testable: the native enum lives in a screen that imports
// dart:io (Platform.isIOS), so it can't be reused from lib/web/ — this
// is the web's own 3-value equivalent, with the column math and the
// persistence KEY derivation kept out of the widgets so they can be
// unit-tested (repo convention: *_logic/policy files hold the
// decisions, screens hold the I/O).

/// How a web file screen renders its rows.
enum WebFileViewMode {
  list,

  /// Grid, 2 columns on a phone-width viewport.
  grid2,

  /// Grid, 3 columns on a phone-width viewport.
  grid3,
}

/// Cycle order for the single AppBar toggle button: list → 2-col →
/// 3-col → list (native cycles list → largeGrid → smallGrid → list).
WebFileViewMode nextWebFileViewMode(WebFileViewMode mode) {
  switch (mode) {
    case WebFileViewMode.list:
      return WebFileViewMode.grid2;
    case WebFileViewMode.grid2:
      return WebFileViewMode.grid3;
    case WebFileViewMode.grid3:
      return WebFileViewMode.list;
  }
}

/// Persisted string form (stable across releases — it is written to
/// browser storage). Unknown/absent values read back as [list].
String webFileViewModeName(WebFileViewMode mode) => mode.name;

WebFileViewMode parseWebFileViewMode(String? raw) {
  switch (raw) {
    case 'grid2':
      return WebFileViewMode.grid2;
    case 'grid3':
      return WebFileViewMode.grid3;
    default:
      return WebFileViewMode.list;
  }
}

/// Storage key per screen, mirroring native's per-screen keys
/// (`viewMode_category_<base>` / `viewMode_cloud`): the user's choice
/// for Images shouldn't change Documents.
String webFileViewModeKey(String screenKey) => 'fx.viewMode.$screenKey';

/// Columns for [mode] at a viewport of [width] logical pixels.
///
/// The mode's NAME is its phone-width column count (2 / 3) — that is
/// what the user picks. On wider viewports the count scales by whole
/// multiples so desktop tiles don't become enormous (native does the
/// same thing via width breakpoints), while grid3 always stays denser
/// than grid2:
///
///   <600px  → 2 / 3     (phones — exactly what the icon promises)
///   <1200px → 4 / 6     (tablets, split-screen desktop)
///   <1800px → 6 / 9
///   ≥1800px → 8 / 12
///
/// Returns 1 for [WebFileViewMode.list] so callers can share one
/// builder if they want.
int webGridColumnsFor(WebFileViewMode mode, double width) {
  if (mode == WebFileViewMode.list) return 1;
  final base = mode == WebFileViewMode.grid2 ? 2 : 3;
  final int scale;
  if (width < 600) {
    scale = 1;
  } else if (width < 1200) {
    scale = 2;
  } else if (width < 1800) {
    scale = 3;
  } else {
    scale = 4;
  }
  return base * scale;
}

/// Tile aspect ratio (width / height). The 2-col tile is wider, so it
/// can afford a slightly taller thumbnail area; the denser grid needs a
/// squarer tile or the footer text dominates.
double webGridAspectRatioFor(WebFileViewMode mode) =>
    mode == WebFileViewMode.grid2 ? 0.85 : 0.80;

/// How far offscreen the grid should keep building tiles, in logical
/// pixels. Deliberately MODEST and smaller on low-end devices: every
/// offscreen tile is a potential thumbnail fetch + decode, so a large
/// cacheExtent turns a fast scroll into a request storm on exactly the
/// phones that can least afford it (the grid already multiplies visible
/// thumbnails 4-9x vs the list).
double webGridCacheExtent({required bool lowEnd}) => lowEnd ? 200 : 600;
