import 'package:hive_flutter/hive_flutter.dart';

part 'sync_state.g.dart';

@HiveType(typeId: 0)
enum SyncStatus {
  @HiveField(0)
  notSynced,
  
  @HiveField(1)
  syncing,
  
  @HiveField(2)
  synced,
  
  @HiveField(3)
  error,
}

@HiveType(typeId: 1)
class SyncState extends HiveObject {
  @HiveField(0)
  final String localPath;

  @HiveField(1)
  final String? remotePath;

  @HiveField(2)
  final String? remoteKey;

  @HiveField(3)
  final String? bucket;

  @HiveField(4)
  SyncStatus status;

  @HiveField(5)
  final DateTime? lastSyncedAt;

  @HiveField(6)
  final String? etag;

  @HiveField(7)
  final int? localSize;

  @HiveField(8)
  final int? remoteSize;

  @HiveField(9)
  final String? errorMessage;

  @HiveField(10)
  final String? displayPath; // Virtual path for iOS PhotoKit files (for UI lookup)

  @HiveField(11)
  final String? iosAssetId; // iOS PhotoKit asset ID for stable identification

  SyncState({
    required this.localPath,
    this.remotePath,
    this.remoteKey,
    this.bucket,
    this.status = SyncStatus.notSynced,
    this.lastSyncedAt,
    this.etag,
    this.localSize,
    this.remoteSize,
    this.errorMessage,
    this.displayPath,
    this.iosAssetId,
  });

  SyncState copyWith({
    String? localPath,
    String? remotePath,
    String? remoteKey,
    String? bucket,
    SyncStatus? status,
    DateTime? lastSyncedAt,
    String? etag,
    int? localSize,
    int? remoteSize,
    String? errorMessage,
    String? displayPath,
    String? iosAssetId,
  }) {
    return SyncState(
      localPath: localPath ?? this.localPath,
      remotePath: remotePath ?? this.remotePath,
      remoteKey: remoteKey ?? this.remoteKey,
      bucket: bucket ?? this.bucket,
      status: status ?? this.status,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      etag: etag ?? this.etag,
      localSize: localSize ?? this.localSize,
      remoteSize: remoteSize ?? this.remoteSize,
      errorMessage: errorMessage ?? this.errorMessage,
      displayPath: displayPath ?? this.displayPath,
      iosAssetId: iosAssetId ?? this.iosAssetId,
    );
  }

  bool get isSynced => status == SyncStatus.synced;
  bool get isSyncing => status == SyncStatus.syncing;
  bool get hasError => status == SyncStatus.error;
}
