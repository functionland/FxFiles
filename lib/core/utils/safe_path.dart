import 'package:path/path.dart' as p;

/// Joins [untrustedRelative] onto [baseDir] and guarantees the result stays
/// inside [baseDir]. Throws [FormatException] if the relative component is
/// absolute, uses drive letters, or escapes the base directory via `..`.
///
/// Use at every filesystem sink that takes a remote- or archive-supplied path
/// component (zip entry names, sync manifest fileNames, backup manifest
/// relativePaths).
String safeJoin(String baseDir, String untrustedRelative) {
  if (untrustedRelative.isEmpty) {
    throw const FormatException('Empty path component');
  }
  if (p.isAbsolute(untrustedRelative)) {
    throw FormatException(
        'Absolute path rejected: $untrustedRelative');
  }
  // Normalize both sides using the current platform's separator so that
  // isWithin compares apples-to-apples.
  final normalizedBase = p.normalize(p.absolute(baseDir));
  final joined = p.normalize(p.join(normalizedBase, untrustedRelative));
  if (joined == normalizedBase) {
    throw FormatException(
        'Path resolves to base directory: $untrustedRelative');
  }
  if (!p.isWithin(normalizedBase, joined)) {
    throw FormatException(
        'Path escapes base directory: $untrustedRelative');
  }
  return joined;
}

/// Strips path separators and traversal tokens from [name] so it is safe to
/// use as a single filename component. Returns an empty string for inputs
/// that collapse to only separators/dots.
String sanitizeFileName(String name) {
  final stripped = name
      .replaceAll('\\', '_')
      .replaceAll('/', '_')
      .replaceAll('\u0000', '')
      .trim();
  if (stripped == '.' || stripped == '..' || stripped.isEmpty) return '';
  return stripped;
}

const Set<String> _reservedWindowsNames = {
  'CON', 'PRN', 'AUX', 'NUL',
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

/// Returns true if [name] matches a Windows device / reserved filename (case
/// insensitive, extension ignored). These names cannot be used as files or
/// directories on Windows even though Dart / POSIX would accept them.
bool isReservedWindowsName(String name) {
  if (name.isEmpty) return false;
  final base = name.contains('.') ? name.substring(0, name.indexOf('.')) : name;
  return _reservedWindowsNames.contains(base.toUpperCase());
}

/// Characters that are invalid in filenames on Windows (and look dangerous on
/// other platforms because they collide with shell syntax). Suitable for a
/// `FilteringTextInputFormatter.deny(RegExp(invalidFilenameCharsPattern))`.
final RegExp invalidFilenameCharsPattern = RegExp(r'[\\/:*?"<>|\x00-\x1F]');
