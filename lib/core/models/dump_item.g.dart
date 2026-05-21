// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'dump_item.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DumpCategoryAdapter extends TypeAdapter<DumpCategory> {
  @override
  final int typeId = 60;

  @override
  DumpCategory read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return DumpCategory.link;
      case 1:
        return DumpCategory.note;
      case 2:
        return DumpCategory.screenshot;
      case 3:
        return DumpCategory.image;
      case 4:
        return DumpCategory.video;
      case 5:
        return DumpCategory.audio;
      case 6:
        return DumpCategory.document;
      case 7:
        return DumpCategory.file;
      case 8:
        return DumpCategory.other;
      default:
        return DumpCategory.other;
    }
  }

  @override
  void write(BinaryWriter writer, DumpCategory obj) {
    switch (obj) {
      case DumpCategory.link:
        writer.writeByte(0);
        break;
      case DumpCategory.note:
        writer.writeByte(1);
        break;
      case DumpCategory.screenshot:
        writer.writeByte(2);
        break;
      case DumpCategory.image:
        writer.writeByte(3);
        break;
      case DumpCategory.video:
        writer.writeByte(4);
        break;
      case DumpCategory.audio:
        writer.writeByte(5);
        break;
      case DumpCategory.document:
        writer.writeByte(6);
        break;
      case DumpCategory.file:
        writer.writeByte(7);
        break;
      case DumpCategory.other:
        writer.writeByte(8);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DumpCategoryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class DumpUploadStatusAdapter extends TypeAdapter<DumpUploadStatus> {
  @override
  final int typeId = 61;

  @override
  DumpUploadStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return DumpUploadStatus.pendingAuth;
      case 1:
        return DumpUploadStatus.queued;
      case 2:
        return DumpUploadStatus.uploading;
      case 3:
        return DumpUploadStatus.uploaded;
      case 4:
        return DumpUploadStatus.failed;
      default:
        return DumpUploadStatus.queued;
    }
  }

  @override
  void write(BinaryWriter writer, DumpUploadStatus obj) {
    switch (obj) {
      case DumpUploadStatus.pendingAuth:
        writer.writeByte(0);
        break;
      case DumpUploadStatus.queued:
        writer.writeByte(1);
        break;
      case DumpUploadStatus.uploading:
        writer.writeByte(2);
        break;
      case DumpUploadStatus.uploaded:
        writer.writeByte(3);
        break;
      case DumpUploadStatus.failed:
        writer.writeByte(4);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DumpUploadStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class DumpEnrichmentStatusAdapter extends TypeAdapter<DumpEnrichmentStatus> {
  @override
  final int typeId = 63;

  @override
  DumpEnrichmentStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return DumpEnrichmentStatus.pending;
      case 1:
        return DumpEnrichmentStatus.done;
      case 2:
        return DumpEnrichmentStatus.failed;
      default:
        return DumpEnrichmentStatus.pending;
    }
  }

  @override
  void write(BinaryWriter writer, DumpEnrichmentStatus obj) {
    switch (obj) {
      case DumpEnrichmentStatus.pending:
        writer.writeByte(0);
        break;
      case DumpEnrichmentStatus.done:
        writer.writeByte(1);
        break;
      case DumpEnrichmentStatus.failed:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DumpEnrichmentStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class DumpItemAdapter extends TypeAdapter<DumpItem> {
  @override
  final int typeId = 62;

  @override
  DumpItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DumpItem(
      id: fields[0] as String,
      receivedAt: fields[1] as DateTime,
      originalName: fields[2] as String,
      mimeType: fields[3] as String?,
      sizeBytes: fields[4] as int,
      localCachePath: fields[5] as String,
      remoteKey: fields[6] as String?,
      category: fields[7] as DumpCategory,
      uploadStatus: fields[8] as DumpUploadStatus? ?? DumpUploadStatus.queued,
      sourceAppPackage: fields[9] as String?,
      textPayload: fields[10] as String?,
      mlLabels: (fields[11] as List?)?.cast<String>() ?? const <String>[],
      contentSha: fields[12] as String,
      errorMessage: fields[13] as String?,
      autoTitle: fields[14] as String?,
      autoDescription: fields[15] as String?,
      thumbnailPath: fields[16] as String?,
      enrichmentStatus: fields[17] as DumpEnrichmentStatus? ??
          DumpEnrichmentStatus.pending,
    );
  }

  @override
  void write(BinaryWriter writer, DumpItem obj) {
    writer
      ..writeByte(18)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.receivedAt)
      ..writeByte(2)
      ..write(obj.originalName)
      ..writeByte(3)
      ..write(obj.mimeType)
      ..writeByte(4)
      ..write(obj.sizeBytes)
      ..writeByte(5)
      ..write(obj.localCachePath)
      ..writeByte(6)
      ..write(obj.remoteKey)
      ..writeByte(7)
      ..write(obj.category)
      ..writeByte(8)
      ..write(obj.uploadStatus)
      ..writeByte(9)
      ..write(obj.sourceAppPackage)
      ..writeByte(10)
      ..write(obj.textPayload)
      ..writeByte(11)
      ..write(obj.mlLabels)
      ..writeByte(12)
      ..write(obj.contentSha)
      ..writeByte(13)
      ..write(obj.errorMessage)
      ..writeByte(14)
      ..write(obj.autoTitle)
      ..writeByte(15)
      ..write(obj.autoDescription)
      ..writeByte(16)
      ..write(obj.thumbnailPath)
      ..writeByte(17)
      ..write(obj.enrichmentStatus);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DumpItemAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
