// GENERATED CODE - DO NOT MODIFY BY HAND (hand-written to match
// hive_generator output; see website_generation.g.dart for the same
// pattern). TypeIds 40-44 chosen to leave a gap above NFT (30-36).

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

class TargetAppAdapter extends TypeAdapter<TargetApp> {
  @override
  final int typeId = 41;

  @override
  TargetApp read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return TargetApp.whatsapp;
      case 1:
        return TargetApp.telegram;
      case 2:
        return TargetApp.sms;
      case 3:
        return TargetApp.email;
      default:
        return TargetApp.whatsapp;
    }
  }

  @override
  void write(BinaryWriter writer, TargetApp obj) {
    switch (obj) {
      case TargetApp.whatsapp:
        writer.writeByte(0);
        break;
      case TargetApp.telegram:
        writer.writeByte(1);
        break;
      case TargetApp.sms:
        writer.writeByte(2);
        break;
      case TargetApp.email:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TargetAppAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class SendStatusAdapter extends TypeAdapter<SendStatus> {
  @override
  final int typeId = 42;

  @override
  SendStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return SendStatus.pending;
      case 1:
        return SendStatus.opened;
      case 2:
        return SendStatus.sent;
      case 3:
        return SendStatus.skipped;
      case 4:
        return SendStatus.failed;
      default:
        return SendStatus.pending;
    }
  }

  @override
  void write(BinaryWriter writer, SendStatus obj) {
    switch (obj) {
      case SendStatus.pending:
        writer.writeByte(0);
        break;
      case SendStatus.opened:
        writer.writeByte(1);
        break;
      case SendStatus.sent:
        writer.writeByte(2);
        break;
      case SendStatus.skipped:
        writer.writeByte(3);
        break;
      case SendStatus.failed:
        writer.writeByte(4);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SendStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class SendPlanRowAdapter extends TypeAdapter<SendPlanRow> {
  @override
  final int typeId = 44;

  @override
  SendPlanRow read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SendPlanRow(
      recipient: fields[0] as String,
      displayName: fields[1] as String?,
      message: fields[2] as String,
      status: (fields[3] as SendStatus?) ?? SendStatus.pending,
      openedAt: fields[4] as DateTime?,
      failureReason: fields[5] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, SendPlanRow obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.recipient)
      ..writeByte(1)
      ..write(obj.displayName)
      ..writeByte(2)
      ..write(obj.message)
      ..writeByte(3)
      ..write(obj.status)
      ..writeByte(4)
      ..write(obj.openedAt)
      ..writeByte(5)
      ..write(obj.failureReason);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SendPlanRowAdapter &&
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
