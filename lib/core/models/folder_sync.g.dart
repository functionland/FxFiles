// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'folder_sync.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class FolderSyncStatusAdapter extends TypeAdapter<FolderSyncStatus> {
  @override
  final int typeId = 4;

  @override
  FolderSyncStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return FolderSyncStatus.disabled;
      case 1:
        return FolderSyncStatus.enabled;
      case 2:
        return FolderSyncStatus.syncing;
      case 3:
        return FolderSyncStatus.synced;
      case 4:
        return FolderSyncStatus.error;
      default:
        return FolderSyncStatus.disabled;
    }
  }

  @override
  void write(BinaryWriter writer, FolderSyncStatus obj) {
    switch (obj) {
      case FolderSyncStatus.disabled:
        writer.writeByte(0);
        break;
      case FolderSyncStatus.enabled:
        writer.writeByte(1);
        break;
      case FolderSyncStatus.syncing:
        writer.writeByte(2);
        break;
      case FolderSyncStatus.synced:
        writer.writeByte(3);
        break;
      case FolderSyncStatus.error:
        writer.writeByte(4);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FolderSyncStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class FolderSyncAdapter extends TypeAdapter<FolderSync> {
  @override
  final int typeId = 5;

  @override
  FolderSync read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return FolderSync(
      path: fields[0] as String,
      categoryName: fields[1] as String?,
      targetBucket: fields[2] as String,
      status: fields[3] as FolderSyncStatus,
      lastSyncedAt: fields[4] as DateTime?,
      totalFiles: fields[5] as int,
      syncedFiles: fields[6] as int,
      errorMessage: fields[7] as String?,
      isCategory: fields[8] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, FolderSync obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.path)
      ..writeByte(1)
      ..write(obj.categoryName)
      ..writeByte(2)
      ..write(obj.targetBucket)
      ..writeByte(3)
      ..write(obj.status)
      ..writeByte(4)
      ..write(obj.lastSyncedAt)
      ..writeByte(5)
      ..write(obj.totalFiles)
      ..writeByte(6)
      ..write(obj.syncedFiles)
      ..writeByte(7)
      ..write(obj.errorMessage)
      ..writeByte(8)
      ..write(obj.isCategory);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FolderSyncAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
