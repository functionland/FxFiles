import 'dart:convert';
import 'dart:typed_data';
import 'package:equatable/equatable.dart';

/// Type of share - determines how the share is accessed
enum ShareType {
  /// Share with a specific recipient using their public key
  /// Only the intended recipient can decrypt
  recipient,

  /// Public link - anyone with the link can access
  /// Uses a disposable keypair embedded in the URL fragment
  publicLink,

  /// Password-protected link - requires both link and password
  /// Fragment payload is encrypted with password-derived key
  passwordProtected,
}

extension ShareTypeExtension on ShareType {
  String get displayName {
    switch (this) {
      case ShareType.recipient:
        return 'Specific Recipient';
      case ShareType.publicLink:
        return 'Anyone with Link';
      case ShareType.passwordProtected:
        return 'Password Protected';
    }
  }

  String toJson() => name;

  static ShareType fromJson(String json) {
    return ShareType.values.firstWhere(
      (t) => t.name == json,
      orElse: () => ShareType.recipient,
    );
  }
}

/// Share mode - determines content versioning behavior
enum ShareMode {
  /// Temporal mode - recipient always sees latest version
  /// If owner updates file, recipient sees new version
  temporal,

  /// Snapshot mode - recipient only sees specific version
  /// Bound to content hash, size, and timestamp
  snapshot,
}

extension ShareModeExtension on ShareMode {
  String get displayName {
    switch (this) {
      case ShareMode.temporal:
        return 'Latest Version';
      case ShareMode.snapshot:
        return 'Current Version Only';
    }
  }

  String get description {
    switch (this) {
      case ShareMode.temporal:
        return 'Recipients see any future updates to this file';
      case ShareMode.snapshot:
        return 'Recipients only see the current version, not future updates';
    }
  }

  String toJson() => name;

  static ShareMode fromJson(String json) {
    return ShareMode.values.firstWhere(
      (m) => m.name == json,
      orElse: () => ShareMode.temporal,
    );
  }
}

/// Snapshot binding - ties a share to a specific content version
class SnapshotBinding extends Equatable {
  /// Content hash (BLAKE3 or SHA256)
  final String contentHash;

  /// File size at snapshot time
  final int size;

  /// Last modified timestamp (Unix seconds)
  final int modifiedAt;

  /// Optional storage key (IPFS CID or object key)
  final String? storageKey;

  const SnapshotBinding({
    required this.contentHash,
    required this.size,
    required this.modifiedAt,
    this.storageKey,
  });

  Map<String, dynamic> toJson() => {
    'contentHash': contentHash,
    'size': size,
    'modifiedAt': modifiedAt,
    if (storageKey != null) 'storageKey': storageKey,
  };

  factory SnapshotBinding.fromJson(Map<String, dynamic> json) => SnapshotBinding(
    contentHash: json['contentHash'] as String,
    size: json['size'] as int,
    modifiedAt: json['modifiedAt'] as int,
    storageKey: json['storageKey'] as String?,
  );

  @override
  List<Object?> get props => [contentHash, size, modifiedAt, storageKey];
}

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
/// - Type-based: Recipient-specific, public link, or password-protected
/// - Mode-based: Temporal (latest) or snapshot (specific version)
class ShareToken extends Equatable {
  /// Unique identifier for this share
  final String id;

  /// fula_client share token JSON (new format)
  /// Contains encrypted key share for the recipient
  final String? fulaShareToken;

  /// Owner's public key (for verification)
  final Uint8List ownerPublicKey;

  /// Recipient's public key
  /// For public links, this is a disposable generated keypair
  final Uint8List recipientPublicKey;

  /// DEPRECATED: Encrypted DEK (wrapped for recipient using HPKE)
  /// Only kept for backward compatibility with serialized data
  final Uint8List? wrappedDek;

  /// DEPRECATED: Ephemeral public key used in HPKE encryption
  /// Only kept for backward compatibility with serialized data
  final Uint8List? ephemeralPublicKey;

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

  /// Type of share (recipient-specific, public link, or password-protected)
  final ShareType shareType;

  /// Share mode (temporal or snapshot)
  final ShareMode shareMode;

  /// Snapshot binding (only for snapshot mode)
  final SnapshotBinding? snapshotBinding;

  /// Original filename (for display purposes)
  final String? fileName;

  /// Original content type (MIME type)
  final String? contentType;

  const ShareToken({
    required this.id,
    required this.ownerPublicKey,
    required this.recipientPublicKey,
    required this.pathScope,
    required this.bucket,
    required this.permissions,
    required this.createdAt,
    this.fulaShareToken,
    this.wrappedDek,
    this.ephemeralPublicKey,
    this.expiresAt,
    this.label,
    this.isRevoked = false,
    this.shareType = ShareType.recipient,
    this.shareMode = ShareMode.temporal,
    this.snapshotBinding,
    this.fileName,
    this.contentType,
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
    if (fulaShareToken != null) 'fulaShareToken': fulaShareToken,
    'ownerPublicKey': base64Encode(ownerPublicKey),
    'recipientPublicKey': base64Encode(recipientPublicKey),
    if (wrappedDek != null) 'wrappedDek': base64Encode(wrappedDek!),
    if (ephemeralPublicKey != null) 'ephemeralPublicKey': base64Encode(ephemeralPublicKey!),
    'pathScope': pathScope,
    'bucket': bucket,
    'permissions': permissions.toJson(),
    'createdAt': createdAt.toIso8601String(),
    'expiresAt': expiresAt?.toIso8601String(),
    'label': label,
    'isRevoked': isRevoked,
    'shareType': shareType.toJson(),
    'shareMode': shareMode.toJson(),
    if (snapshotBinding != null) 'snapshotBinding': snapshotBinding!.toJson(),
    if (fileName != null) 'fileName': fileName,
    if (contentType != null) 'contentType': contentType,
  };

  /// Create from JSON
  factory ShareToken.fromJson(Map<String, dynamic> json) => ShareToken(
    id: json['id'] as String,
    fulaShareToken: json['fulaShareToken'] as String?,
    ownerPublicKey: base64Decode(json['ownerPublicKey'] as String),
    recipientPublicKey: base64Decode(json['recipientPublicKey'] as String),
    wrappedDek: json['wrappedDek'] != null
        ? base64Decode(json['wrappedDek'] as String)
        : null,
    ephemeralPublicKey: json['ephemeralPublicKey'] != null
        ? base64Decode(json['ephemeralPublicKey'] as String)
        : null,
    pathScope: json['pathScope'] as String,
    bucket: json['bucket'] as String,
    permissions: SharePermissionsExtension.fromJson(json['permissions'] as String),
    createdAt: DateTime.parse(json['createdAt'] as String),
    expiresAt: json['expiresAt'] != null
        ? DateTime.parse(json['expiresAt'] as String)
        : null,
    label: json['label'] as String?,
    isRevoked: json['isRevoked'] as bool? ?? false,
    shareType: json['shareType'] != null
        ? ShareTypeExtension.fromJson(json['shareType'] as String)
        : ShareType.recipient,
    shareMode: json['shareMode'] != null
        ? ShareModeExtension.fromJson(json['shareMode'] as String)
        : ShareMode.temporal,
    snapshotBinding: json['snapshotBinding'] != null
        ? SnapshotBinding.fromJson(json['snapshotBinding'] as Map<String, dynamic>)
        : null,
    fileName: json['fileName'] as String?,
    contentType: json['contentType'] as String?,
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
    fulaShareToken: fulaShareToken,
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
    shareType: shareType,
    shareMode: shareMode,
    snapshotBinding: snapshotBinding,
    fileName: fileName,
    contentType: contentType,
  );

  /// Create a copy with updated fields
  ShareToken copyWith({
    String? id,
    String? fulaShareToken,
    Uint8List? ownerPublicKey,
    Uint8List? recipientPublicKey,
    Uint8List? wrappedDek,
    Uint8List? ephemeralPublicKey,
    String? pathScope,
    String? bucket,
    SharePermissions? permissions,
    DateTime? createdAt,
    DateTime? expiresAt,
    String? label,
    bool? isRevoked,
    ShareType? shareType,
    ShareMode? shareMode,
    SnapshotBinding? snapshotBinding,
    String? fileName,
    String? contentType,
  }) => ShareToken(
    id: id ?? this.id,
    fulaShareToken: fulaShareToken ?? this.fulaShareToken,
    ownerPublicKey: ownerPublicKey ?? this.ownerPublicKey,
    recipientPublicKey: recipientPublicKey ?? this.recipientPublicKey,
    wrappedDek: wrappedDek ?? this.wrappedDek,
    ephemeralPublicKey: ephemeralPublicKey ?? this.ephemeralPublicKey,
    pathScope: pathScope ?? this.pathScope,
    bucket: bucket ?? this.bucket,
    permissions: permissions ?? this.permissions,
    createdAt: createdAt ?? this.createdAt,
    expiresAt: expiresAt ?? this.expiresAt,
    label: label ?? this.label,
    isRevoked: isRevoked ?? this.isRevoked,
    shareType: shareType ?? this.shareType,
    shareMode: shareMode ?? this.shareMode,
    snapshotBinding: snapshotBinding ?? this.snapshotBinding,
    fileName: fileName ?? this.fileName,
    contentType: contentType ?? this.contentType,
  );

  @override
  List<Object?> get props => [
    id,
    fulaShareToken,
    ownerPublicKey,
    recipientPublicKey,
    pathScope,
    bucket,
    permissions,
    createdAt,
    expiresAt,
    isRevoked,
    shareType,
    shareMode,
    snapshotBinding,
  ];
}

/// Represents an accepted share that the recipient can use
class AcceptedShare {
  /// The original share token
  final ShareToken token;

  /// fula_client share token for downloads (new format)
  final String? fulaShareToken;

  /// DEPRECATED: The decrypted DEK (Data Encryption Key)
  /// No longer used with fula_client - kept for backward compatibility
  final Uint8List? dek;

  /// When this share was accepted
  final DateTime acceptedAt;

  AcceptedShare({
    required this.token,
    this.fulaShareToken,
    this.dek,
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
    if (fulaShareToken != null) 'fulaShareToken': fulaShareToken,
    if (dek != null) 'dek': base64Encode(dek!),
    'acceptedAt': acceptedAt.toIso8601String(),
  };

  /// Create from JSON
  factory AcceptedShare.fromJson(Map<String, dynamic> json) => AcceptedShare(
    token: ShareToken.fromJson(json['token'] as Map<String, dynamic>),
    fulaShareToken: json['fulaShareToken'] as String?,
    dek: json['dek'] != null ? base64Decode(json['dek'] as String) : null,
    acceptedAt: DateTime.parse(json['acceptedAt'] as String),
  );

  /// Get the share ID
  String get id => token.id;
}

/// Represents a share that the owner has created (outgoing share)
class OutgoingShare {
  /// The share token
  final ShareToken token;

  /// Recipient name/identifier (for display)
  /// For public links: "Anyone with link"
  /// For password links: "Password Protected"
  final String recipientName;

  /// When the share was sent
  final DateTime sharedAt;

  /// Disposable private key for public/password links
  /// This is embedded in the URL fragment so recipients can decrypt
  /// null for recipient-specific shares
  final Uint8List? linkSecretKey;

  /// Encrypted password salt (for password-protected links)
  /// Used to verify the password on the gateway
  final Uint8List? passwordSalt;

  /// Encrypted URL fragment for password-protected links
  /// Stored so we can regenerate the exact same URL without the password
  final String? encryptedFragment;

  /// Storage key (CID) for fetching file from IPFS
  /// Stored so we can regenerate links without looking up from forest
  final String? storageKey;

  OutgoingShare({
    required this.token,
    required this.recipientName,
    DateTime? sharedAt,
    this.linkSecretKey,
    this.passwordSalt,
    this.encryptedFragment,
    this.storageKey,
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

  /// Share type
  ShareType get shareType => token.shareType;

  /// Share mode
  ShareMode get shareMode => token.shareMode;

  /// File name
  String? get fileName => token.fileName;

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
    'token': token.toJson(),
    'recipientName': recipientName,
    'sharedAt': sharedAt.toIso8601String(),
    if (linkSecretKey != null) 'linkSecretKey': base64Encode(linkSecretKey!),
    if (passwordSalt != null) 'passwordSalt': base64Encode(passwordSalt!),
    if (encryptedFragment != null) 'encryptedFragment': encryptedFragment,
    if (storageKey != null) 'storageKey': storageKey,
  };

  /// Create from JSON
  factory OutgoingShare.fromJson(Map<String, dynamic> json) => OutgoingShare(
    token: ShareToken.fromJson(json['token'] as Map<String, dynamic>),
    recipientName: json['recipientName'] as String,
    sharedAt: DateTime.parse(json['sharedAt'] as String),
    linkSecretKey: json['linkSecretKey'] != null
        ? base64Decode(json['linkSecretKey'] as String)
        : null,
    passwordSalt: json['passwordSalt'] != null
        ? base64Decode(json['passwordSalt'] as String)
        : null,
    encryptedFragment: json['encryptedFragment'] as String?,
    storageKey: json['storageKey'] as String?,
  );
}

/// Payload embedded in URL fragment for public/password-protected links
/// This data is never sent to the server (fragments are client-side only)
///
/// URL format: https://cloud.fx.land/view/{tokenId}#{base64url(payload)}
class PublicLinkPayload extends Equatable {
  /// Version of the payload format
  static const int currentVersion = 1;
  final int version;

  /// The full share token
  final ShareToken token;

  /// Disposable private key for decrypting the wrapped DEK
  /// This allows anyone with the link to unwrap the DEK
  final Uint8List linkSecretKey;

  /// Storage bucket
  final String bucket;

  /// File/folder key (path)
  final String key;

  /// Optional label for display
  final String? label;

  /// For password-protected links: encrypted with password-derived key
  /// This field contains base64-encoded encrypted payload when password is used
  final bool isPasswordProtected;

  const PublicLinkPayload({
    this.version = currentVersion,
    required this.token,
    required this.linkSecretKey,
    required this.bucket,
    required this.key,
    this.label,
    this.isPasswordProtected = false,
  });

  /// Encode payload to base64url for URL fragment
  String encode() {
    final json = toJson();
    final jsonString = jsonEncode(json);
    final bytes = utf8.encode(jsonString);
    // Use URL-safe base64 encoding
    return base64UrlEncode(bytes);
  }

  /// Decode payload from base64url fragment
  static PublicLinkPayload decode(String encoded) {
    // Handle both regular and URL-safe base64
    String normalized = encoded;
    // Add padding if missing
    while (normalized.length % 4 != 0) {
      normalized += '=';
    }
    final bytes = base64Url.decode(normalized);
    final jsonString = utf8.decode(bytes);
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    return PublicLinkPayload.fromJson(json);
  }

  Map<String, dynamic> toJson() => {
    'v': version,
    't': token.toJson(),
    'sk': base64Encode(linkSecretKey),
    'b': bucket,
    'k': key,
    if (label != null) 'l': label,
    if (isPasswordProtected) 'p': true,
  };

  factory PublicLinkPayload.fromJson(Map<String, dynamic> json) => PublicLinkPayload(
    version: json['v'] as int? ?? currentVersion,
    token: ShareToken.fromJson(json['t'] as Map<String, dynamic>),
    linkSecretKey: base64Decode(json['sk'] as String),
    bucket: json['b'] as String,
    key: json['k'] as String,
    label: json['l'] as String?,
    isPasswordProtected: json['p'] as bool? ?? false,
  );

  @override
  List<Object?> get props => [version, token, bucket, key, isPasswordProtected];
}

/// Represents a generated share link with all necessary data
class GeneratedShareLink {
  /// The full URL including fragment
  final String url;

  /// The share token
  final ShareToken token;

  /// The outgoing share record
  final OutgoingShare outgoingShare;

  /// The payload (for public/password links)
  final PublicLinkPayload? payload;

  /// Password used (for password-protected links, not stored)
  final String? password;

  const GeneratedShareLink({
    required this.url,
    required this.token,
    required this.outgoingShare,
    this.payload,
    this.password,
  });
}

/// Predefined expiry durations for shares
enum ShareExpiry {
  oneDay(1, '1 Day'),
  oneWeek(7, '1 Week'),
  oneMonth(30, '1 Month'),
  oneYear(365, '1 Year'),
  fiveYears(1825, '5 Years');

  final int days;
  final String displayName;

  const ShareExpiry(this.days, this.displayName);

  DateTime get expiryDate => DateTime.now().add(Duration(days: days));
}
