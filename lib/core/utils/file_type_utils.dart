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
