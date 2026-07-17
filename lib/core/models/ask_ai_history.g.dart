// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ask_ai_history.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AskAiHistoryAdapter extends TypeAdapter<AskAiHistory> {
  @override
  final int typeId = 28;

  @override
  AskAiHistory read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AskAiHistory(
      id: fields[0] as String,
      tagId: fields[1] as String,
      tagName: fields[2] as String,
      filenames: (fields[3] as List).cast<String>(),
      prompt: fields[4] as String,
      response: fields[5] as String,
      createdAt: fields[6] as DateTime,
      deleted: fields[7] as bool? ?? false,
    );
  }

  @override
  void write(BinaryWriter writer, AskAiHistory obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.tagId)
      ..writeByte(2)
      ..write(obj.tagName)
      ..writeByte(3)
      ..write(obj.filenames)
      ..writeByte(4)
      ..write(obj.prompt)
      ..writeByte(5)
      ..write(obj.response)
      ..writeByte(6)
      ..write(obj.createdAt)
      ..writeByte(7)
      ..write(obj.deleted);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AskAiHistoryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
