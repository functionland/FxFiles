// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'recent_file.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class RecentFileAdapter extends TypeAdapter<RecentFile> {
  @override
  final int typeId = 2;

  @override
  RecentFile read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return RecentFile(
      path: fields[0] as String,
      name: fields[1] as String,
      mimeType: fields[2] as String?,
      size: fields[3] as int,
      accessedAt: fields[4] as DateTime,
      isRemote: fields[5] as bool,
      thumbnailPath: fields[6] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, RecentFile obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.path)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.mimeType)
      ..writeByte(3)
      ..write(obj.size)
      ..writeByte(4)
      ..write(obj.accessedAt)
      ..writeByte(5)
      ..write(obj.isRemote)
      ..writeByte(6)
      ..write(obj.thumbnailPath);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecentFileAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
