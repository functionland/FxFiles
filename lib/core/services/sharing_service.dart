import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/encryption_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';

/// Service for secure file sharing between users
/// 
/// Based on Fula API sharing pattern:
/// - Path-Scoped: Share only specific folders
/// - Time-Limited: Access expires automatically
/// - Permission-Based: Read-only, read-write, or full
/// - Revocable: Cancel access at any time
/// - Zero Knowledge: Server can't read shared content
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
    );
  }

  /// Create and save an outgoing share
  Future<OutgoingShare> shareWithUser({
    required String pathScope,
    required String bucket,
    required Uint8List recipientPublicKey,
    required String recipientName,
    required Uint8List dek,
    SharePermissions permissions = SharePermissions.readOnly,
    int? expiryDays,
    String? label,
  }) async {
    final token = await createShare(
      pathScope: pathScope,
      bucket: bucket,
      recipientPublicKey: recipientPublicKey,
      dek: dek,
      permissions: permissions,
      expiryDays: expiryDays,
      label: label,
    );

    final outgoingShare = OutgoingShare(
      token: token,
      recipientName: recipientName,
    );

    // Save to storage
    await _saveOutgoingShare(outgoingShare);

    return outgoingShare;
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

  /// Generate a shareable link
  String generateShareLink(ShareToken token, {String? baseUrl}) {
    final encoded = token.encode();
    final base = baseUrl ?? 'fxblox://share';
    return '$base/$encoded';
  }

  /// Parse share token from URL
  ShareToken? parseShareLink(String url) {
    try {
      // Handle different URL formats
      String encoded;
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
