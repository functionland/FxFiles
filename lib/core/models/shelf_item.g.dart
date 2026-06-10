// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'shelf_item.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ShelfCategoryAdapter extends TypeAdapter<ShelfCategory> {
  @override
  final int typeId = 60;

  @override
  ShelfCategory read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return ShelfCategory.link;
      case 1:
        return ShelfCategory.note;
      case 2:
        return ShelfCategory.screenshot;
      case 3:
        return ShelfCategory.image;
      case 4:
        return ShelfCategory.video;
      case 5:
        return ShelfCategory.audio;
      case 6:
        return ShelfCategory.document;
      case 7:
        return ShelfCategory.file;
      case 8:
        return ShelfCategory.other;
      default:
        return ShelfCategory.other;
    }
  }

  @override
  void write(BinaryWriter writer, ShelfCategory obj) {
    switch (obj) {
      case ShelfCategory.link:
        writer.writeByte(0);
        break;
      case ShelfCategory.note:
        writer.writeByte(1);
        break;
      case ShelfCategory.screenshot:
        writer.writeByte(2);
        break;
      case ShelfCategory.image:
        writer.writeByte(3);
        break;
      case ShelfCategory.video:
        writer.writeByte(4);
        break;
      case ShelfCategory.audio:
        writer.writeByte(5);
        break;
      case ShelfCategory.document:
        writer.writeByte(6);
        break;
      case ShelfCategory.file:
        writer.writeByte(7);
        break;
      case ShelfCategory.other:
        writer.writeByte(8);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShelfCategoryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class ShelfUploadStatusAdapter extends TypeAdapter<ShelfUploadStatus> {
  @override
  final int typeId = 61;

  @override
  ShelfUploadStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return ShelfUploadStatus.pendingAuth;
      case 1:
        return ShelfUploadStatus.queued;
      case 2:
        return ShelfUploadStatus.uploading;
      case 3:
        return ShelfUploadStatus.uploaded;
      case 4:
        return ShelfUploadStatus.failed;
      default:
        return ShelfUploadStatus.queued;
    }
  }

  @override
  void write(BinaryWriter writer, ShelfUploadStatus obj) {
    switch (obj) {
      case ShelfUploadStatus.pendingAuth:
        writer.writeByte(0);
        break;
      case ShelfUploadStatus.queued:
        writer.writeByte(1);
        break;
      case ShelfUploadStatus.uploading:
        writer.writeByte(2);
        break;
      case ShelfUploadStatus.uploaded:
        writer.writeByte(3);
        break;
      case ShelfUploadStatus.failed:
        writer.writeByte(4);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShelfUploadStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class ShelfEnrichmentStatusAdapter extends TypeAdapter<ShelfEnrichmentStatus> {
  @override
  final int typeId = 63;

  @override
  ShelfEnrichmentStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return ShelfEnrichmentStatus.pending;
      case 1:
        return ShelfEnrichmentStatus.done;
      case 2:
        return ShelfEnrichmentStatus.failed;
      default:
        return ShelfEnrichmentStatus.pending;
    }
  }

  @override
  void write(BinaryWriter writer, ShelfEnrichmentStatus obj) {
    switch (obj) {
      case ShelfEnrichmentStatus.pending:
        writer.writeByte(0);
        break;
      case ShelfEnrichmentStatus.done:
        writer.writeByte(1);
        break;
      case ShelfEnrichmentStatus.failed:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShelfEnrichmentStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class ShelfItemAdapter extends TypeAdapter<ShelfItem> {
  @override
  final int typeId = 62;

  @override
  ShelfItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ShelfItem(
      id: fields[0] as String,
      receivedAt: fields[1] as DateTime,
      originalName: fields[2] as String,
      mimeType: fields[3] as String?,
      sizeBytes: fields[4] as int,
      localCachePath: fields[5] as String,
      remoteKey: fields[6] as String?,
      category: fields[7] as ShelfCategory,
      uploadStatus: fields[8] as ShelfUploadStatus? ?? ShelfUploadStatus.queued,
      sourceAppPackage: fields[9] as String?,
      textPayload: fields[10] as String?,
      mlLabels: (fields[11] as List?)?.cast<String>() ?? const <String>[],
      contentSha: fields[12] as String,
      errorMessage: fields[13] as String?,
      autoTitle: fields[14] as String?,
      autoDescription: fields[15] as String?,
      thumbnailPath: fields[16] as String?,
      enrichmentStatus: fields[17] as ShelfEnrichmentStatus? ??
          ShelfEnrichmentStatus.pending,
      // Field 18 added later — legacy rows persisted before the
      // cloud-sync migration won't have it, so default to null.
      thumbnailRemoteKey: fields[18] as String?,
      // Field 19 added in P7 (v8 shelf-content migration) — rows persisted
      // before it default to null = the legacy `dump` body bucket.
      sourceBucket: fields[19] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, ShelfItem obj) {
    writer
      ..writeByte(20)
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
      ..write(obj.enrichmentStatus)
      ..writeByte(18)
      ..write(obj.thumbnailRemoteKey)
      ..writeByte(19)
      ..write(obj.sourceBucket);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShelfItemAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
