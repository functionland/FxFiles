import 'package:path/path.dart' as p;

/// Classify a file type based on its filename extension.
/// Returns one of: 'image', 'video', 'audio', 'document'.
String classifyFileType(String fileName) {
  final ext = p.extension(fileName).toLowerCase();

  if (['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif', '.svg']
      .contains(ext)) {
    return 'image';
  }
  if (['.mp4', '.mov', '.avi', '.mkv', '.webm', '.m4v', '.flv'].contains(ext)) {
    return 'video';
  }
  if (['.mp3', '.wav', '.flac', '.aac', '.m4a', '.ogg', '.wma', '.opus'].contains(ext)) {
    return 'audio';
  }
  return 'document';
}

/// Get a human-readable label for a file type based on filename extension.
String getFileTypeLabel(String fileName) {
  switch (classifyFileType(fileName)) {
    case 'image':
      return 'Image';
    case 'video':
      return 'Video';
    case 'audio':
      return 'Audio';
    default:
      return 'Document';
  }
}

/// Archive extensions (mirror the web bucket screen's archive picker filter,
/// plus `.tgz`). Note `foo.tar.gz` → `p.extension` is `.gz` → archives.
const Set<String> _archiveExts = {
  '.zip', '.rar', '.7z', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.iso',
};

/// Common document extensions. Anything that isn't image/video/audio/archive
/// and isn't here falls through to the `downloads` catch-all, so a stray
/// `.exe`/`.apk`/extensionless file doesn't clutter Documents.
const Set<String> _documentExts = {
  '.pdf', '.doc', '.docx', '.txt', '.md', '.rtf', '.odt', '.ods', '.odp',
  '.xls', '.xlsx', '.csv', '.tsv', '.ppt', '.pptx',
  '.pages', '.numbers', '.key', '.epub', '.json', '.xml', '.html', '.htm',
};

/// Map a filename to one of the web home's category bases —
/// `images` / `videos` / `audio` / `documents` / `archives` — with
/// `downloads` as the catch-all for unknown or extensionless files. Used by
/// the home's cross-category quick-upload to pick a destination from the file
/// type alone (the web only ever has the filename). Extension-based.
String uploadCategoryBase(String fileName) {
  final ext = p.extension(fileName).toLowerCase();
  if (_archiveExts.contains(ext)) return 'archives';
  switch (classifyFileType(fileName)) {
    case 'image':
      return 'images';
    case 'video':
      return 'videos';
    case 'audio':
      return 'audio';
  }
  // classifyFileType returned its 'document' catch-all: split real documents
  // from everything else (which goes to Downloads).
  if (_documentExts.contains(ext)) return 'documents';
  return 'downloads';
}

/// Human-readable label for an upload-target category base, for the upload
/// progress/complete messages. e.g. `images` → `Images`, `audio` → `Audio`.
String categoryDisplayName(String base) {
  if (base.isEmpty) return base;
  return base[0].toUpperCase() + base.substring(1);
}
