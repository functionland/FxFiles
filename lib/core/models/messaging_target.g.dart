// GENERATED CODE - DO NOT MODIFY BY HAND (hand-written to match
// hive_generator output; same pattern as ai_task.g.dart and
// website_generation.g.dart).
//
// TypeIds 41, 42, 44 were previously generated in ai_task.g.dart. Moved
// here when these types were lifted out of ai_task.dart so the
// Automate feature can use them too. TypeIds preserved — existing on-
// disk data stays readable.

part of 'messaging_target.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

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
