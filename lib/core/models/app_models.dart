import 'dart:io';
import 'package:hive_flutter/hive_flutter.dart';

part 'app_models.g.dart';

/// Definition of an app available in the app store (not persisted in Hive).
class AppDefinition {
  final String id;
  final String name;
  final String description;
  final String iconName;
  final int colorValue;
  final List<String> supportedPlatforms;
  final String? dataPathAndroid;
  final String? dataPathAndroidLegacy;

  const AppDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.iconName,
    required this.colorValue,
    required this.supportedPlatforms,
    this.dataPathAndroid,
    this.dataPathAndroidLegacy,
  });

  bool get supportedOnCurrentPlatform {
    if (Platform.isAndroid) return supportedPlatforms.contains('android');
    if (Platform.isIOS) return supportedPlatforms.contains('ios');
    if (Platform.isWindows) return supportedPlatforms.contains('windows');
    if (Platform.isMacOS) return supportedPlatforms.contains('macos');
    if (Platform.isLinux) return supportedPlatforms.contains('linux');
    return false;
  }
}

/// Status of an activated app
@HiveType(typeId: 41)
enum AppStatus {
  @HiveField(0)
  active,
  @HiveField(1)
  disabled,
  @HiveField(2)
  error,
}

/// A user-activated app with its configuration
@HiveType(typeId: 40)
class ActivatedApp extends HiveObject {
  @HiveField(0)
  final String appId;

  @HiveField(1)
  final DateTime activatedAt;

  @HiveField(2)
  AppStatus status;

  @HiveField(3)
  String? errorMessage;

  @HiveField(4)
  DateTime? lastBackupAt;

  @HiveField(5)
  String? iosFolderPath;

  @HiveField(6)
  bool hasPassword;

  ActivatedApp({
    required this.appId,
    required this.activatedAt,
    this.status = AppStatus.active,
    this.errorMessage,
    this.lastBackupAt,
    this.iosFolderPath,
    this.hasPassword = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'appId': appId,
      'activatedAt': activatedAt.toIso8601String(),
      'status': status.index,
      'errorMessage': errorMessage,
      'lastBackupAt': lastBackupAt?.toIso8601String(),
      'iosFolderPath': iosFolderPath,
      'hasPassword': hasPassword,
    };
  }

  factory ActivatedApp.fromJson(Map<String, dynamic> json) {
    return ActivatedApp(
      appId: json['appId'] as String,
      activatedAt: DateTime.parse(json['activatedAt'] as String),
      status: AppStatus.values[json['status'] as int? ?? 0],
      errorMessage: json['errorMessage'] as String?,
      lastBackupAt: json['lastBackupAt'] != null
          ? DateTime.parse(json['lastBackupAt'] as String)
          : null,
      iosFolderPath: json['iosFolderPath'] as String?,
      hasPassword: json['hasPassword'] as bool? ?? false,
    );
  }
}

/// Status of a backup operation
@HiveType(typeId: 43)
enum BackupStatus {
  @HiveField(0)
  pending,
  @HiveField(1)
  scanning,
  @HiveField(2)
  uploading,
  @HiveField(3)
  completed,
  @HiveField(4)
  error,
  @HiveField(5)
  cancelled,
}

/// Record of a single backup session
@HiveType(typeId: 42)
class BackupRecord extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String appId;

  @HiveField(2)
  final DateTime startedAt;

  @HiveField(3)
  DateTime? completedAt;

  @HiveField(4)
  BackupStatus status;

  @HiveField(5)
  int newFileCount;

  @HiveField(6)
  int totalFileCount;

  @HiveField(7)
  int totalSizeBytes;

  @HiveField(8)
  String? errorMessage;

  @HiveField(9)
  final String platform;

  @HiveField(10)
  Map<String, int> categoryCounts;

  BackupRecord({
    required this.id,
    required this.appId,
    required this.startedAt,
    this.completedAt,
    this.status = BackupStatus.pending,
    this.newFileCount = 0,
    this.totalFileCount = 0,
    this.totalSizeBytes = 0,
    this.errorMessage,
    required this.platform,
    this.categoryCounts = const {},
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'appId': appId,
      'startedAt': startedAt.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'status': status.index,
      'newFileCount': newFileCount,
      'totalFileCount': totalFileCount,
      'totalSizeBytes': totalSizeBytes,
      'errorMessage': errorMessage,
      'platform': platform,
      'categoryCounts': categoryCounts,
    };
  }

  factory BackupRecord.fromJson(Map<String, dynamic> json) {
    return BackupRecord(
      id: json['id'] as String,
      appId: json['appId'] as String,
      startedAt: DateTime.parse(json['startedAt'] as String),
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'] as String)
          : null,
      status: BackupStatus.values[json['status'] as int? ?? 0],
      newFileCount: json['newFileCount'] as int? ?? 0,
      totalFileCount: json['totalFileCount'] as int? ?? 0,
      totalSizeBytes: json['totalSizeBytes'] as int? ?? 0,
      errorMessage: json['errorMessage'] as String?,
      platform: json['platform'] as String? ?? 'unknown',
      categoryCounts: (json['categoryCounts'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as int)) ??
          {},
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BackupRecord && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Category of a backed-up file
@HiveType(typeId: 45)
enum BackupCategory {
  @HiveField(0)
  messages,
  @HiveField(1)
  images,
  @HiveField(2)
  videos,
  @HiveField(3)
  audio,
  @HiveField(4)
  documents,
  @HiveField(5)
  voiceNotes,
  @HiveField(6)
  stickers,
  @HiveField(7)
  other,
}

/// An individual file entry in the backup manifest
@HiveType(typeId: 44)
class BackupFileEntry extends HiveObject {
  @HiveField(0)
  final String relativePath;

  @HiveField(1)
  final int sizeBytes;

  @HiveField(2)
  final DateTime modifiedAt;

  @HiveField(3)
  final String contentHash;

  @HiveField(4)
  final String backupId;

  @HiveField(5)
  final String remoteKey;

  @HiveField(6)
  final BackupCategory category;

  BackupFileEntry({
    required this.relativePath,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.contentHash,
    required this.backupId,
    required this.remoteKey,
    required this.category,
  });

  Map<String, dynamic> toJson() {
    return {
      'relativePath': relativePath,
      'sizeBytes': sizeBytes,
      'modifiedAt': modifiedAt.toIso8601String(),
      'contentHash': contentHash,
      'backupId': backupId,
      'remoteKey': remoteKey,
      'category': category.index,
    };
  }

  factory BackupFileEntry.fromJson(Map<String, dynamic> json) {
    return BackupFileEntry(
      relativePath: json['relativePath'] as String,
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      modifiedAt: DateTime.parse(json['modifiedAt'] as String),
      contentHash: json['contentHash'] as String,
      backupId: json['backupId'] as String,
      remoteKey: json['remoteKey'] as String,
      category: BackupCategory.values[json['category'] as int? ?? 7],
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BackupFileEntry && other.relativePath == relativePath;
  }

  @override
  int get hashCode => relativePath.hashCode;
}
