import 'package:hive_flutter/hive_flutter.dart';

part 'website_generation.g.dart';

/// Status of a website generation job
@HiveType(typeId: 26)
enum WebsiteGenStatus {
  @HiveField(0)
  uploading,
  @HiveField(1)
  parsing,
  @HiveField(2)
  generating,
  @HiveField(3)
  completed,
  @HiveField(4)
  error,
}

/// An asset (file) included in a website generation
@HiveType(typeId: 27)
class WebsiteAsset extends HiveObject {
  @HiveField(0)
  final String localPath;

  @HiveField(1)
  final String fileName;

  @HiveField(2)
  final String type; // image, video, document, audio

  @HiveField(3)
  String? cid; // IPFS CID after upload

  @HiveField(4)
  String? gatewayUrl; // full IPFS gateway URL

  @HiveField(5)
  String? parsedContent; // ML Kit extracted content

  @HiveField(6)
  bool uploaded;

  WebsiteAsset({
    required this.localPath,
    required this.fileName,
    required this.type,
    this.cid,
    this.gatewayUrl,
    this.parsedContent,
    this.uploaded = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'localPath': localPath,
      'fileName': fileName,
      'type': type,
      'cid': cid,
      'gatewayUrl': gatewayUrl,
      'parsedContent': parsedContent,
      'uploaded': uploaded,
    };
  }

  /// Convert to payload format for AI endpoint
  Map<String, dynamic> toAiPayload() {
    return {
      'fileName': fileName,
      'type': type,
      'url': gatewayUrl ?? '',
      'content': parsedContent ?? '',
    };
  }
}

/// Represents a website generation job with its state and results
@HiveType(typeId: 25)
class WebsiteGeneration extends HiveObject {
  @HiveField(0)
  final String id; // UUID

  @HiveField(1)
  final String tagId; // website tag ID

  @HiveField(2)
  final String tagName; // website display name

  @HiveField(3)
  final String prompt; // user prompt

  @HiveField(4)
  WebsiteGenStatus status;

  @HiveField(5)
  String? statusMessage; // e.g. "Uploading asset 2/5"

  @HiveField(6)
  String? resultCid; // IPFS CID of generated website

  @HiveField(7)
  String? errorMessage;

  @HiveField(13)
  String? resultGatewayUrl; // full gateway URL of generated website

  @HiveField(8)
  final DateTime createdAt;

  @HiveField(9)
  DateTime updatedAt;

  @HiveField(10)
  int totalAssets;

  @HiveField(11)
  int uploadedAssets;

  @HiveField(12)
  List<WebsiteAsset> assets;

  WebsiteGeneration({
    required this.id,
    required this.tagId,
    required this.tagName,
    required this.prompt,
    required this.status,
    this.statusMessage,
    this.resultCid,
    this.errorMessage,
    this.resultGatewayUrl,
    required this.createdAt,
    required this.updatedAt,
    this.totalAssets = 0,
    this.uploadedAssets = 0,
    this.assets = const [],
  });

  /// Gateway URL for the completed website
  String? get gatewayUrl {
    if (resultGatewayUrl != null && resultGatewayUrl!.isNotEmpty) {
      return resultGatewayUrl;
    }
    return resultCid;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'tagId': tagId,
      'tagName': tagName,
      'prompt': prompt,
      'status': status.index,
      'statusMessage': statusMessage,
      'resultCid': resultCid,
      'resultGatewayUrl': resultGatewayUrl,
      'errorMessage': errorMessage,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'totalAssets': totalAssets,
      'uploadedAssets': uploadedAssets,
      'assets': assets.map((a) => a.toJson()).toList(),
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WebsiteGeneration && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
