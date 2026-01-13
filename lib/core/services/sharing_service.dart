import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart' as fula_service;
import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_files/core/services/secure_storage_service.dart';

/// Gateway base URL for public share links
const String kShareGatewayBaseUrl = 'https://cloud.fx.land';

/// Service for secure file sharing between users
///
/// Based on Fula API sharing pattern:
/// - Path-Scoped: Share only specific folders
/// - Time-Limited: Access expires automatically
/// - Permission-Based: Read-only, read-write, or full
/// - Revocable: Cancel access at any time
/// - Zero Knowledge: Server can't read shared content
///
/// Supports three share types:
/// 1. Recipient-specific: Share with a known public key
/// 2. Public link: Anyone with the link can access (disposable keypair in URL)
/// 3. Password-protected: Requires both link and password
class SharingService {
  static final SharingService instance = SharingService._();
  SharingService._();

  static const String _outgoingSharesKey = 'outgoing_shares';
  static const String _acceptedSharesKey = 'accepted_shares';
  static const String _revokedSharesKey = 'revoked_shares';

  final _uuid = const Uuid();
  final _random = Random.secure();

  // Cryptographic algorithm for password encryption
  static final _aesGcm = AesGcm.with256bits();

  // ============================================================================
  // CRYPTOGRAPHIC HELPERS (for password-protected links)
  // ============================================================================

  /// Derive encryption key from password using PBKDF2
  Future<Uint8List> _deriveKeyFromPassword(String password, Uint8List salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );

    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );

    return Uint8List.fromList(await secretKey.extractBytes());
  }

  /// Encrypt data using AES-GCM
  Future<Uint8List> _encrypt(Uint8List data, Uint8List key) async {
    final secretKey = SecretKey(key);
    final nonce = _aesGcm.newNonce();
    final secretBox = await _aesGcm.encrypt(data, secretKey: secretKey, nonce: nonce);

    // Return nonce + ciphertext + mac
    return Uint8List.fromList([
      ...nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
  }

  /// Decrypt data using AES-GCM
  Future<Uint8List> _decrypt(Uint8List encryptedData, Uint8List key) async {
    final nonceLength = _aesGcm.nonceLength;
    final macLength = _aesGcm.macAlgorithm.macLength;

    final nonce = encryptedData.sublist(0, nonceLength);
    final cipherText = encryptedData.sublist(nonceLength, encryptedData.length - macLength);
    final mac = encryptedData.sublist(encryptedData.length - macLength);

    final secretKey = SecretKey(key);
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
    final decrypted = await _aesGcm.decrypt(secretBox, secretKey: secretKey);

    return Uint8List.fromList(decrypted);
  }

  /// Generate random salt
  Uint8List _generateSalt(int length) {
    return Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));
  }

  // ============================================================================
  // OWNER SIDE - Creating and managing shares
  // ============================================================================

  /// Get the storage key (CID) for a path from the forest metadata
  Future<String> _getStorageKeyForPath(String bucket, String path) async {
    if (!fula_service.FulaApiService.instance.isConfigured) {
      throw SharingException('Fula API not configured');
    }
    debugPrint('SharingService: Looking for file in bucket=$bucket, path=$path');
    final objects = await fula_service.FulaApiService.instance.listObjects(bucket, prefix: path);
    debugPrint('SharingService: Found ${objects.length} objects with prefix "$path"');
    for (final o in objects) {
      debugPrint('SharingService:   - key="${o.key}", storageKey="${o.storageKey}"');
    }
    final obj = objects.firstWhere(
      (o) => o.key == path,
      orElse: () => throw SharingException('File not found: $path'),
    );
    debugPrint('SharingService: Found file, storageKey=${obj.storageKey}');
    return obj.storageKey ?? obj.key;
  }

  /// Create a share token for a recipient
  ///
  /// Process (with fula_client):
  /// 1. Get storage key for the path
  /// 2. Create fula_client share token with recipient's public key
  /// 3. Return ShareToken with embedded fula_client token
  ///
  /// Note: The 'dek' parameter is ignored - kept for interface compatibility
  Future<ShareToken> createShare({
    required String pathScope,
    required String bucket,
    required Uint8List recipientPublicKey,
    Uint8List? dek,  // DEPRECATED - ignored, kept for interface compat
    SharePermissions permissions = SharePermissions.readOnly,
    int? expiryDays,
    String? label,
    ShareType shareType = ShareType.recipient,
    ShareMode shareMode = ShareMode.temporal,
    SnapshotBinding? snapshotBinding,
    String? fileName,
    String? contentType,
  }) async {
    // Get owner's public key
    final ownerPublicKey = await AuthService.instance.getPublicKey();
    if (ownerPublicKey == null) {
      throw SharingException('Owner public key not available. Please sign in first.');
    }

    if (!fula_service.FulaApiService.instance.isConfigured) {
      throw SharingException('Fula API not configured. Please connect to cloud storage first.');
    }

    // Get storage key for the path
    final storageKey = await _getStorageKeyForPath(bucket, pathScope);

    // Calculate expiry as Unix timestamp
    final now = DateTime.now();
    final expiresAt = expiryDays != null
        ? now.add(Duration(days: expiryDays))
        : null;
    final expiresAtUnix = expiresAt != null
        ? expiresAt.millisecondsSinceEpoch ~/ 1000
        : null;

    // Create fula_client share token
    final fulaToken = await fula_service.FulaApiService.instance.createShareToken(
      bucket,  // Bucket name
      storageKey,
      recipientPublicKey,
      shareMode,
      expiresAtUnix,
    );

    return ShareToken(
      id: _uuid.v4(),
      fulaShareToken: fulaToken,
      ownerPublicKey: ownerPublicKey,
      recipientPublicKey: recipientPublicKey,
      pathScope: pathScope,
      bucket: bucket,
      permissions: permissions,
      createdAt: now,
      expiresAt: expiresAt,
      label: label,
      shareType: shareType,
      shareMode: shareMode,
      snapshotBinding: snapshotBinding,
      fileName: fileName,
      contentType: contentType,
    );
  }

  /// Create and save an outgoing share for a specific recipient
  Future<OutgoingShare> shareWithUser({
    required String pathScope,
    required String bucket,
    required Uint8List recipientPublicKey,
    required String recipientName,
    Uint8List? dek,  // DEPRECATED - ignored, kept for interface compat
    SharePermissions permissions = SharePermissions.readOnly,
    int? expiryDays,
    String? label,
    ShareMode shareMode = ShareMode.temporal,
    SnapshotBinding? snapshotBinding,
    String? fileName,
    String? contentType,
  }) async {
    final token = await createShare(
      pathScope: pathScope,
      bucket: bucket,
      recipientPublicKey: recipientPublicKey,
      permissions: permissions,
      expiryDays: expiryDays,
      label: label,
      shareType: ShareType.recipient,
      shareMode: shareMode,
      snapshotBinding: snapshotBinding,
      fileName: fileName,
      contentType: contentType,
    );

    final outgoingShare = OutgoingShare(
      token: token,
      recipientName: recipientName,
    );

    // Save to storage
    await _saveOutgoingShare(outgoingShare);

    return outgoingShare;
  }

  /// Create a public link that anyone with the link can access
  ///
  /// Uses fula_client share tokens. The token is embedded in the URL fragment
  /// so it's never sent to the server, keeping secrets client-side.
  ///
  /// Security considerations:
  /// - The link allows access to ONLY the specified file/folder (path-scoped)
  /// - Access expires according to expiryDays
  /// - Owner can revoke access at any time
  /// - URL fragment is never transmitted to server (HTTP spec)
  Future<GeneratedShareLink> createPublicLink({
    required String pathScope,
    required String bucket,
    Uint8List? dek,  // DEPRECATED - ignored, kept for interface compat
    required int expiryDays,
    String? label,
    ShareMode shareMode = ShareMode.temporal,
    SnapshotBinding? snapshotBinding,
    String? fileName,
    String? contentType,
    String? gatewayBaseUrl,
  }) async {
    // Get owner's public key
    final ownerPublicKey = await AuthService.instance.getPublicKey();
    if (ownerPublicKey == null) {
      throw SharingException('Owner public key not available. Please sign in first.');
    }

    if (!fula_service.FulaApiService.instance.isConfigured) {
      throw SharingException('Fula API not configured. Please connect to cloud storage first.');
    }

    // Get storage key (CID) for the path - needed for file fetching
    debugPrint('SharingService.createPublicLink: bucket=$bucket, pathScope=$pathScope');
    final storageKey = await _getStorageKeyForPath(bucket, pathScope);
    debugPrint('SharingService.createPublicLink: storageKey=$storageKey');

    // Calculate expiry as Unix timestamp
    final now = DateTime.now();
    final expiresAt = now.add(Duration(days: expiryDays));
    final expiresAtUnix = expiresAt.millisecondsSinceEpoch ~/ 1000;

    // Generate a disposable X25519 keypair for public link
    // The private key is embedded in the URL so anyone with the link can decrypt
    // Use Rust-based key derivation for compatibility with fula_client
    final privateKeyBytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      privateKeyBytes[i] = _random.nextInt(256);
    }
    final publicKeyBytes = Uint8List.fromList(
      await fula.derivePublicKeyFromSecret(secretKeyBytes: privateKeyBytes.toList()),
    );
    debugPrint('SharingService.createPublicLink: generated disposable keypair (${publicKeyBytes.length} bytes public, ${privateKeyBytes.length} bytes private)');

    // Create fula_client share token with the disposable public key
    // DEK is fetched from object metadata (x-fula-encryption), not derived from path
    debugPrint('SharingService.createPublicLink: creating fula share token with bucket=$bucket, storageKey=$storageKey...');
    String fulaToken;
    try {
      fulaToken = await fula_service.FulaApiService.instance.createShareToken(
        bucket,  // Bucket name
        storageKey,  // CID - used to fetch object and its DEK from metadata
        publicKeyBytes,  // Disposable public key for public share
        shareMode,
        expiresAtUnix,
      );
      debugPrint('SharingService.createPublicLink: fula share token created: ${fulaToken.substring(0, 50)}...');
    } catch (e, stack) {
      debugPrint('SharingService.createPublicLink: ERROR creating fula share token: $e');
      debugPrint('SharingService.createPublicLink: Stack: $stack');
      rethrow;
    }

    // Create share token for our records
    final tokenId = _uuid.v4();
    final token = ShareToken(
      id: tokenId,
      fulaShareToken: fulaToken,
      ownerPublicKey: ownerPublicKey,
      recipientPublicKey: publicKeyBytes,  // Store the disposable public key
      pathScope: pathScope,
      bucket: bucket,
      permissions: SharePermissions.readOnly,
      createdAt: now,
      expiresAt: expiresAt,
      label: label,
      shareType: ShareType.publicLink,
      shareMode: shareMode,
      snapshotBinding: snapshotBinding,
      fileName: fileName,
      contentType: contentType,
    );

    // Build payload with fula token and private key (v2 format)
    // The private key is needed by the recipient to decrypt the share token
    final payloadMap = {
      'v': 2,  // Version 2 = fula_client format
      't': fulaToken,
      'b': bucket,
      'k': pathScope,  // Original path - used for DEK derivation
      'cid': storageKey,  // Storage key/CID - used for fetching file from IPFS
      'sk': base64Encode(privateKeyBytes),  // Secret key for decryption
      if (label != null) 'l': label,
      if (fileName != null) 'f': fileName,
    };
    final fragment = base64UrlEncode(utf8.encode(jsonEncode(payloadMap)));

    // Build the URL
    final baseUrl = gatewayBaseUrl ?? kShareGatewayBaseUrl;
    final url = '$baseUrl/view/$tokenId#$fragment';

    // Save outgoing share with the private key and storage key for regeneration
    final outgoingShare = OutgoingShare(
      token: token,
      recipientName: 'Anyone with link',
      linkSecretKey: privateKeyBytes,  // Store for URL regeneration
      storageKey: storageKey,  // Store CID for URL regeneration
    );
    await _saveOutgoingShare(outgoingShare);

    return GeneratedShareLink(
      url: url,
      token: token,
      outgoingShare: outgoingShare,
    );
  }

  /// Create a password-protected link
  ///
  /// Uses fula_client share tokens, encrypted with a password-derived key.
  /// Anyone with both the link AND the password can access the file.
  ///
  /// Security: Adds an extra layer - even if link is intercepted,
  /// password is still required to decrypt the fula_client token.
  Future<GeneratedShareLink> createPasswordProtectedLink({
    required String pathScope,
    required String bucket,
    Uint8List? dek,  // DEPRECATED - ignored, kept for interface compat
    required int expiryDays,
    required String password,
    String? label,
    ShareMode shareMode = ShareMode.temporal,
    SnapshotBinding? snapshotBinding,
    String? fileName,
    String? contentType,
    String? gatewayBaseUrl,
  }) async {
    if (password.isEmpty) {
      throw SharingException('Password cannot be empty');
    }

    // Get owner's public key
    final ownerPublicKey = await AuthService.instance.getPublicKey();
    if (ownerPublicKey == null) {
      throw SharingException('Owner public key not available. Please sign in first.');
    }

    if (!fula_service.FulaApiService.instance.isConfigured) {
      throw SharingException('Fula API not configured. Please connect to cloud storage first.');
    }

    // Get storage key (CID) for the path - needed for file fetching
    final storageKey = await _getStorageKeyForPath(bucket, pathScope);

    // Calculate expiry as Unix timestamp
    final now = DateTime.now();
    final expiresAt = now.add(Duration(days: expiryDays));
    final expiresAtUnix = expiresAt.millisecondsSinceEpoch ~/ 1000;

    // Generate a disposable X25519 keypair for password-protected link
    // Use Rust-based key derivation for compatibility with fula_client
    final privateKeyBytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      privateKeyBytes[i] = _random.nextInt(256);
    }
    final publicKeyBytes = Uint8List.fromList(
      await fula.derivePublicKeyFromSecret(secretKeyBytes: privateKeyBytes.toList()),
    );

    // Create fula_client share token with the disposable public key
    // DEK is fetched from object metadata (x-fula-encryption), not derived from path
    final fulaToken = await fula_service.FulaApiService.instance.createShareToken(
      bucket,  // Bucket name
      storageKey,  // CID - used to fetch object and its DEK from metadata
      publicKeyBytes,  // Disposable public key for password-protected share
      shareMode,
      expiresAtUnix,
    );

    // Create share token for our records
    final tokenId = _uuid.v4();
    final token = ShareToken(
      id: tokenId,
      fulaShareToken: fulaToken,
      ownerPublicKey: ownerPublicKey,
      recipientPublicKey: publicKeyBytes,  // Store the disposable public key
      pathScope: pathScope,
      bucket: bucket,
      permissions: SharePermissions.readOnly,
      createdAt: now,
      expiresAt: expiresAt,
      label: label,
      shareType: ShareType.passwordProtected,
      shareMode: shareMode,
      snapshotBinding: snapshotBinding,
      fileName: fileName,
      contentType: contentType,
    );

    // Build inner payload with fula token and secret key (v2 format)
    // The secret key is needed by the recipient to decrypt the share token
    final innerPayloadMap = {
      'v': 2,
      't': fulaToken,
      'b': bucket,
      'k': pathScope,  // Original path - used for DEK derivation
      'cid': storageKey,  // Storage key/CID - used for fetching file from IPFS
      'sk': base64Encode(privateKeyBytes),  // Secret key for decryption
      if (label != null) 'l': label,
      if (fileName != null) 'f': fileName,
    };

    // Encrypt the inner payload with password-derived key
    final salt = _generateSalt(16);
    final passwordKey = await _deriveKeyFromPassword(password, salt);
    final encryptedPayload = await _encrypt(
      Uint8List.fromList(utf8.encode(jsonEncode(innerPayloadMap))),
      passwordKey,
    );

    // Create outer wrapper with salt and encrypted inner payload
    final outerPayload = {
      'v': 2,  // Version 2 = fula_client format
      'p': true, // password protected flag
      's': base64Encode(salt),
      'e': base64Encode(encryptedPayload),
      'b': bucket,
      'k': pathScope,
    };

    // Encode outer payload for URL
    final fragment = base64UrlEncode(utf8.encode(jsonEncode(outerPayload)));

    // Build the URL
    final baseUrl = gatewayBaseUrl ?? kShareGatewayBaseUrl;
    final url = '$baseUrl/view/$tokenId#$fragment';

    // Save outgoing share with the encrypted fragment and storage key for regeneration
    final outgoingShare = OutgoingShare(
      token: token,
      recipientName: 'Password Protected',
      passwordSalt: salt,
      encryptedFragment: fragment, // Store to regenerate same URL later
      storageKey: storageKey,  // Store CID for reference
    );
    await _saveOutgoingShare(outgoingShare);

    return GeneratedShareLink(
      url: url,
      token: token,
      outgoingShare: outgoingShare,
      password: password,
    );
  }

  /// Decode a password-protected link payload
  ///
  /// Called by the gateway/viewer to decrypt the inner payload
  /// Supports both v1 (legacy) and v2 (fula_client) formats
  ///
  /// Returns the decrypted payload as a Map containing the fula_client token
  static Future<Map<String, dynamic>> decodePasswordProtectedPayloadV2(
    String fragment,
    String password,
  ) async {
    // Decode outer payload
    String normalized = fragment;
    while (normalized.length % 4 != 0) {
      normalized += '=';
    }
    final outerBytes = base64Url.decode(normalized);
    final outerJson = jsonDecode(utf8.decode(outerBytes)) as Map<String, dynamic>;

    if (outerJson['p'] != true) {
      throw SharingException('Not a password-protected link');
    }

    final salt = Uint8List.fromList(base64Decode(outerJson['s'] as String));
    final encryptedPayload = Uint8List.fromList(base64Decode(outerJson['e'] as String));

    // Derive key from password
    final passwordKey = await instance._deriveKeyFromPassword(password, salt);

    // Decrypt inner payload
    try {
      final decryptedBytes = await instance._decrypt(encryptedPayload, passwordKey);
      final innerJson = jsonDecode(utf8.decode(decryptedBytes)) as Map<String, dynamic>;
      return innerJson;
    } catch (e) {
      throw SharingException('Invalid password');
    }
  }

  /// Legacy: Decode a password-protected link payload (v1 format)
  /// @deprecated Use decodePasswordProtectedPayloadV2 instead
  static Future<PublicLinkPayload> decodePasswordProtectedPayload(
    String fragment,
    String password,
  ) async {
    final innerJson = await decodePasswordProtectedPayloadV2(fragment, password);
    return PublicLinkPayload.fromJson(innerJson);
  }

  /// Regenerate a public link URL from an existing share
  ///
  /// Useful when user wants to copy the link again
  String regeneratePublicLink(OutgoingShare share, {String? gatewayBaseUrl}) {
    final baseUrl = gatewayBaseUrl ?? kShareGatewayBaseUrl;

    // For password-protected links, use the stored encrypted fragment
    if (share.shareType == ShareType.passwordProtected && share.encryptedFragment != null) {
      return '$baseUrl/view/${share.token.id}#${share.encryptedFragment}';
    }

    // For public links with fula token (v2 format)
    if (share.token.fulaShareToken != null && share.linkSecretKey != null) {
      final payloadMap = {
        'v': 2,
        't': share.token.fulaShareToken,
        'b': share.bucket,
        'k': share.pathScope,  // Original path - used for DEK derivation
        if (share.storageKey != null) 'cid': share.storageKey,  // CID for fetching from IPFS
        'sk': base64Encode(share.linkSecretKey!),  // Secret key for decryption
        if (share.token.label != null) 'l': share.token.label,
        if (share.token.fileName != null) 'f': share.token.fileName,
      };
      final fragment = base64UrlEncode(utf8.encode(jsonEncode(payloadMap)));
      return '$baseUrl/view/${share.token.id}#$fragment';
    }

    // For legacy public links with linkSecretKey (v1 format)
    if (share.linkSecretKey != null) {
      final payload = PublicLinkPayload(
        token: share.token,
        linkSecretKey: share.linkSecretKey!,
        bucket: share.bucket,
        key: share.pathScope,
        label: share.token.label,
        isPasswordProtected: false,
      );
      return '$baseUrl/view/${share.token.id}#${payload.encode()}';
    }

    throw SharingException('Cannot regenerate link - missing required data');
  }

  /// Revoke a share
  Future<void> revokeShare(String shareId) async {
    final shares = await getOutgoingShares();
    final shareIndex = shares.indexWhere((s) => s.id == shareId);
    
    if (shareIndex == -1) {
      throw SharingException('Share not found');
    }

    // Update share to revoked
    final share = shares[shareIndex];
    final revokedToken = share.token.revoke();
    shares[shareIndex] = OutgoingShare(
      token: revokedToken,
      recipientName: share.recipientName,
      sharedAt: share.sharedAt,
    );

    // Save updated shares
    await _saveOutgoingShares(shares);

    // Add to revoked list (for sync with recipient)
    await _addToRevokedList(shareId);
  }

  /// Get all outgoing shares (shares created by this user)
  Future<List<OutgoingShare>> getOutgoingShares() async {
    final json = await SecureStorageService.instance.read(_outgoingSharesKey);
    if (json == null) return [];

    try {
      final list = jsonDecode(json) as List;
      return list
          .map((e) => OutgoingShare.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Error loading outgoing shares: $e');
      return [];
    }
  }

  /// Get active (non-revoked, non-expired) outgoing shares
  Future<List<OutgoingShare>> getActiveOutgoingShares() async {
    final shares = await getOutgoingShares();
    return shares.where((s) => s.isValid).toList();
  }

  /// Get shares for a specific path
  Future<List<OutgoingShare>> getSharesForPath(String bucket, String path) async {
    final shares = await getOutgoingShares();
    return shares.where((s) => 
      s.bucket == bucket && 
      (path.startsWith(s.pathScope) || s.pathScope.startsWith(path))
    ).toList();
  }

  // ============================================================================
  // RECIPIENT SIDE - Accepting and using shares
  // ============================================================================

  /// Accept a share token
  ///
  /// Process (with fula_client):
  /// 1. Verify token is valid (not expired, not revoked)
  /// 2. Verify recipient matches (for non-public shares)
  /// 3. Validate with fula_client
  /// 4. Store accepted share for future use
  Future<AcceptedShare> acceptShare(ShareToken token) async {
    // Check if share is valid
    if (token.isExpired) {
      throw SharingException('Share has expired');
    }
    if (token.isRevoked) {
      throw SharingException('Share has been revoked');
    }

    // Check if this share is in the revoked list
    if (await _isShareRevoked(token.id)) {
      throw SharingException('Share has been revoked by owner');
    }

    // For recipient-specific shares, verify recipient
    if (token.shareType == ShareType.recipient) {
      final myPublicKey = await AuthService.instance.getPublicKey();
      if (myPublicKey == null || !_compareKeys(myPublicKey, token.recipientPublicKey)) {
        throw SharingException('This share was not intended for you');
      }
    }

    // Get fula_client token
    final fulaToken = token.fulaShareToken;
    if (fulaToken == null) {
      throw SharingException('Invalid share token format - missing fula token');
    }

    // Validate with fula_client (will throw if invalid)
    try {
      fula_service.FulaApiService.instance.acceptShareToken(fulaToken);
    } catch (e) {
      throw SharingException('Failed to validate share token: $e');
    }

    final acceptedShare = AcceptedShare(
      token: token,
      fulaShareToken: fulaToken,
    );

    // Save accepted share
    await _saveAcceptedShare(acceptedShare);

    return acceptedShare;
  }

  /// Download a file using an accepted share
  ///
  /// This is the new method for downloading shared files with fula_client
  Future<Uint8List> downloadSharedFile(AcceptedShare share) async {
    final fulaToken = share.fulaShareToken ?? share.token.fulaShareToken;
    if (fulaToken == null) {
      throw SharingException('Invalid share - no fula token available');
    }

    if (!fula_service.FulaApiService.instance.isConfigured) {
      throw SharingException('Fula API not configured');
    }

    // Get storage key for the path
    final storageKey = await _getStorageKeyForPath(share.bucket, share.pathScope);

    // Accept and download via fula_client
    final handle = await fula_service.FulaApiService.instance.acceptShareToken(fulaToken);
    return await fula_service.FulaApiService.instance.downloadSharedFile(
      share.bucket,
      storageKey,
      handle,
    );
  }

  /// Accept a share from encoded string (from URL/QR code)
  Future<AcceptedShare> acceptShareFromString(String encoded) async {
    try {
      final token = ShareToken.decode(encoded);
      return await acceptShare(token);
    } catch (e) {
      throw SharingException('Invalid share token: $e');
    }
  }

  /// Get all accepted shares (shares received by this user)
  Future<List<AcceptedShare>> getAcceptedShares() async {
    final json = await SecureStorageService.instance.read(_acceptedSharesKey);
    if (json == null) return [];

    try {
      final list = jsonDecode(json) as List;
      return list
          .map((e) => AcceptedShare.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Error loading accepted shares: $e');
      return [];
    }
  }

  /// Get valid accepted shares
  Future<List<AcceptedShare>> getValidAcceptedShares() async {
    final shares = await getAcceptedShares();
    final revokedIds = await _getRevokedShareIds();
    
    return shares.where((s) => 
      s.isValid && !revokedIds.contains(s.token.id)
    ).toList();
  }

  /// Get accepted share for a specific path
  Future<AcceptedShare?> getShareForPath(String bucket, String path) async {
    final shares = await getValidAcceptedShares();
    
    for (final share in shares) {
      if (share.bucket == bucket && share.hasAccessTo(path)) {
        return share;
      }
    }
    return null;
  }

  /// Remove an accepted share
  Future<void> removeAcceptedShare(String shareId) async {
    final shares = await getAcceptedShares();
    shares.removeWhere((s) => s.token.id == shareId);
    await _saveAcceptedShares(shares);
  }

  // ============================================================================
  // HELPER METHODS
  // ============================================================================

  /// Generate a shareable link based on share type
  ///
  /// For recipient-specific shares: fxblox://share/{encoded_token}
  /// For public links: Already generated with createPublicLink()
  /// For password links: Already generated with createPasswordProtectedLink()
  ///
  /// NOTE: For password-protected links, use generateShareLinkFromOutgoing() instead
  /// as it can use the stored encrypted fragment.
  String generateShareLink(ShareToken token, {String? baseUrl, Uint8List? linkSecretKey, String? encryptedFragment}) {
    final gatewayBase = baseUrl ?? kShareGatewayBaseUrl;

    // For password-protected links with stored encrypted fragment, use it directly
    if (token.shareType == ShareType.passwordProtected && encryptedFragment != null) {
      return '$gatewayBase/view/${token.id}#$encryptedFragment';
    }

    // For public links that have linkSecretKey, generate gateway URL
    if (linkSecretKey != null && token.shareType == ShareType.publicLink) {
      final payload = PublicLinkPayload(
        token: token,
        linkSecretKey: linkSecretKey,
        bucket: token.bucket,
        key: token.pathScope,
        label: token.label,
        isPasswordProtected: false,
      );

      return '$gatewayBase/view/${token.id}#${payload.encode()}';
    }

    // For recipient-specific shares, use app deep link
    final encoded = token.encode();
    final base = baseUrl ?? 'fxblox://share';
    return '$base/$encoded';
  }

  /// Generate share link from OutgoingShare (handles all types)
  String generateShareLinkFromOutgoing(OutgoingShare share, {String? baseUrl}) {
    return generateShareLink(
      share.token,
      baseUrl: baseUrl,
      linkSecretKey: share.linkSecretKey,
      encryptedFragment: share.encryptedFragment,
    );
  }

  /// Parse share token from URL
  ShareToken? parseShareLink(String url) {
    try {
      // Handle different URL formats
      String encoded;

      // Check for gateway public link format
      if (url.contains('/view/') && url.contains('#')) {
        // This is a public/password link - parse the fragment
        final uri = Uri.parse(url);
        final fragment = uri.fragment;
        if (fragment.isNotEmpty) {
          try {
            final payload = PublicLinkPayload.decode(fragment);
            return payload.token;
          } catch (e) {
            // Might be password-protected, return null for now
            debugPrint('Could not parse public link fragment: $e');
            return null;
          }
        }
        return null;
      }

      // Handle app deep link format
      if (url.startsWith('fxblox://share/')) {
        encoded = url.substring('fxblox://share/'.length);
      } else if (url.contains('?token=')) {
        final uri = Uri.parse(url);
        encoded = uri.queryParameters['token'] ?? '';
      } else {
        // Assume it's just the encoded token
        encoded = url;
      }

      return ShareToken.decode(encoded);
    } catch (e) {
      debugPrint('Error parsing share link: $e');
      return null;
    }
  }

  /// Parse a public link and return the full payload
  PublicLinkPayload? parsePublicLink(String url) {
    try {
      if (!url.contains('#')) return null;

      final uri = Uri.parse(url);
      final fragment = uri.fragment;
      if (fragment.isEmpty) return null;

      return PublicLinkPayload.decode(fragment);
    } catch (e) {
      debugPrint('Error parsing public link: $e');
      return null;
    }
  }

  /// Check if a URL is a password-protected link
  bool isPasswordProtectedLink(String url) {
    try {
      if (!url.contains('#')) return false;

      final uri = Uri.parse(url);
      final fragment = uri.fragment;
      if (fragment.isEmpty) return false;

      // Try to parse the outer wrapper
      String normalized = fragment;
      while (normalized.length % 4 != 0) {
        normalized += '=';
      }
      final bytes = base64Url.decode(normalized);
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

      return json['p'] == true;
    } catch (e) {
      return false;
    }
  }

  /// Check if user has access to a path via any share
  Future<bool> hasAccessTo(String bucket, String path) async {
    final share = await getShareForPath(bucket, path);
    return share != null;
  }

  /// DEPRECATED: Get DEK for a shared path
  /// With fula_client, use downloadSharedFile() instead
  @Deprecated('Use downloadSharedFile() instead')
  Future<Uint8List?> getDekForPath(String bucket, String path) async {
    // DEKs are no longer used with fula_client
    // Use downloadSharedFile() to download shared files
    return null;
  }

  // ============================================================================
  // PRIVATE STORAGE METHODS
  // ============================================================================

  Future<void> _saveOutgoingShare(OutgoingShare share) async {
    final shares = await getOutgoingShares();
    shares.add(share);
    await _saveOutgoingShares(shares);
  }

  Future<void> _saveOutgoingShares(List<OutgoingShare> shares) async {
    final json = jsonEncode(shares.map((s) => s.toJson()).toList());
    await SecureStorageService.instance.write(_outgoingSharesKey, json);
  }

  Future<void> _saveAcceptedShare(AcceptedShare share) async {
    final shares = await getAcceptedShares();
    // Remove any existing share with same ID
    shares.removeWhere((s) => s.token.id == share.token.id);
    shares.add(share);
    await _saveAcceptedShares(shares);
  }

  Future<void> _saveAcceptedShares(List<AcceptedShare> shares) async {
    final json = jsonEncode(shares.map((s) => s.toJson()).toList());
    await SecureStorageService.instance.write(_acceptedSharesKey, json);
  }

  Future<void> _addToRevokedList(String shareId) async {
    final revokedIds = await _getRevokedShareIds();
    if (!revokedIds.contains(shareId)) {
      revokedIds.add(shareId);
      await SecureStorageService.instance.write(
        _revokedSharesKey,
        jsonEncode(revokedIds),
      );
    }
  }

  Future<List<String>> _getRevokedShareIds() async {
    final json = await SecureStorageService.instance.read(_revokedSharesKey);
    if (json == null) return [];
    
    try {
      return (jsonDecode(json) as List).cast<String>();
    } catch (e) {
      return [];
    }
  }

  Future<bool> _isShareRevoked(String shareId) async {
    final revokedIds = await _getRevokedShareIds();
    return revokedIds.contains(shareId);
  }

  bool _compareKeys(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Import outgoing shares (used for cloud sync restore)
  Future<void> importOutgoingShares(List<OutgoingShare> shares) async {
    await _saveOutgoingShares(shares);
  }

  /// Clear all sharing data (for sign out)
  Future<void> clearAll() async {
    await SecureStorageService.instance.delete(_outgoingSharesKey);
    await SecureStorageService.instance.delete(_acceptedSharesKey);
    await SecureStorageService.instance.delete(_revokedSharesKey);
  }
}

/// Exception for sharing operations
class SharingException implements Exception {
  final String message;
  SharingException(this.message);

  @override
  String toString() => 'SharingException: $message';
}
