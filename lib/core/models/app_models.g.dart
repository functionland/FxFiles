// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_models.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ActivatedAppAdapter extends TypeAdapter<ActivatedApp> {
  @override
  final int typeId = 40;

  @override
  ActivatedApp read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ActivatedApp(
      appId: fields[0] as String,
      activatedAt: fields[1] as DateTime,
      status: fields[2] as AppStatus? ?? AppStatus.active,
      errorMessage: fields[3] as String?,
      lastBackupAt: fields[4] as DateTime?,
      iosFolderPath: fields[5] as String?,
      hasPassword: fields[6] as bool? ?? false,
    );
  }

  @override
  void write(BinaryWriter writer, ActivatedApp obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.appId)
      ..writeByte(1)
      ..write(obj.activatedAt)
      ..writeByte(2)
      ..write(obj.status)
      ..writeByte(3)
      ..write(obj.errorMessage)
      ..writeByte(4)
      ..write(obj.lastBackupAt)
      ..writeByte(5)
      ..write(obj.iosFolderPath)
      ..writeByte(6)
      ..write(obj.hasPassword);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActivatedAppAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AppStatusAdapter extends TypeAdapter<AppStatus> {
  @override
  final int typeId = 41;

  @override
  AppStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return AppStatus.active;
      case 1:
        return AppStatus.disabled;
      case 2:
        return AppStatus.error;
      default:
        return AppStatus.active;
    }
  }

  @override
  void write(BinaryWriter writer, AppStatus obj) {
    switch (obj) {
      case AppStatus.active:
        writer.writeByte(0);
        break;
      case AppStatus.disabled:
        writer.writeByte(1);
        break;
      case AppStatus.error:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class BackupRecordAdapter extends TypeAdapter<BackupRecord> {
  @override
  final int typeId = 42;

  @override
  BackupRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return BackupRecord(
      id: fields[0] as String,
      appId: fields[1] as String,
      startedAt: fields[2] as DateTime,
      completedAt: fields[3] as DateTime?,
      status: fields[4] as BackupStatus? ?? BackupStatus.pending,
      newFileCount: fields[5] as int? ?? 0,
      totalFileCount: fields[6] as int? ?? 0,
      totalSizeBytes: fields[7] as int? ?? 0,
      errorMessage: fields[8] as String?,
      platform: fields[9] as String? ?? 'unknown',
      categoryCounts: (fields[10] as Map?)?.cast<String, int>() ?? {},
    );
  }

  @override
  void write(BinaryWriter writer, BackupRecord obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.appId)
      ..writeByte(2)
      ..write(obj.startedAt)
      ..writeByte(3)
      ..write(obj.completedAt)
      ..writeByte(4)
      ..write(obj.status)
      ..writeByte(5)
      ..write(obj.newFileCount)
      ..writeByte(6)
      ..write(obj.totalFileCount)
      ..writeByte(7)
      ..write(obj.totalSizeBytes)
      ..writeByte(8)
      ..write(obj.errorMessage)
      ..writeByte(9)
      ..write(obj.platform)
      ..writeByte(10)
      ..write(obj.categoryCounts);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class BackupStatusAdapter extends TypeAdapter<BackupStatus> {
  @override
  final int typeId = 43;

  @override
  BackupStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return BackupStatus.pending;
      case 1:
        return BackupStatus.scanning;
      case 2:
        return BackupStatus.uploading;
      case 3:
        return BackupStatus.completed;
      case 4:
        return BackupStatus.error;
      case 5:
        return BackupStatus.cancelled;
      default:
        return BackupStatus.pending;
    }
  }

  @override
  void write(BinaryWriter writer, BackupStatus obj) {
    switch (obj) {
      case BackupStatus.pending:
        writer.writeByte(0);
        break;
      case BackupStatus.scanning:
        writer.writeByte(1);
        break;
      case BackupStatus.uploading:
        writer.writeByte(2);
        break;
      case BackupStatus.completed:
        writer.writeByte(3);
        break;
      case BackupStatus.error:
        writer.writeByte(4);
        break;
      case BackupStatus.cancelled:
        writer.writeByte(5);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class BackupFileEntryAdapter extends TypeAdapter<BackupFileEntry> {
  @override
  final int typeId = 44;

  @override
  BackupFileEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return BackupFileEntry(
      relativePath: fields[0] as String,
      sizeBytes: fields[1] as int? ?? 0,
      modifiedAt: fields[2] as DateTime,
      contentHash: fields[3] as String,
      backupId: fields[4] as String,
      remoteKey: fields[5] as String,
      category: fields[6] as BackupCategory? ?? BackupCategory.other,
    );
  }

  @override
  void write(BinaryWriter writer, BackupFileEntry obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.relativePath)
      ..writeByte(1)
      ..write(obj.sizeBytes)
      ..writeByte(2)
      ..write(obj.modifiedAt)
      ..writeByte(3)
      ..write(obj.contentHash)
      ..writeByte(4)
      ..write(obj.backupId)
      ..writeByte(5)
      ..write(obj.remoteKey)
      ..writeByte(6)
      ..write(obj.category);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupFileEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class BackupCategoryAdapter extends TypeAdapter<BackupCategory> {
  @override
  final int typeId = 45;

  @override
  BackupCategory read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return BackupCategory.messages;
      case 1:
        return BackupCategory.images;
      case 2:
        return BackupCategory.videos;
      case 3:
        return BackupCategory.audio;
      case 4:
        return BackupCategory.documents;
      case 5:
        return BackupCategory.voiceNotes;
      case 6:
        return BackupCategory.stickers;
      case 7:
        return BackupCategory.other;
      default:
        return BackupCategory.other;
    }
  }

  @override
  void write(BinaryWriter writer, BackupCategory obj) {
    switch (obj) {
      case BackupCategory.messages:
        writer.writeByte(0);
        break;
      case BackupCategory.images:
        writer.writeByte(1);
        break;
      case BackupCategory.videos:
        writer.writeByte(2);
        break;
      case BackupCategory.audio:
        writer.writeByte(3);
        break;
      case BackupCategory.documents:
        writer.writeByte(4);
        break;
      case BackupCategory.voiceNotes:
        writer.writeByte(5);
        break;
      case BackupCategory.stickers:
        writer.writeByte(6);
        break;
      case BackupCategory.other:
        writer.writeByte(7);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupCategoryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
