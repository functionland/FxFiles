// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'nft_token.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class NftCollectionAdapter extends TypeAdapter<NftCollection> {
  @override
  final int typeId = 30;

  @override
  NftCollection read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return NftCollection(
      id: fields[0] as String,
      tagId: fields[1] as String,
      name: fields[2] as String,
      createdAt: fields[3] as DateTime,
      mints: (fields[4] as List?)?.cast<NftMintRecord>().toList() ?? [],
      creatorWalletAddress: fields[5] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, NftCollection obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.tagId)
      ..writeByte(2)
      ..write(obj.name)
      ..writeByte(3)
      ..write(obj.createdAt)
      ..writeByte(4)
      ..write(obj.mints)
      ..writeByte(5)
      ..write(obj.creatorWalletAddress);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NftCollectionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class NftMintRecordAdapter extends TypeAdapter<NftMintRecord> {
  @override
  final int typeId = 31;

  @override
  NftMintRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return NftMintRecord(
      id: fields[0] as String,
      tokenId: fields[1] as int?,
      ipfsCid: fields[2] as String,
      gatewayUrl: fields[3] as String?,
      count: fields[4] as int,
      fulaPerNft: fields[5] as String,
      chainId: fields[6] as int,
      txHash: fields[7] as String?,
      creatorAddress: fields[8] as String,
      mintedAt: fields[9] as DateTime,
      status: fields[10] as NftMintStatus,
      errorMessage: fields[11] as String?,
      claims: (fields[12] as List?)?.cast<NftClaimRecord>().toList() ?? [],
      approvalTxHash: fields[13] as String?,
      metadataCid: fields[14] as String?,
      eventName: fields[15] as String? ?? 'default',
      creatorBurned: fields[16] as int? ?? 0,
      royaltyBps: fields[17] as int? ?? 0,
    );
  }

  @override
  void write(BinaryWriter writer, NftMintRecord obj) {
    writer
      ..writeByte(18)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.tokenId)
      ..writeByte(2)
      ..write(obj.ipfsCid)
      ..writeByte(3)
      ..write(obj.gatewayUrl)
      ..writeByte(4)
      ..write(obj.count)
      ..writeByte(5)
      ..write(obj.fulaPerNft)
      ..writeByte(6)
      ..write(obj.chainId)
      ..writeByte(7)
      ..write(obj.txHash)
      ..writeByte(8)
      ..write(obj.creatorAddress)
      ..writeByte(9)
      ..write(obj.mintedAt)
      ..writeByte(10)
      ..write(obj.status)
      ..writeByte(11)
      ..write(obj.errorMessage)
      ..writeByte(12)
      ..write(obj.claims)
      ..writeByte(13)
      ..write(obj.approvalTxHash)
      ..writeByte(14)
      ..write(obj.metadataCid)
      ..writeByte(15)
      ..write(obj.eventName)
      ..writeByte(16)
      ..write(obj.creatorBurned)
      ..writeByte(17)
      ..write(obj.royaltyBps);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NftMintRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class NftClaimRecordAdapter extends TypeAdapter<NftClaimRecord> {
  @override
  final int typeId = 32;

  @override
  NftClaimRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return NftClaimRecord(
      id: fields[0] as String,
      tokenId: fields[1] as int,
      linkHash: fields[2] as String?,
      claimerAddress: fields[3] as String?,
      chainId: fields[4] as int,
      createdAt: fields[5] as DateTime,
      expiresAt: fields[6] as DateTime,
      status: fields[7] as NftClaimStatus,
      claimTxHash: fields[8] as String?,
      burnTxHash: fields[9] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, NftClaimRecord obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.tokenId)
      ..writeByte(2)
      ..write(obj.linkHash)
      ..writeByte(3)
      ..write(obj.claimerAddress)
      ..writeByte(4)
      ..write(obj.chainId)
      ..writeByte(5)
      ..write(obj.createdAt)
      ..writeByte(6)
      ..write(obj.expiresAt)
      ..writeByte(7)
      ..write(obj.status)
      ..writeByte(8)
      ..write(obj.claimTxHash)
      ..writeByte(9)
      ..write(obj.burnTxHash);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NftClaimRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class NftMintStatusAdapter extends TypeAdapter<NftMintStatus> {
  @override
  final int typeId = 33;

  @override
  NftMintStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return NftMintStatus.approving;
      case 1:
        return NftMintStatus.minting;
      case 2:
        return NftMintStatus.confirming;
      case 3:
        return NftMintStatus.completed;
      case 4:
        return NftMintStatus.error;
      default:
        return NftMintStatus.error;
    }
  }

  @override
  void write(BinaryWriter writer, NftMintStatus obj) {
    switch (obj) {
      case NftMintStatus.approving:
        writer.writeByte(0);
        break;
      case NftMintStatus.minting:
        writer.writeByte(1);
        break;
      case NftMintStatus.confirming:
        writer.writeByte(2);
        break;
      case NftMintStatus.completed:
        writer.writeByte(3);
        break;
      case NftMintStatus.error:
        writer.writeByte(4);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NftMintStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class ReceivedNftAdapter extends TypeAdapter<ReceivedNft> {
  @override
  final int typeId = 35;

  @override
  ReceivedNft read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ReceivedNft(
      id: fields[0] as String,
      tokenId: fields[1] as int,
      chainId: fields[2] as int,
      contractAddress: fields[3] as String,
      eventName: fields[4] as String? ?? '',
      fulaPerNft: fields[5] as String? ?? '0',
      creator: fields[6] as String? ?? '',
      claimTxHash: fields[7] as String,
      claimedAt: fields[8] as DateTime,
      gatewayUrl: fields[9] as String?,
      status: fields[10] as ReceivedNftStatus? ?? ReceivedNftStatus.held,
      burnTxHash: fields[11] as String?,
      transferTxHash: fields[12] as String?,
      claimLinkHash: fields[13] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, ReceivedNft obj) {
    writer
      ..writeByte(14)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.tokenId)
      ..writeByte(2)
      ..write(obj.chainId)
      ..writeByte(3)
      ..write(obj.contractAddress)
      ..writeByte(4)
      ..write(obj.eventName)
      ..writeByte(5)
      ..write(obj.fulaPerNft)
      ..writeByte(6)
      ..write(obj.creator)
      ..writeByte(7)
      ..write(obj.claimTxHash)
      ..writeByte(8)
      ..write(obj.claimedAt)
      ..writeByte(9)
      ..write(obj.gatewayUrl)
      ..writeByte(10)
      ..write(obj.status)
      ..writeByte(11)
      ..write(obj.burnTxHash)
      ..writeByte(12)
      ..write(obj.transferTxHash)
      ..writeByte(13)
      ..write(obj.claimLinkHash);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReceivedNftAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class ReceivedNftStatusAdapter extends TypeAdapter<ReceivedNftStatus> {
  @override
  final int typeId = 36;

  @override
  ReceivedNftStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return ReceivedNftStatus.held;
      case 1:
        return ReceivedNftStatus.burned;
      case 2:
        return ReceivedNftStatus.transferred;
      default:
        return ReceivedNftStatus.held;
    }
  }

  @override
  void write(BinaryWriter writer, ReceivedNftStatus obj) {
    switch (obj) {
      case ReceivedNftStatus.held:
        writer.writeByte(0);
        break;
      case ReceivedNftStatus.burned:
        writer.writeByte(1);
        break;
      case ReceivedNftStatus.transferred:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReceivedNftStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class NftClaimStatusAdapter extends TypeAdapter<NftClaimStatus> {
  @override
  final int typeId = 34;

  @override
  NftClaimStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return NftClaimStatus.pending;
      case 1:
        return NftClaimStatus.claimed;
      case 2:
        return NftClaimStatus.expired;
      case 3:
        return NftClaimStatus.burned;
      default:
        return NftClaimStatus.pending;
    }
  }

  @override
  void write(BinaryWriter writer, NftClaimStatus obj) {
    switch (obj) {
      case NftClaimStatus.pending:
        writer.writeByte(0);
        break;
      case NftClaimStatus.claimed:
        writer.writeByte(1);
        break;
      case NftClaimStatus.expired:
        writer.writeByte(2);
        break;
      case NftClaimStatus.burned:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NftClaimStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
