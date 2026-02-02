// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'file_tag.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class FileTagAdapter extends TypeAdapter<FileTag> {
  @override
  final int typeId = 20;

  @override
  FileTag read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return FileTag(
      id: fields[0] as String,
      name: fields[1] as String,
      colorValue: fields[2] as int,
      createdAt: fields[3] as DateTime,
      updatedAt: fields[4] as DateTime,
      fileCount: fields[5] as int,
    );
  }

  @override
  void write(BinaryWriter writer, FileTag obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.colorValue)
      ..writeByte(3)
      ..write(obj.createdAt)
      ..writeByte(4)
      ..write(obj.updatedAt)
      ..writeByte(5)
      ..write(obj.fileCount);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FileTagAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class TaggedFileAdapter extends TypeAdapter<TaggedFile> {
  @override
  final int typeId = 21;

  @override
  TaggedFile read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return TaggedFile(
      id: fields[0] as String,
      tagId: fields[1] as String,
      localPath: fields[2] as String?,
      remoteKey: fields[3] as String?,
      iosAssetId: fields[4] as String?,
      fileName: fields[5] as String,
      taggedAt: fields[6] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, TaggedFile obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.tagId)
      ..writeByte(2)
      ..write(obj.localPath)
      ..writeByte(3)
      ..write(obj.remoteKey)
      ..writeByte(4)
      ..write(obj.iosAssetId)
      ..writeByte(5)
      ..write(obj.fileName)
      ..writeByte(6)
      ..write(obj.taggedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TaggedFileAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
