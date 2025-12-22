import 'dart:io';

class LocalFile {
  final String path;
  final String name;
  final int size;
  final DateTime modifiedAt;
  final bool isDirectory;
  final String? mimeType;
  final String? iosAssetId; // iOS PhotoKit asset ID for media files

  LocalFile({
    required this.path,
    required this.name,
    required this.size,
    required this.modifiedAt,
    required this.isDirectory,
    this.mimeType,
    this.iosAssetId,
  });

  factory LocalFile.fromFileSystemEntity(FileSystemEntity entity, FileStat stat) {
    final name = entity.path.split(Platform.pathSeparator).last;
    return LocalFile(
      path: entity.path,
      name: name,
      size: stat.size,
      modifiedAt: stat.modified,
      isDirectory: entity is Directory,
    );
  }

  String get extension {
    if (isDirectory) return '';
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex == name.length - 1) return '';
    return name.substring(dotIndex + 1).toLowerCase();
  }

  bool get isImage {
    final ext = extension;
    return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'svg'].contains(ext);
  }

  bool get isVideo {
    final ext = extension;
    return ['mp4', 'mov', 'avi', 'mkv', 'webm', 'flv', 'm4v', '3gp'].contains(ext);
  }

  bool get isAudio {
    final ext = extension;
    return ['mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a', 'wma'].contains(ext);
  }

  bool get isDocument {
    final ext = extension;
    return ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf', 'md'].contains(ext);
  }

  bool get isArchive {
    final ext = extension;
    return ['zip', 'rar', '7z', 'tar', 'gz', 'bz2'].contains(ext);
  }

  bool get isCode {
    final ext = extension;
    return ['dart', 'py', 'js', 'ts', 'java', 'kt', 'swift', 'c', 'cpp', 'h', 'cs', 'go', 'rs', 'rb', 'php', 'html', 'css', 'json', 'xml', 'yaml', 'yml'].contains(ext);
  }

  String get sizeFormatted {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
