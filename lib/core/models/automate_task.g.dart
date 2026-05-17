// GENERATED CODE - DO NOT MODIFY BY HAND (hand-written to match
// hive_generator output; same pattern as ai_task.g.dart and
// website_generation.g.dart). TypeId 50 chosen with room for 51-59 if
// Automate grows new types.

part of 'automate_task.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AutomateTaskAdapter extends TypeAdapter<AutomateTask> {
  @override
  final int typeId = 50;

  @override
  AutomateTask read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AutomateTask(
      id: fields[0] as String,
      tagId: fields[1] as String,
      tagName: fields[2] as String,
      targetApp: (fields[3] as TargetApp?) ?? TargetApp.whatsapp,
      toFieldTemplate: (fields[4] as String?) ?? '',
      messageTemplate: (fields[5] as String?) ?? '',
      subjectTemplate: fields[6] as String?,
      createdAt: fields[7] as DateTime,
      updatedAt: fields[8] as DateTime,
      rows: (fields[9] as List?)?.cast<SendPlanRow>() ?? const <SendPlanRow>[],
      attachmentLocalPath: fields[10] as String?,
      attachmentFileName: fields[11] as String?,
      attachmentCid: fields[12] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, AutomateTask obj) {
    writer
      ..writeByte(13)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.tagId)
      ..writeByte(2)
      ..write(obj.tagName)
      ..writeByte(3)
      ..write(obj.targetApp)
      ..writeByte(4)
      ..write(obj.toFieldTemplate)
      ..writeByte(5)
      ..write(obj.messageTemplate)
      ..writeByte(6)
      ..write(obj.subjectTemplate)
      ..writeByte(7)
      ..write(obj.createdAt)
      ..writeByte(8)
      ..write(obj.updatedAt)
      ..writeByte(9)
      ..write(obj.rows)
      ..writeByte(10)
      ..write(obj.attachmentLocalPath)
      ..writeByte(11)
      ..write(obj.attachmentFileName)
      ..writeByte(12)
      ..write(obj.attachmentCid);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutomateTaskAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
