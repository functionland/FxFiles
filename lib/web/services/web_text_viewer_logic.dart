import 'dart:convert';
import 'dart:typed_data';

/// Pure, VM-testable helpers behind the web inline text/code viewer (#19),
/// mirroring the native `lib/features/viewer/screens/text_viewer_screen.dart`
/// + `lib/core/models/local_file.dart` (`isTextViewable`). No `package:web`
/// / `dart:ui` imports so this — and its unit tests — run under the Dart VM;
/// the browser-only widget lives in `lib/web/widgets/web_text_viewer.dart`.

/// Hard cap on inline-rendered text. Above this a file downloads instead of
/// opening in the viewer: the whole file is in memory on web (no streaming),
/// and `split('\n')` + line widgets on a huge string is a JS-thread hazard.
const int kMaxInlineTextBytes = 2 * 1024 * 1024; // 2 MB

/// JSON is only pretty-printed below this: `jsonDecode` + re-encode builds a
/// whole object graph and a second (larger) string synchronously, which can
/// stall the single JS thread on web (advisor: Codex). Tighter than the
/// render cap on purpose.
const int kJsonPrettyMaxBytes = 512 * 1024; // 512 KB

// Prefixed to avoid colliding with Flutter's own `kDefaultFontSize`.
const double kTextViewerMinFontSize = 10;
const double kTextViewerMaxFontSize = 24;
const double kTextViewerDefaultFontSize = 14;
const double kTextViewerFontStep = 2;

/// Extensions that open inline (mirror of native `LocalFile.isTextViewable`).
const Set<String> kTextViewableExts = {
  'txt', 'md', 'rtf', 'csv', 'log', 'ini', 'conf', 'cfg',
  'json', 'xml', 'yaml', 'yml', 'sql',
  'dart', 'js', 'ts', 'jsx', 'tsx', 'vue', 'py', 'java', 'kt',
  'swift', 'c', 'cpp', 'h', 'cs', 'go', 'rs', 'rb', 'php',
  'html', 'css', 'sh',
  'gradle', 'properties', 'env', 'gitignore', 'dockerignore',
  'makefile', 'cmake',
};

/// Extensions that get the dark editor theme (mirror of the native viewer's
/// in-build `isCode` list — note it includes a couple not in the viewable
/// set, e.g. `bash`, kept faithful).
const Set<String> kCodeExts = {
  'dart', 'js', 'ts', 'py', 'java', 'kt', 'swift', 'go', 'rs',
  'c', 'cpp', 'h', 'css', 'html', 'xml', 'json', 'yaml', 'yml', 'sh', 'bash',
};

/// Lower-cased extension of a file name. Mirrors native exactly
/// (`basename.split('.').last.toLowerCase()`), so extensionless special
/// names map to themselves: `Makefile` → `makefile`, `.gitignore` →
/// `gitignore`. Strips any path prefix first so `a/b/file.TS` → `ts`.
String fileExtension(String name) {
  var base = name;
  final slash = base.lastIndexOf('/');
  if (slash >= 0) base = base.substring(slash + 1);
  final back = base.lastIndexOf('\\');
  if (back >= 0) base = base.substring(back + 1);
  return base.split('.').last.toLowerCase();
}

bool isTextViewableExt(String ext) => kTextViewableExts.contains(ext);

bool isTextViewableName(String name) =>
    isTextViewableExt(fileExtension(name));

bool isCodeName(String name) => kCodeExts.contains(fileExtension(name));

/// Decode bytes as UTF-8, replacing malformed sequences (never throws) so a
/// stray non-UTF-8 byte shows a replacement char instead of failing the
/// whole preview. Mirrors the existing web dialog's `allowMalformed: true`.
String decodeTextLenient(Uint8List bytes) =>
    utf8.decode(bytes, allowMalformed: true);

/// Split into lines handling `\r\n`, `\r`, and `\n` (so Windows CRLF files
/// don't show a trailing `\r`), and yielding no spurious trailing blank line
/// — an empty string gives zero lines.
List<String> splitLines(String content) =>
    const LineSplitter().convert(content);

/// Widest line in display columns, counting a tab as [tabWidth] columns.
/// Used to size the horizontal scroll extent in no-wrap mode; tab-aware so a
/// tab-indented file isn't under-measured and clipped (advisor: Codex).
int maxLineDisplayWidth(List<String> lines, {int tabWidth = 4}) {
  var maxW = 0;
  for (final l in lines) {
    var w = 0;
    for (var i = 0; i < l.length; i++) {
      w += l.codeUnitAt(i) == 0x09 ? tabWidth : 1; // 0x09 == '\t'
    }
    if (w > maxW) maxW = w;
  }
  return maxW;
}

/// Pretty-print JSON (2-space indent) when [ext] is `json`, the content
/// parses, and it's small enough ([byteSize] <= [maxBytes]); otherwise
/// returns it unchanged.
String prettyPrintJsonIfApplicable(String content, String ext,
    {int? byteSize, int maxBytes = kJsonPrettyMaxBytes}) {
  if (ext != 'json') return content;
  if (byteSize != null && byteSize > maxBytes) return content; // too big
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(content));
  } catch (_) {
    return content; // not valid JSON → show as-is
  }
}

/// Indices of [lines] containing [query] (case-insensitive). Empty query →
/// no matches. Used to drive the search highlight + next/prev navigation.
List<int> findMatchingLineIndices(List<String> lines, String query) {
  if (query.isEmpty) return const [];
  final q = query.toLowerCase();
  final out = <int>[];
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].toLowerCase().contains(q)) out.add(i);
  }
  return out;
}
