import 'package:hive_flutter/hive_flutter.dart';

part 'dump_item.g.dart';

@HiveType(typeId: 60)
enum DumpCategory {
  @HiveField(0)
  link,
  @HiveField(1)
  note,
  @HiveField(2)
  screenshot,
  @HiveField(3)
  image,
  @HiveField(4)
  video,
  @HiveField(5)
  audio,
  @HiveField(6)
  document,
  @HiveField(7)
  file,
  @HiveField(8)
  other,
}

@HiveType(typeId: 61)
enum DumpUploadStatus {
  @HiveField(0)
  pendingAuth,
  @HiveField(1)
  queued,
  @HiveField(2)
  uploading,
  @HiveField(3)
  uploaded,
  @HiveField(4)
  failed,
}

@HiveType(typeId: 63)
enum DumpEnrichmentStatus {
  @HiveField(0)
  pending,
  @HiveField(1)
  done,
  @HiveField(2)
  failed,
}

@HiveType(typeId: 62)
class DumpItem extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final DateTime receivedAt;

  @HiveField(2)
  final String originalName;

  @HiveField(3)
  final String? mimeType;

  @HiveField(4)
  final int sizeBytes;

  @HiveField(5)
  final String localCachePath;

  @HiveField(6)
  final String? remoteKey;

  @HiveField(7)
  final DumpCategory category;

  @HiveField(8)
  DumpUploadStatus uploadStatus;

  @HiveField(9)
  final String? sourceAppPackage;

  @HiveField(10)
  final String? textPayload;

  @HiveField(11)
  final List<String> mlLabels;

  @HiveField(12)
  final String contentSha;

  @HiveField(13)
  String? errorMessage;

  @HiveField(14)
  String? autoTitle;

  @HiveField(15)
  String? autoDescription;

  @HiveField(16)
  String? thumbnailPath;

  @HiveField(17)
  DumpEnrichmentStatus enrichmentStatus;

  DumpItem({
    required this.id,
    required this.receivedAt,
    required this.originalName,
    this.mimeType,
    required this.sizeBytes,
    required this.localCachePath,
    this.remoteKey,
    required this.category,
    this.uploadStatus = DumpUploadStatus.queued,
    this.sourceAppPackage,
    this.textPayload,
    this.mlLabels = const <String>[],
    required this.contentSha,
    this.errorMessage,
    this.autoTitle,
    this.autoDescription,
    this.thumbnailPath,
    this.enrichmentStatus = DumpEnrichmentStatus.pending,
  });

  DumpItem copyWith({
    String? id,
    DateTime? receivedAt,
    String? originalName,
    String? mimeType,
    int? sizeBytes,
    String? localCachePath,
    String? remoteKey,
    DumpCategory? category,
    DumpUploadStatus? uploadStatus,
    String? sourceAppPackage,
    String? textPayload,
    List<String>? mlLabels,
    String? contentSha,
    String? errorMessage,
    String? autoTitle,
    String? autoDescription,
    String? thumbnailPath,
    DumpEnrichmentStatus? enrichmentStatus,
  }) {
    return DumpItem(
      id: id ?? this.id,
      receivedAt: receivedAt ?? this.receivedAt,
      originalName: originalName ?? this.originalName,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      localCachePath: localCachePath ?? this.localCachePath,
      remoteKey: remoteKey ?? this.remoteKey,
      category: category ?? this.category,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      sourceAppPackage: sourceAppPackage ?? this.sourceAppPackage,
      textPayload: textPayload ?? this.textPayload,
      mlLabels: mlLabels ?? this.mlLabels,
      contentSha: contentSha ?? this.contentSha,
      errorMessage: errorMessage ?? this.errorMessage,
      autoTitle: autoTitle ?? this.autoTitle,
      autoDescription: autoDescription ?? this.autoDescription,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      enrichmentStatus: enrichmentStatus ?? this.enrichmentStatus,
    );
  }

  bool get isUploaded => uploadStatus == DumpUploadStatus.uploaded;
  bool get isQueued => uploadStatus == DumpUploadStatus.queued;
  bool get isUploading => uploadStatus == DumpUploadStatus.uploading;
  bool get isPendingAuth => uploadStatus == DumpUploadStatus.pendingAuth;
  bool get hasFailed => uploadStatus == DumpUploadStatus.failed;
}
