import 'package:hive_flutter/hive_flutter.dart';

/// Stable per-website-group pointer. One per website "group" (a `FileTag` with
/// the `websites-` prefix; multiple `WebsiteGeneration`s share one tagId),
/// keyed by [tagId].
///
/// Holds the group's permanent IPNS name and the latest CID it currently points
/// at, plus the user-facing links. Regenerating a site re-points the same IPNS
/// name at the new CID, so a link the user shared once keeps working.
///
/// The IPNS name is derived from a per-group Ed25519 keypair the app holds; the
/// **private key is intentionally NOT stored here**. It lives in secure storage
/// under `SecureStorageKeys.groupIpnsPrivKeyPrefix + tagId` (and is backed up in
/// the encrypted cloud sync). This record is safe-at-rest metadata only.
///
/// NOTE: the adapter below is **hand-written** rather than build_runner
/// generated — this repo does not depend on `build_runner`/`hive_generator`,
/// so new Hive types ship their own `TypeAdapter`. The `@HiveType`/`@HiveField`
/// annotations are kept as documentation of the typeId (28) and field layout,
/// matching the sibling models; they are inert without the generator. Field
/// indices here MUST match the adapter.
@HiveType(typeId: 28)
class WebsiteGroupPointer extends HiveObject {
  @HiveField(0)
  final String tagId;

  /// Permanent IPNS name (`k51…`, base36 CIDv1 libp2p-key). Stable forever for
  /// this group — never regenerated once minted.
  @HiveField(1)
  final String ipnsName;

  /// Last IPNS record sequence number published for this name (monotonic).
  @HiveField(2)
  int sequence;

  /// The CID the IPNS name currently resolves to (the group's latest
  /// generation). Null until the first successful publish.
  @HiveField(3)
  String? currentCid;

  /// Branded front-door URL — the primary share link, served by the stateless
  /// Cloudflare resolver Worker, e.g. `https://fxfiles.top/w/{ipnsName}`.
  @HiveField(4)
  String frontDoorUrl;

  /// Raw IPNS gateway URL, e.g. `https://{ipnsName}.ipns.dweb.link/` — the
  /// name's own address. NOTE: this only resolves on a public gateway once the
  /// record is published to the IPFS DHT; w3name alone does NOT do that, so
  /// today the working share link is [frontDoorUrl] (the Cloudflare Worker,
  /// which reads w3name directly). Kept as the forward-compatible canonical
  /// address (see cloudflare/README.md).
  @HiveField(5)
  String ipnsGatewayUrl;

  /// True once at least one IPNS record has been published for this name (i.e.
  /// the shared link actually resolves to content). Until then the UI shows a
  /// "creating link…" state.
  @HiveField(6)
  bool published;

  @HiveField(7)
  final DateTime createdAt;

  @HiveField(8)
  DateTime updatedAt;

  WebsiteGroupPointer({
    required this.tagId,
    required this.ipnsName,
    this.sequence = 0,
    this.currentCid,
    required this.frontDoorUrl,
    required this.ipnsGatewayUrl,
    this.published = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory WebsiteGroupPointer.fromJson(Map<String, dynamic> json) {
    return WebsiteGroupPointer(
      tagId: json['tagId'] as String,
      ipnsName: json['ipnsName'] as String,
      sequence: json['sequence'] as int? ?? 0,
      currentCid: json['currentCid'] as String?,
      frontDoorUrl: json['frontDoorUrl'] as String? ?? '',
      ipnsGatewayUrl: json['ipnsGatewayUrl'] as String? ?? '',
      published: json['published'] as bool? ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'tagId': tagId,
        'ipnsName': ipnsName,
        'sequence': sequence,
        'currentCid': currentCid,
        'frontDoorUrl': frontDoorUrl,
        'ipnsGatewayUrl': ipnsGatewayUrl,
        'published': published,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WebsiteGroupPointer && other.tagId == tagId);

  @override
  int get hashCode => tagId.hashCode;
}

/// Hand-written Hive adapter (see class doc). Serialises fields by the same
/// index scheme build_runner uses, so it is wire-compatible with a generated
/// adapter should the repo adopt codegen later.
class WebsiteGroupPointerAdapter extends TypeAdapter<WebsiteGroupPointer> {
  @override
  final int typeId = 28;

  @override
  WebsiteGroupPointer read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return WebsiteGroupPointer(
      tagId: fields[0] as String,
      ipnsName: fields[1] as String,
      sequence: fields[2] as int? ?? 0,
      currentCid: fields[3] as String?,
      frontDoorUrl: fields[4] as String? ?? '',
      ipnsGatewayUrl: fields[5] as String? ?? '',
      published: fields[6] as bool? ?? false,
      createdAt: fields[7] as DateTime,
      updatedAt: fields[8] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, WebsiteGroupPointer obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.tagId)
      ..writeByte(1)
      ..write(obj.ipnsName)
      ..writeByte(2)
      ..write(obj.sequence)
      ..writeByte(3)
      ..write(obj.currentCid)
      ..writeByte(4)
      ..write(obj.frontDoorUrl)
      ..writeByte(5)
      ..write(obj.ipnsGatewayUrl)
      ..writeByte(6)
      ..write(obj.published)
      ..writeByte(7)
      ..write(obj.createdAt)
      ..writeByte(8)
      ..write(obj.updatedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WebsiteGroupPointerAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
