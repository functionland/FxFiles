import 'package:hive_flutter/hive_flutter.dart';

part 'sync_task.g.dart';

@HiveType(typeId: 14)
enum SyncTaskStatus {
  @HiveField(0)
  pending,

  @HiveField(1)
  inProgress,

  @HiveField(2)
  completed,

  @HiveField(3)
  failed,
}

@HiveType(typeId: 15)
enum SyncTaskDirection {
  @HiveField(0)
  upload,

  @HiveField(1)
  download,
}

@HiveType(typeId: 16)
class SyncTask extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String localPath;

  @HiveField(2)
  final String remoteBucket;

  @HiveField(3)
  final String remoteKey;

  @HiveField(4)
  final SyncTaskDirection direction;

  @HiveField(5)
  final bool encrypt;

  @HiveField(6)
  SyncTaskStatus status;

  @HiveField(7)
  final DateTime createdAt;

  @HiveField(8)
  DateTime? startedAt;

  @HiveField(9)
  DateTime? completedAt;

  @HiveField(10)
  String? errorMessage;

  @HiveField(11)
  int retryCount;

  SyncTask({
    required this.id,
    required this.localPath,
    required this.remoteBucket,
    required this.remoteKey,
    required this.direction,
    this.encrypt = true,
    this.status = SyncTaskStatus.pending,
    DateTime? createdAt,
    this.startedAt,
    this.completedAt,
    this.errorMessage,
    this.retryCount = 0,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Generate a unique ID for a new task
  static String generateId() {
    return '${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}';
  }

  /// Create an upload task
  factory SyncTask.upload({
    required String localPath,
    required String remoteBucket,
    required String remoteKey,
    bool encrypt = true,
  }) {
    return SyncTask(
      id: generateId(),
      localPath: localPath,
      remoteBucket: remoteBucket,
      remoteKey: remoteKey,
      direction: SyncTaskDirection.upload,
      encrypt: encrypt,
    );
  }

  /// Create a download task
  factory SyncTask.download({
    required String localPath,
    required String remoteBucket,
    required String remoteKey,
    bool decrypt = true,
  }) {
    return SyncTask(
      id: generateId(),
      localPath: localPath,
      remoteBucket: remoteBucket,
      remoteKey: remoteKey,
      direction: SyncTaskDirection.download,
      encrypt: decrypt,
    );
  }

  SyncTask copyWith({
    String? id,
    String? localPath,
    String? remoteBucket,
    String? remoteKey,
    SyncTaskDirection? direction,
    bool? encrypt,
    SyncTaskStatus? status,
    DateTime? createdAt,
    DateTime? startedAt,
    DateTime? completedAt,
    String? errorMessage,
    int? retryCount,
  }) {
    return SyncTask(
      id: id ?? this.id,
      localPath: localPath ?? this.localPath,
      remoteBucket: remoteBucket ?? this.remoteBucket,
      remoteKey: remoteKey ?? this.remoteKey,
      direction: direction ?? this.direction,
      encrypt: encrypt ?? this.encrypt,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      errorMessage: errorMessage ?? this.errorMessage,
      retryCount: retryCount ?? this.retryCount,
    );
  }

  bool get isPending => status == SyncTaskStatus.pending;
  bool get isInProgress => status == SyncTaskStatus.inProgress;
  bool get isCompleted => status == SyncTaskStatus.completed;
  bool get isFailed => status == SyncTaskStatus.failed;
  bool get isUpload => direction == SyncTaskDirection.upload;
  bool get isDownload => direction == SyncTaskDirection.download;
}
