import 'dart:convert';
import 'dart:typed_data';
import 'package:equatable/equatable.dart';

/// A file within a collaboration group
class CollaborationFile extends Equatable {
  /// Unique identifier for this file entry
  final String id;

  /// Original filename
  final String fileName;

  /// MIME type
  final String? contentType;

  /// Storage bucket for this file
  final String bucket;

  /// CID of encrypted file in storage
  final String storageKey;

  /// Original path (for fula-encrypted files)
  final String? pathScope;

  /// Public key of the user who added this file (base64)
  final String addedByPublicKey;

  /// When this file was added
  final DateTime addedAt;

  /// File size in bytes
  final int fileSize;

  /// Encryption type: "fula" (fula_client encrypted) or "collab" (collaboration key)
  final String encType;

  /// fula_client share token JSON (only for encType="fula")
  final String? shareTokenJson;

  const CollaborationFile({
    required this.id,
    required this.fileName,
    this.contentType,
    required this.bucket,
    required this.storageKey,
    this.pathScope,
    required this.addedByPublicKey,
    required this.addedAt,
    required this.fileSize,
    required this.encType,
    this.shareTokenJson,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'fileName': fileName,
    if (contentType != null) 'contentType': contentType,
    'bucket': bucket,
    'storageKey': storageKey,
    if (pathScope != null) 'pathScope': pathScope,
    'addedByPublicKey': addedByPublicKey,
    'addedAt': addedAt.toIso8601String(),
    'fileSize': fileSize,
    'encType': encType,
    if (shareTokenJson != null) 'shareTokenJson': shareTokenJson,
  };

  factory CollaborationFile.fromJson(Map<String, dynamic> json) =>
      CollaborationFile(
        id: json['id'] as String,
        fileName: json['fileName'] as String,
        contentType: json['contentType'] as String?,
        bucket: json['bucket'] as String,
        storageKey: json['storageKey'] as String,
        pathScope: json['pathScope'] as String?,
        addedByPublicKey: json['addedByPublicKey'] as String,
        addedAt: DateTime.parse(json['addedAt'] as String),
        fileSize: json['fileSize'] as int,
        encType: json['encType'] as String? ?? 'fula',
        shareTokenJson: json['shareTokenJson'] as String?,
      );

  @override
  List<Object?> get props => [id, fileName, bucket, storageKey, encType];
}

/// A named group of documents for bidirectional collaboration
class CollaborationGroup extends Equatable {
  /// Unique identifier
  final String id;

  /// User-given name (e.g. "Legal Docs 1", "Client 1")
  final String name;

  /// Base64-encoded public key of the group creator
  final String ownerPublicKey;

  /// Bucket where the manifest is stored
  final String manifestBucket;

  /// Path to manifest JSON in the bucket
  final String manifestKey;

  /// When the group was created
  final DateTime createdAt;

  /// When the group expires (null = no expiry)
  final DateTime? expiresAt;

  /// Whether this group has been revoked
  final bool isRevoked;

  /// Files in this group
  final List<CollaborationFile> files;

  /// Version counter for conflict resolution (incremented on each update)
  final int version;

  /// Last time the manifest was updated
  final DateTime updatedAt;

  const CollaborationGroup({
    required this.id,
    required this.name,
    required this.ownerPublicKey,
    required this.manifestBucket,
    required this.manifestKey,
    required this.createdAt,
    this.expiresAt,
    this.isRevoked = false,
    required this.files,
    required this.version,
    required this.updatedAt,
  });

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  bool get isValid => !isExpired && !isRevoked;

  int get fileCount => files.length;

  CollaborationGroup copyWith({
    String? id,
    String? name,
    String? ownerPublicKey,
    String? manifestBucket,
    String? manifestKey,
    DateTime? createdAt,
    DateTime? expiresAt,
    bool? isRevoked,
    List<CollaborationFile>? files,
    int? version,
    DateTime? updatedAt,
  }) =>
      CollaborationGroup(
        id: id ?? this.id,
        name: name ?? this.name,
        ownerPublicKey: ownerPublicKey ?? this.ownerPublicKey,
        manifestBucket: manifestBucket ?? this.manifestBucket,
        manifestKey: manifestKey ?? this.manifestKey,
        createdAt: createdAt ?? this.createdAt,
        expiresAt: expiresAt ?? this.expiresAt,
        isRevoked: isRevoked ?? this.isRevoked,
        files: files ?? this.files,
        version: version ?? this.version,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// Merge file lists from two versions (union by file ID)
  CollaborationGroup mergeWith(CollaborationGroup other) {
    final mergedFiles = <String, CollaborationFile>{};
    for (final f in files) {
      mergedFiles[f.id] = f;
    }
    for (final f in other.files) {
      mergedFiles.putIfAbsent(f.id, () => f);
    }
    final higherVersion = version >= other.version ? this : other;
    return higherVersion.copyWith(
      files: mergedFiles.values.toList()
        ..sort((a, b) => a.addedAt.compareTo(b.addedAt)),
      version: (version > other.version ? version : other.version) + 1,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'ownerPublicKey': ownerPublicKey,
    'manifestBucket': manifestBucket,
    'manifestKey': manifestKey,
    'createdAt': createdAt.toIso8601String(),
    if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
    'isRevoked': isRevoked,
    'files': files.map((f) => f.toJson()).toList(),
    'version': version,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory CollaborationGroup.fromJson(Map<String, dynamic> json) =>
      CollaborationGroup(
        id: json['id'] as String,
        name: json['name'] as String,
        ownerPublicKey: json['ownerPublicKey'] as String,
        manifestBucket: json['manifestBucket'] as String? ?? 'fula-metadata',
        manifestKey: json['manifestKey'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        expiresAt: json['expiresAt'] != null
            ? DateTime.parse(json['expiresAt'] as String)
            : null,
        isRevoked: json['isRevoked'] as bool? ?? false,
        files: (json['files'] as List<dynamic>?)
                ?.map((f) =>
                    CollaborationFile.fromJson(f as Map<String, dynamic>))
                .toList() ??
            [],
        version: json['version'] as int? ?? 1,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );

  @override
  List<Object?> get props => [id, name, ownerPublicKey, version];
}

/// A collaboration group created by this user (outgoing)
class OutgoingCollaboration {
  final CollaborationGroup group;
  final DateTime sharedAt;

  /// Disposable private key for the collaboration link
  final Uint8List? linkSecretKey;

  /// Encrypted URL fragment for link regeneration
  final String? encryptedFragment;

  /// fula_client share token for the manifest (temporal mode)
  final String? manifestShareToken;

  OutgoingCollaboration({
    required this.group,
    DateTime? sharedAt,
    this.linkSecretKey,
    this.encryptedFragment,
    this.manifestShareToken,
  }) : sharedAt = sharedAt ?? DateTime.now();

  String get id => group.id;
  String get name => group.name;
  bool get isExpired => group.isExpired;
  bool get isRevoked => group.isRevoked;
  bool get isValid => group.isValid;

  Map<String, dynamic> toJson() => {
    'group': group.toJson(),
    'sharedAt': sharedAt.toIso8601String(),
    if (linkSecretKey != null) 'linkSecretKey': base64Encode(linkSecretKey!),
    if (encryptedFragment != null) 'encryptedFragment': encryptedFragment,
    if (manifestShareToken != null) 'manifestShareToken': manifestShareToken,
  };

  factory OutgoingCollaboration.fromJson(Map<String, dynamic> json) =>
      OutgoingCollaboration(
        group: CollaborationGroup.fromJson(
            json['group'] as Map<String, dynamic>),
        sharedAt: DateTime.parse(json['sharedAt'] as String),
        linkSecretKey: json['linkSecretKey'] != null
            ? base64Decode(json['linkSecretKey'] as String)
            : null,
        encryptedFragment: json['encryptedFragment'] as String?,
        manifestShareToken: json['manifestShareToken'] as String?,
      );
}

/// A collaboration group shared with this user (accepted)
class AcceptedCollaboration {
  final CollaborationGroup group;

  /// fula_client share token for manifest access
  final String manifestShareToken;

  /// Link secret key for decrypting collab-encrypted files
  final Uint8List? linkSecretKey;

  final DateTime acceptedAt;

  AcceptedCollaboration({
    required this.group,
    required this.manifestShareToken,
    this.linkSecretKey,
    DateTime? acceptedAt,
  }) : acceptedAt = acceptedAt ?? DateTime.now();

  String get id => group.id;
  String get name => group.name;
  bool get isExpired => group.isExpired;
  bool get isRevoked => group.isRevoked;
  bool get isValid => group.isValid;

  Map<String, dynamic> toJson() => {
    'group': group.toJson(),
    'manifestShareToken': manifestShareToken,
    if (linkSecretKey != null) 'linkSecretKey': base64Encode(linkSecretKey!),
    'acceptedAt': acceptedAt.toIso8601String(),
  };

  factory AcceptedCollaboration.fromJson(Map<String, dynamic> json) =>
      AcceptedCollaboration(
        group: CollaborationGroup.fromJson(
            json['group'] as Map<String, dynamic>),
        manifestShareToken: json['manifestShareToken'] as String,
        linkSecretKey: json['linkSecretKey'] != null
            ? base64Decode(json['linkSecretKey'] as String)
            : null,
        acceptedAt: DateTime.parse(json['acceptedAt'] as String),
      );
}
