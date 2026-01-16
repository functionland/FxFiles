import 'package:hive_flutter/hive_flutter.dart';

part 'recent_file.g.dart';

@HiveType(typeId: 2)
class RecentFile extends HiveObject {
  @HiveField(0)
  final String path;

  @HiveField(1)
  final String name;

  @HiveField(2)
  final String? mimeType;

  @HiveField(3)
  final int size;

  @HiveField(4)
  final DateTime accessedAt;

  @HiveField(5)
  final bool isRemote;

  @HiveField(6)
  final String? thumbnailPath;

  @HiveField(7)
  final String? iosAssetId;

  RecentFile({
    required this.path,
    required this.name,
    this.mimeType,
    required this.size,
    required this.accessedAt,
    this.isRemote = false,
    this.thumbnailPath,
    this.iosAssetId,
  });

  String get extension {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex == name.length - 1) return '';
    return name.substring(dotIndex + 1).toLowerCase();
  }

  bool get isImage {
    final ext = extension;
    return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif'].contains(ext);
  }

  bool get isVideo {
    final ext = extension;
    return ['mp4', 'mov', 'avi', 'mkv', 'webm', 'flv', 'm4v'].contains(ext);
  }

  bool get isAudio {
    final ext = extension;
    return ['mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a', 'wma'].contains(ext);
  }

  bool get isDocument {
    final ext = extension;
    return ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf'].contains(ext);
  }
}
