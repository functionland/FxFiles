// GENERATED CODE - DO NOT MODIFY BY HAND (hand-written to match
// hive_generator output).
//
// TypeIds 41, 42, 44 (TargetApp / SendStatus / SendPlanRow) were moved
// out of this file into messaging_target.g.dart when those types were
// extracted to be shared with the Automate feature. This file now only
// holds the AI-specific adapters (40: AiTaskType, 43: AiTask).

part of 'ai_task.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class AiTaskTypeAdapter extends TypeAdapter<AiTaskType> {
  @override
  final int typeId = 40;

  @override
  AiTaskType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return AiTaskType.crmAutomation;
      default:
        return AiTaskType.crmAutomation;
    }
  }

  @override
  void write(BinaryWriter writer, AiTaskType obj) {
    switch (obj) {
      case AiTaskType.crmAutomation:
        writer.writeByte(0);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiTaskTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class AiTaskAdapter extends TypeAdapter<AiTask> {
  @override
  final int typeId = 43;

  @override
  AiTask read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AiTask(
      id: fields[0] as String,
      tagId: fields[1] as String,
      tagName: fields[2] as String,
      taskType: (fields[3] as AiTaskType?) ?? AiTaskType.crmAutomation,
      targetApp: (fields[4] as TargetApp?) ?? TargetApp.whatsapp,
      userPrompt: (fields[5] as String?) ?? '',
      renderedTemplate: fields[6] as String?,
      recipientColumn: fields[7] as String?,
      nameColumn: fields[8] as String?,
      createdAt: fields[9] as DateTime,
      updatedAt: fields[10] as DateTime,
      rows: (fields[11] as List?)?.cast<SendPlanRow>() ?? const <SendPlanRow>[],
    );
  }

  @override
  void write(BinaryWriter writer, AiTask obj) {
    writer
      ..writeByte(12)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.tagId)
      ..writeByte(2)
      ..write(obj.tagName)
      ..writeByte(3)
      ..write(obj.taskType)
      ..writeByte(4)
      ..write(obj.targetApp)
      ..writeByte(5)
      ..write(obj.userPrompt)
      ..writeByte(6)
      ..write(obj.renderedTemplate)
      ..writeByte(7)
      ..write(obj.recipientColumn)
      ..writeByte(8)
      ..write(obj.nameColumn)
      ..writeByte(9)
      ..write(obj.createdAt)
      ..writeByte(10)
      ..write(obj.updatedAt)
      ..writeByte(11)
      ..write(obj.rows);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiTaskAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
