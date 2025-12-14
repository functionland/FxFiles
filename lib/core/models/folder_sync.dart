import 'package:hive_flutter/hive_flutter.dart';

part 'folder_sync.g.dart';

@HiveType(typeId: 4)
enum FolderSyncStatus {
  @HiveField(0)
  disabled,
  
  @HiveField(1)
  enabled,
  
  @HiveField(2)
  syncing,
  
  @HiveField(3)
  synced,
  
  @HiveField(4)
  error,
}

@HiveType(typeId: 5)
class FolderSync extends HiveObject {
  @HiveField(0)
  final String path;

  @HiveField(1)
  final String? categoryName;

  @HiveField(2)
  final String targetBucket;

  @HiveField(3)
  FolderSyncStatus status;

  @HiveField(4)
  final DateTime? lastSyncedAt;

  @HiveField(5)
  final int totalFiles;

  @HiveField(6)
  final int syncedFiles;

  @HiveField(7)
  final String? errorMessage;

  @HiveField(8)
  final bool isCategory;

  FolderSync({
    required this.path,
    this.categoryName,
    required this.targetBucket,
    this.status = FolderSyncStatus.disabled,
    this.lastSyncedAt,
    this.totalFiles = 0,
    this.syncedFiles = 0,
    this.errorMessage,
    this.isCategory = false,
  });

  FolderSync copyWith({
    String? path,
    String? categoryName,
    String? targetBucket,
    FolderSyncStatus? status,
    DateTime? lastSyncedAt,
    int? totalFiles,
    int? syncedFiles,
    String? errorMessage,
    bool? isCategory,
  }) {
    return FolderSync(
      path: path ?? this.path,
      categoryName: categoryName ?? this.categoryName,
      targetBucket: targetBucket ?? this.targetBucket,
      status: status ?? this.status,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      totalFiles: totalFiles ?? this.totalFiles,
      syncedFiles: syncedFiles ?? this.syncedFiles,
      errorMessage: errorMessage ?? this.errorMessage,
      isCategory: isCategory ?? this.isCategory,
    );
  }

  bool get isEnabled => status != FolderSyncStatus.disabled;
  bool get isSyncing => status == FolderSyncStatus.syncing;
  bool get isSynced => status == FolderSyncStatus.synced;
  bool get hasError => status == FolderSyncStatus.error;
  
  double get syncProgress => totalFiles > 0 ? syncedFiles / totalFiles : 0.0;
  
  String get displayName => categoryName ?? path.split('/').last;
}
