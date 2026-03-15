import 'package:hive_flutter/hive_flutter.dart';

part 'nft_token.g.dart';

/// Status of an NFT minting operation
@HiveType(typeId: 33)
enum NftMintStatus {
  @HiveField(0)
  approving,
  @HiveField(1)
  minting,
  @HiveField(2)
  confirming,
  @HiveField(3)
  completed,
  @HiveField(4)
  error,
}

/// Status of an NFT claim
@HiveType(typeId: 34)
enum NftClaimStatus {
  @HiveField(0)
  pending,
  @HiveField(1)
  claimed,
  @HiveField(2)
  expired,
  @HiveField(3)
  burned,
}

/// Record of a single NFT mint operation
@HiveType(typeId: 31)
class NftMintRecord extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  int? tokenId;

  @HiveField(2)
  final String ipfsCid;

  @HiveField(3)
  String? gatewayUrl;

  @HiveField(4)
  final int count;

  @HiveField(5)
  final String fulaPerNft; // stored as string to avoid BigInt serialization issues

  @HiveField(6)
  final int chainId;

  @HiveField(7)
  String? txHash;

  @HiveField(8)
  final String creatorAddress;

  @HiveField(9)
  final DateTime mintedAt;

  @HiveField(10)
  NftMintStatus status;

  @HiveField(11)
  String? errorMessage;

  @HiveField(12)
  List<NftClaimRecord> claims;

  @HiveField(13)
  String? approvalTxHash;

  @HiveField(14)
  String? metadataCid;

  @HiveField(15)
  String eventName;

  @HiveField(16)
  int creatorBurned;

  @HiveField(17)
  int royaltyBps;

  NftMintRecord({
    required this.id,
    this.tokenId,
    required this.ipfsCid,
    this.gatewayUrl,
    required this.count,
    required this.fulaPerNft,
    required this.chainId,
    this.txHash,
    required this.creatorAddress,
    required this.mintedAt,
    required this.status,
    this.errorMessage,
    this.claims = const [],
    this.approvalTxHash,
    this.metadataCid,
    this.eventName = 'default',
    this.creatorBurned = 0,
    this.royaltyBps = 0,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'tokenId': tokenId,
      'ipfsCid': ipfsCid,
      'gatewayUrl': gatewayUrl,
      'count': count,
      'fulaPerNft': fulaPerNft,
      'chainId': chainId,
      'txHash': txHash,
      'creatorAddress': creatorAddress,
      'mintedAt': mintedAt.toIso8601String(),
      'status': status.index,
      'errorMessage': errorMessage,
      'claims': claims.map((c) => c.toJson()).toList(),
      'approvalTxHash': approvalTxHash,
      'metadataCid': metadataCid,
      'eventName': eventName,
      'creatorBurned': creatorBurned,
      'royaltyBps': royaltyBps,
    };
  }

  factory NftMintRecord.fromJson(Map<String, dynamic> json) {
    return NftMintRecord(
      id: json['id'] as String,
      tokenId: json['tokenId'] as int?,
      ipfsCid: json['ipfsCid'] as String,
      gatewayUrl: json['gatewayUrl'] as String?,
      count: json['count'] as int? ?? 1,
      fulaPerNft: json['fulaPerNft'] as String? ?? '0',
      chainId: json['chainId'] as int? ?? 8453,
      txHash: json['txHash'] as String?,
      creatorAddress: json['creatorAddress'] as String? ?? '',
      mintedAt: DateTime.parse(json['mintedAt'] as String),
      status: NftMintStatus.values[json['status'] as int? ?? 3],
      errorMessage: json['errorMessage'] as String?,
      claims: (json['claims'] as List<dynamic>?)
              ?.map((c) => NftClaimRecord.fromJson(c as Map<String, dynamic>))
              .toList() ??
          [],
      approvalTxHash: json['approvalTxHash'] as String?,
      metadataCid: json['metadataCid'] as String?,
      eventName: json['eventName'] as String? ?? 'default',
      creatorBurned: json['creatorBurned'] as int? ?? 0,
      royaltyBps: json['royaltyBps'] as int? ?? 0,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NftMintRecord && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Record of a claim offer and its status
@HiveType(typeId: 32)
class NftClaimRecord extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final int tokenId;

  @HiveField(2)
  String? linkHash;

  @HiveField(3)
  String? claimerAddress;

  @HiveField(4)
  final int chainId;

  @HiveField(5)
  final DateTime createdAt;

  @HiveField(6)
  final DateTime expiresAt;

  @HiveField(7)
  NftClaimStatus status;

  @HiveField(8)
  String? claimTxHash;

  @HiveField(9)
  String? burnTxHash;

  NftClaimRecord({
    required this.id,
    required this.tokenId,
    this.linkHash,
    this.claimerAddress,
    required this.chainId,
    required this.createdAt,
    required this.expiresAt,
    required this.status,
    this.claimTxHash,
    this.burnTxHash,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'tokenId': tokenId,
      'linkHash': linkHash,
      'claimerAddress': claimerAddress,
      'chainId': chainId,
      'createdAt': createdAt.toIso8601String(),
      'expiresAt': expiresAt.toIso8601String(),
      'status': status.index,
      'claimTxHash': claimTxHash,
      'burnTxHash': burnTxHash,
    };
  }

  factory NftClaimRecord.fromJson(Map<String, dynamic> json) {
    return NftClaimRecord(
      id: json['id'] as String,
      tokenId: json['tokenId'] as int,
      linkHash: json['linkHash'] as String?,
      claimerAddress: json['claimerAddress'] as String?,
      chainId: json['chainId'] as int? ?? 8453,
      createdAt: DateTime.parse(json['createdAt'] as String),
      expiresAt: DateTime.parse(json['expiresAt'] as String),
      status: NftClaimStatus.values[json['status'] as int? ?? 0],
      claimTxHash: json['claimTxHash'] as String?,
      burnTxHash: json['burnTxHash'] as String?,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NftClaimRecord && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Status of a received (claimed) NFT
@HiveType(typeId: 36)
enum ReceivedNftStatus {
  @HiveField(0)
  held,
  @HiveField(1)
  burned,
  @HiveField(2)
  transferred,
}

/// A received NFT — one claimed or transferred to the user's wallet
@HiveType(typeId: 35)
class ReceivedNft extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final int tokenId;

  @HiveField(2)
  final int chainId;

  @HiveField(3)
  final String contractAddress;

  @HiveField(4)
  final String eventName;

  @HiveField(5)
  final String fulaPerNft; // stored as string

  @HiveField(6)
  final String creator;

  @HiveField(7)
  final String claimTxHash;

  @HiveField(8)
  final DateTime claimedAt;

  @HiveField(9)
  String? gatewayUrl;

  @HiveField(10)
  ReceivedNftStatus status;

  @HiveField(11)
  String? burnTxHash;

  @HiveField(12)
  String? transferTxHash;

  /// The claim link hash — needed for gasless burn/transfer via meta-tx relay.
  @HiveField(13)
  String? claimLinkHash;

  ReceivedNft({
    required this.id,
    required this.tokenId,
    required this.chainId,
    required this.contractAddress,
    required this.eventName,
    required this.fulaPerNft,
    required this.creator,
    required this.claimTxHash,
    required this.claimedAt,
    this.gatewayUrl,
    this.status = ReceivedNftStatus.held,
    this.burnTxHash,
    this.transferTxHash,
    this.claimLinkHash,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'tokenId': tokenId,
      'chainId': chainId,
      'contractAddress': contractAddress,
      'eventName': eventName,
      'fulaPerNft': fulaPerNft,
      'creator': creator,
      'claimTxHash': claimTxHash,
      'claimedAt': claimedAt.toIso8601String(),
      'gatewayUrl': gatewayUrl,
      'status': status.index,
      'burnTxHash': burnTxHash,
      'transferTxHash': transferTxHash,
      'claimLinkHash': claimLinkHash,
    };
  }

  factory ReceivedNft.fromJson(Map<String, dynamic> json) {
    return ReceivedNft(
      id: json['id'] as String,
      tokenId: json['tokenId'] as int,
      chainId: json['chainId'] as int,
      contractAddress: json['contractAddress'] as String,
      eventName: json['eventName'] as String? ?? '',
      fulaPerNft: json['fulaPerNft'] as String? ?? '0',
      creator: json['creator'] as String? ?? '',
      claimTxHash: json['claimTxHash'] as String,
      claimedAt: DateTime.parse(json['claimedAt'] as String),
      gatewayUrl: json['gatewayUrl'] as String?,
      status: ReceivedNftStatus.values[json['status'] as int? ?? 0],
      burnTxHash: json['burnTxHash'] as String?,
      transferTxHash: json['transferTxHash'] as String?,
      claimLinkHash: json['claimLinkHash'] as String?,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ReceivedNft && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// An NFT collection groups minted NFTs under a tag
@HiveType(typeId: 30)
class NftCollection extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String tagId;

  @HiveField(2)
  final String name;

  @HiveField(3)
  final DateTime createdAt;

  @HiveField(4)
  List<NftMintRecord> mints;

  @HiveField(5)
  final String? creatorWalletAddress;

  NftCollection({
    required this.id,
    required this.tagId,
    required this.name,
    required this.createdAt,
    this.mints = const [],
    this.creatorWalletAddress,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'tagId': tagId,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'mints': mints.map((m) => m.toJson()).toList(),
      'creatorWalletAddress': creatorWalletAddress,
    };
  }

  factory NftCollection.fromJson(Map<String, dynamic> json) {
    return NftCollection(
      id: json['id'] as String,
      tagId: json['tagId'] as String,
      name: json['name'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      mints: (json['mints'] as List<dynamic>?)
              ?.map((m) => NftMintRecord.fromJson(m as Map<String, dynamic>))
              .toList() ??
          [],
      creatorWalletAddress: json['creatorWalletAddress'] as String?,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NftCollection && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
