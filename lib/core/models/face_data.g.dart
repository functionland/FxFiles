// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'face_data.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DetectedFaceAdapter extends TypeAdapter<DetectedFace> {
  @override
  final int typeId = 10;

  @override
  DetectedFace read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DetectedFace(
      id: fields[0] as String,
      imagePath: fields[1] as String,
      boundingBoxLeft: fields[2] as double,
      boundingBoxTop: fields[3] as double,
      boundingBoxWidth: fields[4] as double,
      boundingBoxHeight: fields[5] as double,
      embedding: (fields[6] as List).cast<double>(),
      personId: fields[7] as String?,
      detectedAt: fields[8] as DateTime,
      confidence: fields[9] as double?,
      thumbnailPath: fields[10] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, DetectedFace obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.imagePath)
      ..writeByte(2)
      ..write(obj.boundingBoxLeft)
      ..writeByte(3)
      ..write(obj.boundingBoxTop)
      ..writeByte(4)
      ..write(obj.boundingBoxWidth)
      ..writeByte(5)
      ..write(obj.boundingBoxHeight)
      ..writeByte(6)
      ..write(obj.embedding)
      ..writeByte(7)
      ..write(obj.personId)
      ..writeByte(8)
      ..write(obj.detectedAt)
      ..writeByte(9)
      ..write(obj.confidence)
      ..writeByte(10)
      ..write(obj.thumbnailPath);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DetectedFaceAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class PersonAdapter extends TypeAdapter<Person> {
  @override
  final int typeId = 11;

  @override
  Person read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Person(
      id: fields[0] as String,
      name: fields[1] as String,
      averageEmbedding: (fields[2] as List).cast<double>(),
      createdAt: fields[3] as DateTime,
      updatedAt: fields[4] as DateTime,
      faceCount: fields[5] as int,
      thumbnailPath: fields[6] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, Person obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.averageEmbedding)
      ..writeByte(3)
      ..write(obj.createdAt)
      ..writeByte(4)
      ..write(obj.updatedAt)
      ..writeByte(5)
      ..write(obj.faceCount)
      ..writeByte(6)
      ..write(obj.thumbnailPath);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PersonAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class FaceProcessingStateAdapter extends TypeAdapter<FaceProcessingState> {
  @override
  final int typeId = 12;

  @override
  FaceProcessingState read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return FaceProcessingState(
      imagePath: fields[0] as String,
      status: fields[1] as FaceProcessingStatus,
      processedAt: fields[2] as DateTime?,
      faceCount: fields[3] as int,
      errorMessage: fields[4] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, FaceProcessingState obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.imagePath)
      ..writeByte(1)
      ..write(obj.status)
      ..writeByte(2)
      ..write(obj.processedAt)
      ..writeByte(3)
      ..write(obj.faceCount)
      ..writeByte(4)
      ..write(obj.errorMessage);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FaceProcessingStateAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class FaceProcessingStatusAdapter extends TypeAdapter<FaceProcessingStatus> {
  @override
  final int typeId = 13;

  @override
  FaceProcessingStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return FaceProcessingStatus.pending;
      case 1:
        return FaceProcessingStatus.processing;
      case 2:
        return FaceProcessingStatus.completed;
      case 3:
        return FaceProcessingStatus.failed;
      case 4:
        return FaceProcessingStatus.noFaces;
      default:
        return FaceProcessingStatus.pending;
    }
  }

  @override
  void write(BinaryWriter writer, FaceProcessingStatus obj) {
    switch (obj) {
      case FaceProcessingStatus.pending:
        writer.writeByte(0);
        break;
      case FaceProcessingStatus.processing:
        writer.writeByte(1);
        break;
      case FaceProcessingStatus.completed:
        writer.writeByte(2);
        break;
      case FaceProcessingStatus.failed:
        writer.writeByte(3);
        break;
      case FaceProcessingStatus.noFaces:
        writer.writeByte(4);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FaceProcessingStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
