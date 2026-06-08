import 'package:hive_flutter/hive_flutter.dart';

part 'shelf_item.g.dart';

@HiveType(typeId: 60)
enum ShelfCategory {
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
enum ShelfUploadStatus {
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
enum ShelfEnrichmentStatus {
  @HiveField(0)
  pending,
  @HiveField(1)
  done,
  @HiveField(2)
  failed,
}

@HiveType(typeId: 62)
class ShelfItem extends HiveObject {
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
  final ShelfCategory category;

  @HiveField(8)
  ShelfUploadStatus uploadStatus;

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
  ShelfEnrichmentStatus enrichmentStatus;

  /// Cloud key (within the dump-thumbs bucket) for the encrypted JPEG
  /// thumbnail. Set after the enricher generates a local thumbnail
  /// AND the upload succeeds — until then it stays null and the tile
  /// falls back to the category icon. On a fresh device after
  /// `restoreFromCloud`, [thumbnailPath] is null but this key is
  /// preserved so a lazy fetch in the tile widget can rehydrate the
  /// local JPEG on demand.
  @HiveField(18)
  String? thumbnailRemoteKey;

  /// The cloud bucket the file BODY was written to (`dump` legacy, or
  /// `dump-v8` once the v8 migration routes it). Null on rows persisted
  /// before P7 — treated as the legacy `dump` bucket. Integrity-critical:
  /// it is the authoritative home used to route this item's body (and, by
  /// version, its thumbnail) on delete and on a future cloud body-download,
  /// so it stays correct even if the master v8 flag is later toggled.
  @HiveField(19)
  final String? sourceBucket;

  ShelfItem({
    required this.id,
    required this.receivedAt,
    required this.originalName,
    this.mimeType,
    required this.sizeBytes,
    required this.localCachePath,
    this.remoteKey,
    required this.category,
    this.uploadStatus = ShelfUploadStatus.queued,
    this.sourceAppPackage,
    this.textPayload,
    this.mlLabels = const <String>[],
    required this.contentSha,
    this.errorMessage,
    this.autoTitle,
    this.autoDescription,
    this.thumbnailPath,
    this.enrichmentStatus = ShelfEnrichmentStatus.pending,
    this.thumbnailRemoteKey,
    this.sourceBucket,
  });

  ShelfItem copyWith({
    String? id,
    DateTime? receivedAt,
    String? originalName,
    String? mimeType,
    int? sizeBytes,
    String? localCachePath,
    String? remoteKey,
    ShelfCategory? category,
    ShelfUploadStatus? uploadStatus,
    String? sourceAppPackage,
    String? textPayload,
    List<String>? mlLabels,
    String? contentSha,
    String? errorMessage,
    String? autoTitle,
    String? autoDescription,
    String? thumbnailPath,
    ShelfEnrichmentStatus? enrichmentStatus,
    String? thumbnailRemoteKey,
    String? sourceBucket,
  }) {
    return ShelfItem(
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
      thumbnailRemoteKey: thumbnailRemoteKey ?? this.thumbnailRemoteKey,
      sourceBucket: sourceBucket ?? this.sourceBucket,
    );
  }

  bool get isUploaded => uploadStatus == ShelfUploadStatus.uploaded;
  bool get isQueued => uploadStatus == ShelfUploadStatus.queued;
  bool get isUploading => uploadStatus == ShelfUploadStatus.uploading;
  bool get isPendingAuth => uploadStatus == ShelfUploadStatus.pendingAuth;
  bool get hasFailed => uploadStatus == ShelfUploadStatus.failed;

  /// JSON shape used for cloud-sync persistence. Deliberately excludes
  /// device-specific paths ([localCachePath], [thumbnailPath]) — those
  /// don't survive a reinstall and get rehydrated locally on demand.
  /// On restore, [fromJson] reconstructs the row with
  /// `localCachePath = ''` and `thumbnailPath = null`; the tile widget
  /// uses [thumbnailRemoteKey] to lazy-fetch a fresh JPEG, and the
  /// content viewer fetches from [remoteKey] when [localCachePath] is
  /// missing.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'receivedAt': receivedAt.toUtc().toIso8601String(),
        'originalName': originalName,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'remoteKey': remoteKey,
        'category': category.name,
        'uploadStatus': uploadStatus.name,
        'sourceAppPackage': sourceAppPackage,
        'textPayload': textPayload,
        'mlLabels': mlLabels,
        'contentSha': contentSha,
        'errorMessage': errorMessage,
        'autoTitle': autoTitle,
        'autoDescription': autoDescription,
        'thumbnailRemoteKey': thumbnailRemoteKey,
        'enrichmentStatus': enrichmentStatus.name,
        'sourceBucket': sourceBucket,
      };

  /// Rebuilds a [ShelfItem] from a cloud-sync JSON payload. Applies the
  /// status-normalization rule the user picked: any row carrying a
  /// non-null `remoteKey` is treated as `uploaded` regardless of what
  /// the persisted `uploadStatus` says — a row with a remoteKey is, by
  /// definition, uploaded.
  static ShelfItem fromJson(Map<String, dynamic> json) {
    final remoteKey = json['remoteKey'] as String?;
    final persistedStatus = _uploadStatusFromName(
      json['uploadStatus'] as String?,
    );
    final normalizedStatus = (remoteKey != null && remoteKey.isNotEmpty)
        ? ShelfUploadStatus.uploaded
        : persistedStatus;
    return ShelfItem(
      id: json['id'] as String,
      receivedAt: DateTime.parse(json['receivedAt'] as String),
      originalName: json['originalName'] as String,
      mimeType: json['mimeType'] as String?,
      sizeBytes: (json['sizeBytes'] as num).toInt(),
      localCachePath: '', // device-specific; rehydrated lazily
      remoteKey: remoteKey,
      category: _categoryFromName(json['category'] as String?),
      uploadStatus: normalizedStatus,
      sourceAppPackage: json['sourceAppPackage'] as String?,
      textPayload: json['textPayload'] as String?,
      mlLabels:
          (json['mlLabels'] as List?)?.cast<String>() ?? const <String>[],
      contentSha: json['contentSha'] as String? ?? '',
      errorMessage: json['errorMessage'] as String?,
      autoTitle: json['autoTitle'] as String?,
      autoDescription: json['autoDescription'] as String?,
      thumbnailPath: null,
      thumbnailRemoteKey: json['thumbnailRemoteKey'] as String?,
      enrichmentStatus:
          _enrichmentStatusFromName(json['enrichmentStatus'] as String?),
      sourceBucket: json['sourceBucket'] as String?,
    );
  }

  static ShelfCategory _categoryFromName(String? name) {
    for (final v in ShelfCategory.values) {
      if (v.name == name) return v;
    }
    return ShelfCategory.other;
  }

  static ShelfUploadStatus _uploadStatusFromName(String? name) {
    for (final v in ShelfUploadStatus.values) {
      if (v.name == name) return v;
    }
    return ShelfUploadStatus.queued;
  }

  static ShelfEnrichmentStatus _enrichmentStatusFromName(String? name) {
    for (final v in ShelfEnrichmentStatus.values) {
      if (v.name == name) return v;
    }
    return ShelfEnrichmentStatus.pending;
  }
}
