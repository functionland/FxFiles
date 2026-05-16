// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'website_generation.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class WebsiteGenStatusAdapter extends TypeAdapter<WebsiteGenStatus> {
  @override
  final int typeId = 26;

  @override
  WebsiteGenStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return WebsiteGenStatus.uploading;
      case 1:
        return WebsiteGenStatus.parsing;
      case 2:
        return WebsiteGenStatus.generating;
      case 3:
        return WebsiteGenStatus.completed;
      case 4:
        return WebsiteGenStatus.error;
      default:
        return WebsiteGenStatus.error;
    }
  }

  @override
  void write(BinaryWriter writer, WebsiteGenStatus obj) {
    switch (obj) {
      case WebsiteGenStatus.uploading:
        writer.writeByte(0);
        break;
      case WebsiteGenStatus.parsing:
        writer.writeByte(1);
        break;
      case WebsiteGenStatus.generating:
        writer.writeByte(2);
        break;
      case WebsiteGenStatus.completed:
        writer.writeByte(3);
        break;
      case WebsiteGenStatus.error:
        writer.writeByte(4);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WebsiteGenStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class WebsiteAssetAdapter extends TypeAdapter<WebsiteAsset> {
  @override
  final int typeId = 27;

  @override
  WebsiteAsset read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return WebsiteAsset(
      localPath: fields[0] as String,
      fileName: fields[1] as String,
      type: fields[2] as String,
      cid: fields[3] as String?,
      gatewayUrl: fields[4] as String?,
      parsedContent: fields[5] as String?,
      uploaded: fields[6] as bool,
      comment: fields[7] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, WebsiteAsset obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.localPath)
      ..writeByte(1)
      ..write(obj.fileName)
      ..writeByte(2)
      ..write(obj.type)
      ..writeByte(3)
      ..write(obj.cid)
      ..writeByte(4)
      ..write(obj.gatewayUrl)
      ..writeByte(5)
      ..write(obj.parsedContent)
      ..writeByte(6)
      ..write(obj.uploaded)
      ..writeByte(7)
      ..write(obj.comment);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WebsiteAssetAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class WebsiteGenerationAdapter extends TypeAdapter<WebsiteGeneration> {
  @override
  final int typeId = 25;

  @override
  WebsiteGeneration read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return WebsiteGeneration(
      id: fields[0] as String,
      tagId: fields[1] as String,
      tagName: fields[2] as String,
      prompt: fields[3] as String,
      status: fields[4] as WebsiteGenStatus,
      statusMessage: fields[5] as String?,
      resultCid: fields[6] as String?,
      errorMessage: fields[7] as String?,
      resultGatewayUrl: fields[13] as String?,
      createdAt: fields[8] as DateTime,
      updatedAt: fields[9] as DateTime,
      totalAssets: fields[10] as int,
      uploadedAssets: fields[11] as int,
      assets: (fields[12] as List).cast<WebsiteAsset>(),
      trackingEnabled: fields[14] as bool? ?? false,
      // Field 15 (legacy `trackingToken` from the short-lived token-auth
      // design) is silently discarded here. The map-based fields dict makes
      // it safe to read records that still carry the byte; future writes
      // drop it.
    );
  }

  @override
  void write(BinaryWriter writer, WebsiteGeneration obj) {
    writer
      ..writeByte(15)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.tagId)
      ..writeByte(2)
      ..write(obj.tagName)
      ..writeByte(3)
      ..write(obj.prompt)
      ..writeByte(4)
      ..write(obj.status)
      ..writeByte(5)
      ..write(obj.statusMessage)
      ..writeByte(6)
      ..write(obj.resultCid)
      ..writeByte(7)
      ..write(obj.errorMessage)
      ..writeByte(8)
      ..write(obj.createdAt)
      ..writeByte(9)
      ..write(obj.updatedAt)
      ..writeByte(10)
      ..write(obj.totalAssets)
      ..writeByte(11)
      ..write(obj.uploadedAssets)
      ..writeByte(12)
      ..write(obj.assets)
      ..writeByte(13)
      ..write(obj.resultGatewayUrl)
      ..writeByte(14)
      ..write(obj.trackingEnabled);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WebsiteGenerationAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
