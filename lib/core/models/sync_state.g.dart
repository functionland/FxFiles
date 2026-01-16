// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sync_state.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SyncStatusAdapter extends TypeAdapter<SyncStatus> {
  @override
  final int typeId = 0;

  @override
  SyncStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return SyncStatus.notSynced;
      case 1:
        return SyncStatus.syncing;
      case 2:
        return SyncStatus.synced;
      case 3:
        return SyncStatus.error;
      default:
        return SyncStatus.notSynced;
    }
  }

  @override
  void write(BinaryWriter writer, SyncStatus obj) {
    switch (obj) {
      case SyncStatus.notSynced:
        writer.writeByte(0);
        break;
      case SyncStatus.syncing:
        writer.writeByte(1);
        break;
      case SyncStatus.synced:
        writer.writeByte(2);
        break;
      case SyncStatus.error:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class SyncStateAdapter extends TypeAdapter<SyncState> {
  @override
  final int typeId = 1;

  @override
  SyncState read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SyncState(
      localPath: fields[0] as String,
      remotePath: fields[1] as String?,
      remoteKey: fields[2] as String?,
      bucket: fields[3] as String?,
      status: fields[4] as SyncStatus,
      lastSyncedAt: fields[5] as DateTime?,
      etag: fields[6] as String?,
      localSize: fields[7] as int?,
      remoteSize: fields[8] as int?,
      errorMessage: fields[9] as String?,
      displayPath: fields[10] as String?,
      iosAssetId: fields[11] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, SyncState obj) {
    writer
      ..writeByte(12)
      ..writeByte(0)
      ..write(obj.localPath)
      ..writeByte(1)
      ..write(obj.remotePath)
      ..writeByte(2)
      ..write(obj.remoteKey)
      ..writeByte(3)
      ..write(obj.bucket)
      ..writeByte(4)
      ..write(obj.status)
      ..writeByte(5)
      ..write(obj.lastSyncedAt)
      ..writeByte(6)
      ..write(obj.etag)
      ..writeByte(7)
      ..write(obj.localSize)
      ..writeByte(8)
      ..write(obj.remoteSize)
      ..writeByte(9)
      ..write(obj.errorMessage)
      ..writeByte(10)
      ..write(obj.displayPath)
      ..writeByte(11)
      ..write(obj.iosAssetId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncStateAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
