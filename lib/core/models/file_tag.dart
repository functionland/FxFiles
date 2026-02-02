import 'package:hive_flutter/hive_flutter.dart';

part 'file_tag.g.dart';

/// Represents a user-created tag with a name and color
@HiveType(typeId: 20)
class FileTag extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  int colorValue; // Store color as int (Color.value)

  @HiveField(3)
  final DateTime createdAt;

  @HiveField(4)
  DateTime updatedAt;

  @HiveField(5)
  int fileCount;

  FileTag({
    required this.id,
    required this.name,
    required this.colorValue,
    required this.createdAt,
    required this.updatedAt,
    this.fileCount = 0,
  });

  FileTag copyWith({
    String? id,
    String? name,
    int? colorValue,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? fileCount,
  }) {
    return FileTag(
      id: id ?? this.id,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      fileCount: fileCount ?? this.fileCount,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'colorValue': colorValue,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'fileCount': fileCount,
    };
  }

  factory FileTag.fromJson(Map<String, dynamic> json) {
    return FileTag(
      id: json['id'] as String,
      name: json['name'] as String,
      colorValue: json['colorValue'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      fileCount: json['fileCount'] as int? ?? 0,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FileTag && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Represents a file-to-tag association
@HiveType(typeId: 21)
class TaggedFile extends HiveObject {
  @HiveField(0)
  final String id; // Unique ID for this association

  @HiveField(1)
  final String tagId; // Reference to FileTag.id

  @HiveField(2)
  final String? localPath; // Local file path (Android)

  @HiveField(3)
  final String? remoteKey; // Cloud file key (for cloud files)

  @HiveField(4)
  final String? iosAssetId; // iOS PhotoKit asset ID

  @HiveField(5)
  final String fileName; // File name for display

  @HiveField(6)
  final DateTime taggedAt;

  TaggedFile({
    required this.id,
    required this.tagId,
    this.localPath,
    this.remoteKey,
    this.iosAssetId,
    required this.fileName,
    required this.taggedAt,
  });

  /// Create a unique file identifier for lookups
  String get fileIdentifier {
    // Prefer iOS asset ID, then local path, then remote key
    return iosAssetId ?? localPath ?? remoteKey ?? '';
  }

  TaggedFile copyWith({
    String? id,
    String? tagId,
    String? localPath,
    String? remoteKey,
    String? iosAssetId,
    String? fileName,
    DateTime? taggedAt,
  }) {
    return TaggedFile(
      id: id ?? this.id,
      tagId: tagId ?? this.tagId,
      localPath: localPath ?? this.localPath,
      remoteKey: remoteKey ?? this.remoteKey,
      iosAssetId: iosAssetId ?? this.iosAssetId,
      fileName: fileName ?? this.fileName,
      taggedAt: taggedAt ?? this.taggedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'tagId': tagId,
      'localPath': localPath,
      'remoteKey': remoteKey,
      'iosAssetId': iosAssetId,
      'fileName': fileName,
      'taggedAt': taggedAt.toIso8601String(),
    };
  }

  factory TaggedFile.fromJson(Map<String, dynamic> json) {
    return TaggedFile(
      id: json['id'] as String,
      tagId: json['tagId'] as String,
      localPath: json['localPath'] as String?,
      remoteKey: json['remoteKey'] as String?,
      iosAssetId: json['iosAssetId'] as String?,
      fileName: json['fileName'] as String,
      taggedAt: DateTime.parse(json['taggedAt'] as String),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TaggedFile && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Cloud metadata structure for tags backup
class TagCloudMetadata {
  final String userId;
  final List<FileTag> tags;
  final List<TaggedFile> taggedFiles;
  final DateTime updatedAt;
  final String version;

  TagCloudMetadata({
    required this.userId,
    required this.tags,
    required this.taggedFiles,
    required this.updatedAt,
    this.version = '1.0',
  });

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'tags': tags.map((t) => t.toJson()).toList(),
      'taggedFiles': taggedFiles.map((f) => f.toJson()).toList(),
      'updatedAt': updatedAt.toIso8601String(),
      'version': version,
    };
  }

  factory TagCloudMetadata.fromJson(Map<String, dynamic> json) {
    return TagCloudMetadata(
      userId: json['userId'] as String,
      tags: (json['tags'] as List<dynamic>)
          .map((t) => FileTag.fromJson(t as Map<String, dynamic>))
          .toList(),
      taggedFiles: (json['taggedFiles'] as List<dynamic>)
          .map((f) => TaggedFile.fromJson(f as Map<String, dynamic>))
          .toList(),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      version: json['version'] as String? ?? '1.0',
    );
  }
}

/// Predefined tag colors for user selection
class TagColors {
  static const List<int> presetColors = [
    0xFFE53935, // Red
    0xFFD81B60, // Pink
    0xFF8E24AA, // Purple
    0xFF5E35B1, // Deep Purple
    0xFF3949AB, // Indigo
    0xFF1E88E5, // Blue
    0xFF039BE5, // Light Blue
    0xFF00ACC1, // Cyan
    0xFF00897B, // Teal
    0xFF43A047, // Green
    0xFF7CB342, // Light Green
    0xFFC0CA33, // Lime
    0xFFFDD835, // Yellow
    0xFFFFB300, // Amber
    0xFFFB8C00, // Orange
    0xFFF4511E, // Deep Orange
    0xFF6D4C41, // Brown
    0xFF757575, // Grey
    0xFF546E7A, // Blue Grey
  ];

  static int getRandomColor() {
    return presetColors[DateTime.now().millisecondsSinceEpoch % presetColors.length];
  }
}
