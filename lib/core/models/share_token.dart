import 'dart:convert';
import 'dart:typed_data';
import 'package:equatable/equatable.dart';

/// Share permissions for encrypted file sharing
/// Based on Fula API sharing model
enum SharePermissions {
  /// Read-only access - can view and download files
  readOnly,
  
  /// Read-write access - can view, download, and upload files
  readWrite,
  
  /// Full access - can view, download, upload, and delete files
  full,
}

extension SharePermissionsExtension on SharePermissions {
  bool get canRead => true;
  
  bool get canWrite => this == SharePermissions.readWrite || this == SharePermissions.full;
  
  bool get canDelete => this == SharePermissions.full;
  
  String get displayName {
    switch (this) {
      case SharePermissions.readOnly:
        return 'Read Only';
      case SharePermissions.readWrite:
        return 'Read & Write';
      case SharePermissions.full:
        return 'Full Access';
    }
  }
  
  String toJson() => name;
  
  static SharePermissions fromJson(String json) {
    return SharePermissions.values.firstWhere(
      (p) => p.name == json,
      orElse: () => SharePermissions.readOnly,
    );
  }
}

/// Share token containing encrypted DEK for recipient
/// 
/// Based on Fula API sharing pattern:
/// - Path-scoped: Share only specific folders
/// - Time-limited: Access expires automatically
/// - Permission-based: Read-only, read-write, or full
/// - Revocable: Can be revoked by owner
class ShareToken extends Equatable {
  /// Unique identifier for this share
  final String id;
  
  /// Owner's public key (for verification)
  final Uint8List ownerPublicKey;
  
  /// Recipient's public key
  final Uint8List recipientPublicKey;
  
  /// Encrypted DEK (wrapped for recipient using HPKE)
  /// The DEK is re-encrypted for the recipient's public key
  final Uint8List wrappedDek;
  
  /// Ephemeral public key used in HPKE encryption
  final Uint8List ephemeralPublicKey;
  
  /// Path scope - only files under this path can be accessed
  final String pathScope;
  
  /// Bucket scope - the bucket this share applies to
  final String bucket;
  
  /// Permissions granted to recipient
  final SharePermissions permissions;
  
  /// When the share was created
  final DateTime createdAt;
  
  /// When the share expires (null = never expires)
  final DateTime? expiresAt;
  
  /// Optional label/name for this share
  final String? label;
  
  /// Whether this share has been revoked
  final bool isRevoked;
  
  const ShareToken({
    required this.id,
    required this.ownerPublicKey,
    required this.recipientPublicKey,
    required this.wrappedDek,
    required this.ephemeralPublicKey,
    required this.pathScope,
    required this.bucket,
    required this.permissions,
    required this.createdAt,
    this.expiresAt,
    this.label,
    this.isRevoked = false,
  });
  
  /// Check if this share has expired
  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }
  
  /// Check if this share is valid (not expired and not revoked)
  bool get isValid => !isExpired && !isRevoked;
  
  /// Check if a path is within this share's scope
  bool hasAccessTo(String path) {
    if (!isValid) return false;
    
    // Normalize paths
    final normalizedScope = pathScope.endsWith('/') ? pathScope : '$pathScope/';
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    
    return normalizedPath.startsWith(normalizedScope) || normalizedPath == pathScope;
  }
  
  /// Days until expiry (null if no expiry)
  int? get daysUntilExpiry {
    if (expiresAt == null) return null;
    final diff = expiresAt!.difference(DateTime.now());
    return diff.inDays;
  }
  
  /// Convert to JSON for transmission
  Map<String, dynamic> toJson() => {
    'id': id,
    'ownerPublicKey': base64Encode(ownerPublicKey),
    'recipientPublicKey': base64Encode(recipientPublicKey),
    'wrappedDek': base64Encode(wrappedDek),
    'ephemeralPublicKey': base64Encode(ephemeralPublicKey),
    'pathScope': pathScope,
    'bucket': bucket,
    'permissions': permissions.toJson(),
    'createdAt': createdAt.toIso8601String(),
    'expiresAt': expiresAt?.toIso8601String(),
    'label': label,
    'isRevoked': isRevoked,
  };
  
  /// Create from JSON
  factory ShareToken.fromJson(Map<String, dynamic> json) => ShareToken(
    id: json['id'] as String,
    ownerPublicKey: base64Decode(json['ownerPublicKey'] as String),
    recipientPublicKey: base64Decode(json['recipientPublicKey'] as String),
    wrappedDek: base64Decode(json['wrappedDek'] as String),
    ephemeralPublicKey: base64Decode(json['ephemeralPublicKey'] as String),
    pathScope: json['pathScope'] as String,
    bucket: json['bucket'] as String,
    permissions: SharePermissionsExtension.fromJson(json['permissions'] as String),
    createdAt: DateTime.parse(json['createdAt'] as String),
    expiresAt: json['expiresAt'] != null 
        ? DateTime.parse(json['expiresAt'] as String) 
        : null,
    label: json['label'] as String?,
    isRevoked: json['isRevoked'] as bool? ?? false,
  );
  
  /// Encode to base64 string for sharing via URL/QR code
  String encode() => base64Encode(utf8.encode(jsonEncode(toJson())));
  
  /// Decode from base64 string
  static ShareToken decode(String encoded) {
    final json = jsonDecode(utf8.decode(base64Decode(encoded)));
    return ShareToken.fromJson(json as Map<String, dynamic>);
  }
  
  /// Create a revoked copy of this token
  ShareToken revoke() => ShareToken(
    id: id,
    ownerPublicKey: ownerPublicKey,
    recipientPublicKey: recipientPublicKey,
    wrappedDek: wrappedDek,
    ephemeralPublicKey: ephemeralPublicKey,
    pathScope: pathScope,
    bucket: bucket,
    permissions: permissions,
    createdAt: createdAt,
    expiresAt: expiresAt,
    label: label,
    isRevoked: true,
  );
  
  @override
  List<Object?> get props => [
    id,
    ownerPublicKey,
    recipientPublicKey,
    pathScope,
    bucket,
    permissions,
    createdAt,
    expiresAt,
    isRevoked,
  ];
}

/// Represents an accepted share that the recipient can use
class AcceptedShare {
  /// The original share token
  final ShareToken token;
  
  /// The decrypted DEK (Data Encryption Key)
  final Uint8List dek;
  
  /// When this share was accepted
  final DateTime acceptedAt;
  
  AcceptedShare({
    required this.token,
    required this.dek,
    DateTime? acceptedAt,
  }) : acceptedAt = acceptedAt ?? DateTime.now();
  
  /// Check if expired
  bool get isExpired => token.isExpired;
  
  /// Check if revoked
  bool get isRevoked => token.isRevoked;
  
  /// Check if valid
  bool get isValid => token.isValid;
  
  /// Path scope
  String get pathScope => token.pathScope;
  
  /// Bucket
  String get bucket => token.bucket;
  
  /// Permissions
  SharePermissions get permissions => token.permissions;
  
  /// Can read files
  bool get canRead => permissions.canRead;
  
  /// Can write files
  bool get canWrite => permissions.canWrite;
  
  /// Can delete files
  bool get canDelete => permissions.canDelete;
  
  /// Check if a path is accessible
  bool hasAccessTo(String path) => token.hasAccessTo(path);
  
  /// Convert to JSON for storage
  Map<String, dynamic> toJson() => {
    'token': token.toJson(),
    'dek': base64Encode(dek),
    'acceptedAt': acceptedAt.toIso8601String(),
  };
  
  /// Create from JSON
  factory AcceptedShare.fromJson(Map<String, dynamic> json) => AcceptedShare(
    token: ShareToken.fromJson(json['token'] as Map<String, dynamic>),
    dek: base64Decode(json['dek'] as String),
    acceptedAt: DateTime.parse(json['acceptedAt'] as String),
  );
}

/// Represents a share that the owner has created (outgoing share)
class OutgoingShare {
  /// The share token
  final ShareToken token;
  
  /// Recipient name/identifier (for display)
  final String recipientName;
  
  /// When the share was sent
  final DateTime sharedAt;
  
  OutgoingShare({
    required this.token,
    required this.recipientName,
    DateTime? sharedAt,
  }) : sharedAt = sharedAt ?? DateTime.now();
  
  /// Share ID
  String get id => token.id;
  
  /// Path scope
  String get pathScope => token.pathScope;
  
  /// Bucket
  String get bucket => token.bucket;
  
  /// Permissions
  SharePermissions get permissions => token.permissions;
  
  /// Is expired
  bool get isExpired => token.isExpired;
  
  /// Is revoked
  bool get isRevoked => token.isRevoked;
  
  /// Is valid
  bool get isValid => token.isValid;
  
  /// Convert to JSON
  Map<String, dynamic> toJson() => {
    'token': token.toJson(),
    'recipientName': recipientName,
    'sharedAt': sharedAt.toIso8601String(),
  };
  
  /// Create from JSON
  factory OutgoingShare.fromJson(Map<String, dynamic> json) => OutgoingShare(
    token: ShareToken.fromJson(json['token'] as Map<String, dynamic>),
    recipientName: json['recipientName'] as String,
    sharedAt: DateTime.parse(json['sharedAt'] as String),
  );
}
