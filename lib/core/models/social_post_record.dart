import 'package:fula_files/core/services/ipfs_gateway_helper.dart';

/// Job status of a social-post generation, mirroring the backend enum.
/// Unknown wire values map to [error] — safe for resume logic (no loop
/// ever restarts against a status it doesn't understand).
enum SocialPostStatus {
  pending,
  generating,
  publishing,
  completed,
  error;

  static SocialPostStatus fromWire(String? value) => switch (value) {
        'pending' => SocialPostStatus.pending,
        'generating' => SocialPostStatus.generating,
        'publishing' => SocialPostStatus.publishing,
        'completed' => SocialPostStatus.completed,
        _ => SocialPostStatus.error,
      };

  String get wire => name;

  bool get isRunning =>
      this == SocialPostStatus.pending ||
      this == SocialPostStatus.generating ||
      this == SocialPostStatus.publishing;
}

/// The two captions a run produces: long (Instagram/Facebook) and short
/// (Twitter/X, ≤280 chars including the website URL).
class SocialCaptions {
  final String long;
  final String short;
  const SocialCaptions({required this.long, required this.short});

  static SocialCaptions? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final long = json['long'];
    final short = json['short'];
    if (long is! String || short is! String) return null;
    return SocialCaptions(long: long, short: short);
  }

  Map<String, dynamic> toJson() => {'long': long, 'short': short};
}

/// One generated social post, keyed by the website generation it belongs
/// to (a re-run overwrites the entry — one post per generation by design).
/// Plain Dart (no Hive): persisted only in the encrypted cloud sidecar
/// manifest `.fula/website_social/{userId16}.json`.
class SocialPostRecord {
  final String generationId;
  final String tagId;
  final String? jobId;
  final SocialPostStatus status;
  final String? statusMessage;
  final String? errorMessage;
  final String? imageCid;
  final String? imageUrl;
  final SocialCaptions? captions;
  final String? websiteUrl;
  final DateTime createdAt;
  final DateTime updatedAt;

  const SocialPostRecord({
    required this.generationId,
    required this.tagId,
    this.jobId,
    required this.status,
    this.statusMessage,
    this.errorMessage,
    this.imageCid,
    this.imageUrl,
    this.captions,
    this.websiteUrl,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Display URL for the generated image: the server-reported URL when
  /// present, else rebuilt from the CID via the user's gateway template.
  String? get resolvedImageUrl {
    if (imageUrl != null && imageUrl!.isNotEmpty) return imageUrl;
    final cid = imageCid;
    if (cid == null || cid.isEmpty) return null;
    return IpfsGatewayHelper.buildUrlForCid(cid);
  }

  SocialPostRecord copyWith({
    String? jobId,
    SocialPostStatus? status,
    String? statusMessage,
    String? errorMessage,
    String? imageCid,
    String? imageUrl,
    SocialCaptions? captions,
    String? websiteUrl,
    DateTime? updatedAt,
  }) {
    return SocialPostRecord(
      generationId: generationId,
      tagId: tagId,
      jobId: jobId ?? this.jobId,
      status: status ?? this.status,
      statusMessage: statusMessage ?? this.statusMessage,
      errorMessage: errorMessage ?? this.errorMessage,
      imageCid: imageCid ?? this.imageCid,
      imageUrl: imageUrl ?? this.imageUrl,
      captions: captions ?? this.captions,
      websiteUrl: websiteUrl ?? this.websiteUrl,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  /// Null on malformed input (missing key fields) — callers skip the entry
  /// rather than dropping the whole sidecar.
  static SocialPostRecord? fromJson(Map<String, dynamic> json) {
    final generationId = json['generationId'];
    if (generationId is! String || generationId.isEmpty) return null;
    DateTime parseDate(dynamic v) =>
        v is String ? (DateTime.tryParse(v) ?? DateTime.now()) : DateTime.now();
    return SocialPostRecord(
      generationId: generationId,
      tagId: json['tagId'] as String? ?? '',
      jobId: json['jobId'] as String?,
      status: SocialPostStatus.fromWire(json['status'] as String?),
      statusMessage: json['statusMessage'] as String?,
      errorMessage: json['errorMessage'] as String?,
      imageCid: json['imageCid'] as String?,
      imageUrl: json['imageUrl'] as String?,
      captions: SocialCaptions.fromJson(
          (json['captions'] as Map?)?.cast<String, dynamic>()),
      websiteUrl: json['websiteUrl'] as String?,
      createdAt: parseDate(json['createdAt']),
      updatedAt: parseDate(json['updatedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'generationId': generationId,
        'tagId': tagId,
        'jobId': jobId,
        'status': status.wire,
        'statusMessage': statusMessage,
        'errorMessage': errorMessage,
        'imageCid': imageCid,
        'imageUrl': imageUrl,
        'captions': captions?.toJson(),
        'websiteUrl': websiteUrl,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };
}
