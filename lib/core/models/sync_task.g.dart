// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sync_task.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SyncTaskStatusAdapter extends TypeAdapter<SyncTaskStatus> {
  @override
  final int typeId = 14;

  @override
  SyncTaskStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return SyncTaskStatus.pending;
      case 1:
        return SyncTaskStatus.inProgress;
      case 2:
        return SyncTaskStatus.completed;
      case 3:
        return SyncTaskStatus.failed;
      default:
        return SyncTaskStatus.pending;
    }
  }

  @override
  void write(BinaryWriter writer, SyncTaskStatus obj) {
    switch (obj) {
      case SyncTaskStatus.pending:
        writer.writeByte(0);
        break;
      case SyncTaskStatus.inProgress:
        writer.writeByte(1);
        break;
      case SyncTaskStatus.completed:
        writer.writeByte(2);
        break;
      case SyncTaskStatus.failed:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncTaskStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class SyncTaskDirectionAdapter extends TypeAdapter<SyncTaskDirection> {
  @override
  final int typeId = 15;

  @override
  SyncTaskDirection read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return SyncTaskDirection.upload;
      case 1:
        return SyncTaskDirection.download;
      default:
        return SyncTaskDirection.upload;
    }
  }

  @override
  void write(BinaryWriter writer, SyncTaskDirection obj) {
    switch (obj) {
      case SyncTaskDirection.upload:
        writer.writeByte(0);
        break;
      case SyncTaskDirection.download:
        writer.writeByte(1);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncTaskDirectionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class SyncTaskAdapter extends TypeAdapter<SyncTask> {
  @override
  final int typeId = 16;

  @override
  SyncTask read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SyncTask(
      id: fields[0] as String,
      localPath: fields[1] as String,
      remoteBucket: fields[2] as String,
      remoteKey: fields[3] as String,
      direction: fields[4] as SyncTaskDirection,
      encrypt: fields[5] as bool,
      status: fields[6] as SyncTaskStatus,
      createdAt: fields[7] as DateTime?,
      startedAt: fields[8] as DateTime?,
      completedAt: fields[9] as DateTime?,
      errorMessage: fields[10] as String?,
      retryCount: fields[11] as int,
    );
  }

  @override
  void write(BinaryWriter writer, SyncTask obj) {
    writer
      ..writeByte(12)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.localPath)
      ..writeByte(2)
      ..write(obj.remoteBucket)
      ..writeByte(3)
      ..write(obj.remoteKey)
      ..writeByte(4)
      ..write(obj.direction)
      ..writeByte(5)
      ..write(obj.encrypt)
      ..writeByte(6)
      ..write(obj.status)
      ..writeByte(7)
      ..write(obj.createdAt)
      ..writeByte(8)
      ..write(obj.startedAt)
      ..writeByte(9)
      ..write(obj.completedAt)
      ..writeByte(10)
      ..write(obj.errorMessage)
      ..writeByte(11)
      ..write(obj.retryCount);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncTaskAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
