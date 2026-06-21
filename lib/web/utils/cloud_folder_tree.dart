import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/utils/cloud_folder_marker.dart';

// Re-export the marker convention so Cloud Files consumers get it from one
// place (the constant lives in core because the storage layer writes it).
export 'package:fula_files/core/utils/cloud_folder_marker.dart'
    show kFolderMarkerName, folderMarkerBytes;

/// Pure helpers for the Cloud Files raw browser.
///
/// `FulaApiService.listObjects` returns the WHOLE bucket as a FLAT list of
/// files (full-path keys, `isDirectory` always false). We therefore derive the
/// folder structure on the client from those keys rather than relying on any
/// SDK directory listing. Keep this file dependency-light and pure so it can be
/// unit-tested exhaustively — it is the only deterministic gate for the folder
/// behaviour (the native browser's directory code is never actually exercised).

/// Normalize an object key for tree math: drop a single leading '/'. Stored
/// keys may or may not carry a leading slash depending on the writer, so the
/// tree treats '/a/b' and 'a/b' identically.
String normalizeCloudKey(String key) =>
    key.startsWith('/') ? key.substring(1) : key;

/// Last path segment of a (possibly slash-prefixed) key.
String cloudKeyName(String key) {
  final k = normalizeCloudKey(key);
  final i = k.lastIndexOf('/');
  return i < 0 ? k : k.substring(i + 1);
}

/// True when [o] is a folder-keep marker (by its leaf name).
bool isFolderMarker(FulaObject o) => cloudKeyName(o.key) == kFolderMarkerName;

/// Remove folder-marker objects from a listing. Shared by the Cloud Files file
/// view AND the category tabs (web_bucket_screen), so a folder created in a
/// category bucket never leaks its marker into Images/Videos/etc.
List<FulaObject> stripFolderMarkers(Iterable<FulaObject> objects) =>
    [for (final o in objects) if (!isFolderMarker(o)) o];

/// Normalize a folder prefix: no leading '/', exactly one trailing '/', and
/// internal runs of '/' collapsed. A free-text "foo//bar" would otherwise
/// produce an empty path segment that [deriveCloudFolderView] drops, silently
/// orphaning a moved/created file. '' stays '' (bucket root). 'a//b' → 'a/b/'.
String normalizeCloudPrefix(String prefix) {
  var p = prefix.trim().replaceAll(RegExp(r'/+'), '/');
  while (p.startsWith('/')) {
    p = p.substring(1);
  }
  if (p.isEmpty) return '';
  while (p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p.isEmpty ? '' : '$p/';
}

/// The object key for a file named [name] directly under folder [prefix]
/// ('' = bucket root). Always leading-slash (the existing upload convention);
/// [prefix] is normalized (slashes collapsed) so a caller can't build a key
/// with an empty segment the tree would hide. ('', 'a.txt') → '/a.txt';
/// ('photos/2024/', 'p.jpg') → '/photos/2024/p.jpg'.
String cloudChildKey(String prefix, String name) =>
    '/${normalizeCloudPrefix(prefix)}$name';

/// The immediate folders + files at [prefix] within a FLAT object list.
///
/// [prefix] is '' for the bucket root or a normalized folder path with a
/// trailing slash and no leading slash (e.g. 'photos/2024/'). Folders are the
/// distinct first path-segment of any key that lives deeper than [prefix];
/// files are the direct, non-marker children at [prefix]. A folder that holds
/// only a marker still appears (empty-folder support). Folders are returned
/// sorted; files keep the caller's order.
({List<String> folders, List<FulaObject> files}) deriveCloudFolderView(
  Iterable<FulaObject> objects,
  String prefix,
) {
  final p = normalizeCloudPrefix(prefix);
  final folders = <String>{};
  final files = <FulaObject>[];
  for (final o in objects) {
    final key = normalizeCloudKey(o.key);
    if (p.isNotEmpty && !key.startsWith(p)) continue;
    final rest = key.substring(p.length);
    if (rest.isEmpty) continue; // the prefix itself, never a real entry
    final slash = rest.indexOf('/');
    if (slash < 0) {
      if (rest == kFolderMarkerName) continue; // hide the marker from files
      files.add(o);
    } else {
      final folder = rest.substring(0, slash);
      if (folder.isNotEmpty) folders.add(folder);
    }
  }
  final sortedFolders = folders.toList()..sort();
  return (folders: sortedFolders, files: files);
}
