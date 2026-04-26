import 'package:hive_flutter/hive_flutter.dart';

part 'website_generation.g.dart';

/// Build the public dweb.link subdomain URL for a CID, used for the
/// *displayed* website URL (copy / open buttons). Intentionally not
/// user-configurable: a generated site's shared link must resolve from any
/// device regardless of the local IPFS gateway setting, so we pin it to a
/// well-known public gateway.
String _publicGatewayUrlForCid(String cid) => 'https://$cid.ipfs.dweb.link/';

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

  factory WebsiteAsset.fromJson(Map<String, dynamic> json) {
    return WebsiteAsset(
      localPath: json['localPath'] as String? ?? '',
      fileName: json['fileName'] as String? ?? '',
      type: json['type'] as String? ?? 'image',
      cid: json['cid'] as String?,
      gatewayUrl: json['gatewayUrl'] as String?,
      parsedContent: json['parsedContent'] as String?,
      uploaded: json['uploaded'] as bool? ?? false,
    );
  }

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

  factory WebsiteGeneration.fromJson(Map<String, dynamic> json) {
    return WebsiteGeneration(
      id: json['id'] as String,
      tagId: json['tagId'] as String,
      tagName: json['tagName'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      status: WebsiteGenStatus.values[json['status'] as int? ?? 3],
      statusMessage: json['statusMessage'] as String?,
      resultCid: json['resultCid'] as String?,
      resultGatewayUrl: json['resultGatewayUrl'] as String?,
      errorMessage: json['errorMessage'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      totalAssets: json['totalAssets'] as int? ?? 0,
      uploadedAssets: json['uploadedAssets'] as int? ?? 0,
      assets: (json['assets'] as List<dynamic>?)
              ?.map((a) => WebsiteAsset.fromJson(a as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  /// Public URL for the completed website, always under the dweb.link
  /// subdomain gateway (see `_publicGatewayUrlForCid`). Prefers `resultCid`;
  /// falls back to extracting the CID from a legacy `resultGatewayUrl`.
  String? get gatewayUrl {
    final cid = (resultCid != null && resultCid!.isNotEmpty)
        ? resultCid
        : _extractCidFromUrl(resultGatewayUrl);
    if (cid == null || cid.isEmpty) return null;
    return _publicGatewayUrlForCid(cid);
  }

  /// Extract the trailing CID from a gateway-style URL such as
  /// `http://host/gateway/<cid>` or `https://host/ipfs/<cid>`. Returns null
  /// when the input is null/empty or can't be parsed.
  static String? _extractCidFromUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final trimmed = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final lastSlash = trimmed.lastIndexOf('/');
    if (lastSlash < 0 || lastSlash == trimmed.length - 1) return null;
    final tail = trimmed.substring(lastSlash + 1);
    return tail.isEmpty ? null : tail;
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
