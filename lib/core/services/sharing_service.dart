import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/encryption_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
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

  // ============================================================================
  // OWNER SIDE - Creating and managing shares
  // ============================================================================

  /// Create a share token for a recipient
  ///
  /// Process:
  /// 1. Generate ephemeral keypair for HPKE
  /// 2. Derive shared secret using X25519 DH
  /// 3. Wrap DEK with derived key
  /// 4. Create share token with wrapped DEK
  Future<ShareToken> createShare({
    required String pathScope,
    required String bucket,
    required Uint8List recipientPublicKey,
    required Uint8List dek,
    SharePermissions permissions = SharePermissions.readOnly,
    int? expiryDays,
    String? label,
    ShareType shareType = ShareType.recipient,
    ShareMode shareMode = ShareMode.temporal,
    SnapshotBinding? snapshotBinding,
    String? fileName,
    String? contentType,
  }) async {
    // Get owner's keypair
    final ownerPublicKey = await AuthService.instance.getPublicKey();
    if (ownerPublicKey == null) {
      throw SharingException('Owner public key not available. Please sign in first.');
    }

    // Generate ephemeral keypair for HPKE key wrapping
    final ephemeralKeyPair = await EncryptionService.instance.generateKeyPair();

    // Wrap DEK for recipient using HPKE
    // DEK is encrypted with a key derived from:
    // ephemeral_secret + recipient_public_key
    final wrappedDek = await EncryptionService.instance.wrapKeyForRecipient(
      dek,
      recipientPublicKey,
      ephemeralKeyPair.privateKey,
    );

    final now = DateTime.now();
    final expiresAt = expiryDays != null
        ? now.add(Duration(days: expiryDays))
        : null;

    return ShareToken(
      id: _uuid.v4(),
      ownerPublicKey: ownerPublicKey,
      recipientPublicKey: recipientPublicKey,
      wrappedDek: wrappedDek,
      ephemeralPublicKey: ephemeralKeyPair.publicKey,
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
    required Uint8List dek,
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
      dek: dek,
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
  /// This generates a disposable keypair, wraps the DEK for that keypair,
  /// and embeds both the token and the private key in the URL fragment.
  /// The fragment is never sent to the server, keeping secrets client-side.
  ///
  /// Security considerations:
  /// - The link allows access to ONLY the specified file/folder (path-scoped)
  /// - Access expires according to expiryDays
  /// - Owner can revoke access at any time
  /// - URL fragment is never transmitted to server (HTTP spec)
  Future<GeneratedShareLink> createPublicLink({
    required String pathScope,
    required String bucket,
    required Uint8List dek,
    required int expiryDays,
    String? label,
    ShareMode shareMode = ShareMode.temporal,
    SnapshotBinding? snapshotBinding,
    String? fileName,
    String? contentType,
    String? gatewayBaseUrl,
  }) async {
    // Generate a disposable keypair for this link
    final linkKeyPair = await EncryptionService.instance.generateKeyPair();

    // Create share token with the disposable public key as recipient
    final token = await createShare(
      pathScope: pathScope,
      bucket: bucket,
      recipientPublicKey: linkKeyPair.publicKey,
      dek: dek,
      permissions: SharePermissions.readOnly,
      expiryDays: expiryDays,
      label: label,
      shareType: ShareType.publicLink,
      shareMode: shareMode,
      snapshotBinding: snapshotBinding,
      fileName: fileName,
      contentType: contentType,
    );

    // Create the payload for the URL fragment
    final payload = PublicLinkPayload(
      token: token,
      linkSecretKey: linkKeyPair.privateKey,
      bucket: bucket,
      key: pathScope,
      label: label,
    );

    // Build the URL
    final baseUrl = gatewayBaseUrl ?? kShareGatewayBaseUrl;
    final url = '$baseUrl/view/${token.id}#${payload.encode()}';

    // Save outgoing share (with the link secret key for potential regeneration)
    final outgoingShare = OutgoingShare(
      token: token,
      recipientName: 'Anyone with link',
      linkSecretKey: linkKeyPair.privateKey,
    );
    await _saveOutgoingShare(outgoingShare);

    return GeneratedShareLink(
      url: url,
      token: token,
      outgoingShare: outgoingShare,
      payload: payload,
    );
  }

  /// Create a password-protected link
  ///
  /// Similar to public link, but the fragment payload is encrypted with
  /// a key derived from the password. Anyone with both the link AND the
  /// password can access the file.
  ///
  /// Security: Adds an extra layer - even if link is intercepted,
  /// password is still required to decrypt.
  Future<GeneratedShareLink> createPasswordProtectedLink({
    required String pathScope,
    required String bucket,
    required Uint8List dek,
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

    // Generate a disposable keypair for this link
    final linkKeyPair = await EncryptionService.instance.generateKeyPair();

    // Create share token with the disposable public key as recipient
    final token = await createShare(
      pathScope: pathScope,
      bucket: bucket,
      recipientPublicKey: linkKeyPair.publicKey,
      dek: dek,
      permissions: SharePermissions.readOnly,
      expiryDays: expiryDays,
      label: label,
      shareType: ShareType.passwordProtected,
      shareMode: shareMode,
      snapshotBinding: snapshotBinding,
      fileName: fileName,
      contentType: contentType,
    );

    // Create the inner payload (unencrypted data)
    final innerPayload = PublicLinkPayload(
      token: token,
      linkSecretKey: linkKeyPair.privateKey,
      bucket: bucket,
      key: pathScope,
      label: label,
      isPasswordProtected: true,
    );

    // Encrypt the payload with password-derived key
    final salt = EncryptionService.instance.generateSalt(16);
    final passwordKey = await EncryptionService.instance.deriveKeyFromPassword(
      password,
      salt,
    );

    final innerPayloadBytes = utf8.encode(jsonEncode(innerPayload.toJson()));
    final encryptedPayload = await EncryptionService.instance.encrypt(
      Uint8List.fromList(innerPayloadBytes),
      passwordKey,
    );

    // Create outer wrapper with salt and encrypted inner payload
    final outerPayload = {
      'v': PublicLinkPayload.currentVersion,
      'p': true, // password protected flag
      's': base64Encode(salt),
      'e': base64Encode(encryptedPayload),
    };

    // Encode outer payload for URL
    final fragment = base64UrlEncode(utf8.encode(jsonEncode(outerPayload)));

    // Build the URL
    final baseUrl = gatewayBaseUrl ?? kShareGatewayBaseUrl;
    final url = '$baseUrl/view/${token.id}#$fragment';

    // Save outgoing share with the encrypted fragment for regeneration
    final outgoingShare = OutgoingShare(
      token: token,
      recipientName: 'Password Protected',
      linkSecretKey: linkKeyPair.privateKey,
      passwordSalt: salt,
      encryptedFragment: fragment, // Store to regenerate same URL later
    );
    await _saveOutgoingShare(outgoingShare);

    return GeneratedShareLink(
      url: url,
      token: token,
      outgoingShare: outgoingShare,
      payload: innerPayload,
      password: password,
    );
  }

  /// Decode a password-protected link payload
  ///
  /// Called by the gateway/viewer to decrypt the inner payload
  static Future<PublicLinkPayload> decodePasswordProtectedPayload(
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

    final salt = base64Decode(outerJson['s'] as String);
    final encryptedPayload = base64Decode(outerJson['e'] as String);

    // Derive key from password
    final passwordKey = await EncryptionService.instance.deriveKeyFromPassword(
      password,
      salt,
    );

    // Decrypt inner payload
    try {
      final decryptedBytes = await EncryptionService.instance.decrypt(
        encryptedPayload,
        passwordKey,
      );
      final innerJson = jsonDecode(utf8.decode(decryptedBytes)) as Map<String, dynamic>;
      return PublicLinkPayload.fromJson(innerJson);
    } catch (e) {
      throw SharingException('Invalid password');
    }
  }

  /// Regenerate a public link URL from an existing share
  ///
  /// Useful when user wants to copy the link again
  String regeneratePublicLink(OutgoingShare share, {String? gatewayBaseUrl}) {
    if (share.linkSecretKey == null) {
      throw SharingException('Not a public link share');
    }

    final baseUrl = gatewayBaseUrl ?? kShareGatewayBaseUrl;

    // For password-protected links, use the stored encrypted fragment
    // This ensures we regenerate the exact same URL that was originally created
    if (share.shareType == ShareType.passwordProtected && share.encryptedFragment != null) {
      return '$baseUrl/view/${share.token.id}#${share.encryptedFragment}';
    }

    // For regular public links, encode the payload normally
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
  /// Process:
  /// 1. Verify token is valid (not expired, not revoked)
  /// 2. Unwrap DEK using recipient's private key
  /// 3. Store accepted share for future use
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

    // Get recipient's private key
    final privateKey = await AuthService.instance.getPrivateKey();
    if (privateKey == null) {
      throw SharingException('Private key not available. Please sign in first.');
    }

    // Verify recipient public key matches
    final myPublicKey = await AuthService.instance.getPublicKey();
    if (myPublicKey == null || !_compareKeys(myPublicKey, token.recipientPublicKey)) {
      throw SharingException('This share was not intended for you');
    }

    // Unwrap DEK using recipient's private key and ephemeral public key
    final dek = await EncryptionService.instance.unwrapKeyFromSender(
      token.wrappedDek,
      token.ephemeralPublicKey,
      privateKey,
    );

    final acceptedShare = AcceptedShare(
      token: token,
      dek: dek,
    );

    // Save accepted share
    await _saveAcceptedShare(acceptedShare);

    return acceptedShare;
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

  /// Get DEK for a shared path
  Future<Uint8List?> getDekForPath(String bucket, String path) async {
    final share = await getShareForPath(bucket, path);
    return share?.dek;
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
