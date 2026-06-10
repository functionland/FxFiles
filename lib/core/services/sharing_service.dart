import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/cloud_sync_mapping_service.dart';
import 'package:fula_files/core/services/file_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart' as fula_service;
import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_files/core/services/collaboration_service.dart';
import 'package:fula_files/core/services/cloud_share_storage_service.dart';
import 'package:fula_files/core/services/media_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/tag_storage_service.dart';

/// Gateway base URL for public share links
const String kShareGatewayBaseUrl = 'https://cloud.fx.land';

/// The bucket a NEW folder / tag / category share targets.
///
/// These shares ENUMERATE a bucket (a folder prefix or a tag's files), so —
/// unlike a single-file share, which carries the file's own bucket — post-v8
/// they must be **v8-native**: list, mint per-file tokens, and freeze against
/// `<base>-v8`, where new (post-gc) writes land. Pre-v8 files in the legacy
/// bucket are simply not enumerated → not shared (re-upload to include them).
///
/// Idempotent — `writeBucket` passes an already-`-v8` bucket through unchanged
/// (it is not a managed base), so feeding it `images-v8` returns `images-v8`,
/// never `images-v8-v8`. Flag-off-safe: `writeBucket` returns the input
/// unchanged when the resolver is disabled, making every call site a
/// byte-for-byte no-op. Top-level + pure so it is unit-testable without a device.
String shareV8Bucket(String bucket) =>
    BucketVersionResolver.writeBucket(bucket);

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

    // For folder prefixes (path ends with '/'), use the first child's storageKey
    if (path.endsWith('/') && objects.isNotEmpty) {
      final firstChild = objects.first;
      debugPrint('SharingService: Folder share - using first child storageKey');
      return firstChild.storageKey ?? firstChild.key;
    }

    final obj = objects.firstWhere(
      (o) => o.key == path,
      orElse: () => throw SharingException('File not found: $path'),
    );
    debugPrint('SharingService: Found file, storageKey=${obj.storageKey}');
    return obj.storageKey ?? obj.key;
  }

  /// v8 UX precheck for a FOLDER share (P8.3). A folder share enumerates only
  /// the v8 bucket, so:
  ///  - if the v8 folder is EMPTY (a purely-pre-v8 folder), refuse with a clear,
  ///    user-facing message — the marker phrase "must be re-uploaded" is what
  ///    `ErrorMessages` keys off to show a friendly note instead of a generic
  ///    "Unable to share".
  ///  - otherwise return how many OLDER (legacy) files in this folder were left
  ///    OUT of the share, so the dialog can tell the owner. 0 when not routed
  ///    (resolver off / unmanaged) or on a (non-fatal) legacy-listing error.
  /// `effBucket` is the already-routed (v8) bucket; `pathScope` ends with '/'.
  Future<int> _folderShareEmptyCheckAndNotIncluded(
      String effBucket, String pathScope) async {
    final v8Objects = (await fula_service.FulaApiService.instance
            .listObjects(effBucket, prefix: pathScope))
        .where((o) => !o.isDirectory)
        .toList();
    if (v8Objects.isEmpty) {
      throw SharingException(
        'No files here can be shared yet — newly uploaded files are shareable; '
        'older files must be re-uploaded to share them.',
      );
    }
    if (!BucketVersionResolver.isV8(effBucket)) return 0; // flag-off / unmanaged
    try {
      final legacy = await fula_service.FulaApiService.instance
          .listObjects(BucketVersionResolver.baseOf(effBucket), prefix: pathScope);
      final v8Keys = v8Objects.map((o) => o.key).toSet();
      final n = legacy
          .where((o) => !o.isDirectory && !v8Keys.contains(o.key))
          .length;
      if (n > 0) {
        debugPrint('SharingService: folder share leaves $n pre-v8 file(s) out '
            'of "$pathScope" (in ${BucketVersionResolver.baseOf(effBucket)})');
      }
      return n;
    } catch (_) {
      return 0; // best-effort count; never block a share on the legacy listing
    }
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

    // v8: a folder/category share enumerates a bucket → target the v8 sibling;
    // a single-file share keeps the caller's bucket. Flag-off ⇒ effBucket==bucket.
    final effBucket = pathScope.endsWith('/') ? shareV8Bucket(bucket) : bucket;

    // v8 (P8.3): a purely-pre-v8 folder gets a clear "re-upload" message.
    if (pathScope.endsWith('/')) {
      await _folderShareEmptyCheckAndNotIncluded(effBucket, pathScope);
    }

    // Get storage key for the path
    final storageKey = await _getStorageKeyForPath(effBucket, pathScope);

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
      effBucket,  // Bucket name (v8 sibling for folder shares)
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
      bucket: effBucket,
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

  // ============================================================================
  // TAG SHARES
  // ============================================================================

  /// Create a public link for a tag.
  ///
  /// The recipient sees the current set of cloud files matching the tag.
  /// As files get tagged/untagged or pending uploads complete, the manifest is
  /// re-published (latest mode — see [updateTagShareManifest]).
  ///
  /// Local-only / iOS-only tagged items are auto-queued for upload. Files that
  /// land in a bucket different from the share's primary bucket are skipped
  /// for v1 (the manifest schema carries a single outer bucket).
  Future<GeneratedShareLink> createTagPublicLink({
    required String tagId,
    required int expiryDays,
    String? label,
    String? gatewayBaseUrl,
  }) async {
    final ownerPublicKey = await AuthService.instance.getPublicKey();
    if (ownerPublicKey == null) {
      throw SharingException('Owner public key not available. Please sign in first.');
    }
    if (!fula_service.FulaApiService.instance.isConfigured) {
      throw SharingException('Fula API not configured. Please connect to cloud storage first.');
    }

    final resolution = await _resolveTagShareScope(tagId);
    if (resolution.items.isEmpty) {
      if (resolution.pendingCount > 0) {
        throw SharingException(
          'No cloud files yet. ${resolution.pendingCount} file(s) are uploading — try again in a moment.',
        );
      }
      throw SharingException('Tag "${resolution.tag.name}" has no shareable '
          'files — older files must be re-uploaded to share them.');
    }

    final bucket = resolution.primaryBucket!;
    final firstStorageKey = resolution.items.first.storageKey;

    final now = DateTime.now();
    final expiresAt = now.add(Duration(days: expiryDays));
    final expiresAtUnix = expiresAt.millisecondsSinceEpoch ~/ 1000;

    // Generate disposable keypair for the link
    final privateKeyBytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      privateKeyBytes[i] = _random.nextInt(256);
    }
    final publicKeyBytes = Uint8List.fromList(
      await fula.derivePublicKeyFromSecret(secretKeyBytes: privateKeyBytes.toList()),
    );

    // Outer fula token. Tag shares have no single file scope, so we anchor the
    // outer token to the first cloud file. The recipient uses per-file tokens
    // from the manifest to actually fetch files; the outer token exists to
    // satisfy the v2 share payload schema.
    final fulaToken = await fula_service.FulaApiService.instance.createShareToken(
      bucket, firstStorageKey, publicKeyBytes, ShareMode.temporal, expiresAtUnix,
    );

    final tokenId = _uuid.v4();
    final token = ShareToken(
      id: tokenId,
      fulaShareToken: fulaToken,
      ownerPublicKey: ownerPublicKey,
      recipientPublicKey: publicKeyBytes,
      // pathScope intentionally empty so existing endsWith('/') checks don't
      // misclassify a tag share as a folder share.
      pathScope: '',
      bucket: bucket,
      permissions: SharePermissions.readOnly,
      createdAt: now,
      expiresAt: expiresAt,
      label: label ?? resolution.tag.name,
      shareType: ShareType.publicLink,
      shareMode: ShareMode.temporal,
    );

    final folderFiles = await _buildManifestEntries(
      bucket: bucket,
      publicKeyBytes: publicKeyBytes,
      shareMode: ShareMode.temporal,
      expiresAtUnix: expiresAtUnix,
      items: resolution.items,
    );

    final payloadMap = {
      'v': 2,
      't': fulaToken,
      'b': bucket,
      'k': '',
      'sk': base64Encode(privateKeyBytes),
      if (label != null) 'l': label,
      'scope': 'tag',
      'tagName': resolution.tag.name,
      // Hint to the portal that the manifest is stored server-side, same as
      // folder shares — the portal already handles `folder: true` this way.
      'folder': true,
    };
    final fragment = base64UrlEncode(utf8.encode(jsonEncode(payloadMap)));

    final baseUrl = gatewayBaseUrl ?? kShareGatewayBaseUrl;
    final url = '$baseUrl/view/$tokenId#$fragment';

    _postManifest(
      baseUrl: baseUrl,
      shareId: tokenId,
      bucket: bucket,
      pathScope: '',
      fulaToken: fulaToken,
      folderFiles: folderFiles,
      shareMode: ShareMode.temporal,
      expiresAt: expiresAt,
      linkSecretKey: privateKeyBytes,
    );

    final outgoingShare = OutgoingShare(
      token: token,
      recipientName: 'Anyone with link',
      linkSecretKey: privateKeyBytes,
      tagId: tagId,
    );
    await _saveOutgoingShare(outgoingShare);

    debugPrint('SharingService.createTagPublicLink: tag "${resolution.tag.name}" '
        '— ${resolution.items.length} cloud, ${resolution.pendingCount} pending, '
        '${resolution.skippedOtherBucket} skipped (other bucket)');

    return GeneratedShareLink(
      url: url,
      token: token,
      outgoingShare: outgoingShare,
      // v8: tagged files NOT in the share (legacy-only / other-category /
      // still-pending) so the owner knows what was left out.
      notIncludedCount: resolution.totalCount - resolution.items.length,
    );
  }

  /// Password-protected variant of [createTagPublicLink]. Same dynamic
  /// manifest behaviour (recipient pulls the manifest from the server, which
  /// re-publishes when files are tagged/untagged), but the inner payload is
  /// encrypted with a password-derived key so anyone who intercepts the URL
  /// still needs the password to decrypt the fula token.
  Future<GeneratedShareLink> createTagPasswordProtectedLink({
    required String tagId,
    required int expiryDays,
    required String password,
    String? label,
    String? gatewayBaseUrl,
  }) async {
    if (password.isEmpty) {
      throw SharingException('Password cannot be empty');
    }

    final ownerPublicKey = await AuthService.instance.getPublicKey();
    if (ownerPublicKey == null) {
      throw SharingException(
          'Owner public key not available. Please sign in first.');
    }
    if (!fula_service.FulaApiService.instance.isConfigured) {
      throw SharingException(
          'Fula API not configured. Please connect to cloud storage first.');
    }

    final resolution = await _resolveTagShareScope(tagId);
    if (resolution.items.isEmpty) {
      if (resolution.pendingCount > 0) {
        throw SharingException(
          'No cloud files yet. ${resolution.pendingCount} file(s) are uploading — try again in a moment.',
        );
      }
      throw SharingException('Tag "${resolution.tag.name}" has no shareable '
          'files — older files must be re-uploaded to share them.');
    }

    final bucket = resolution.primaryBucket!;
    final firstStorageKey = resolution.items.first.storageKey;

    final now = DateTime.now();
    final expiresAt = now.add(Duration(days: expiryDays));
    final expiresAtUnix = expiresAt.millisecondsSinceEpoch ~/ 1000;

    // Disposable keypair for the link — same as the public-link variant.
    final privateKeyBytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      privateKeyBytes[i] = _random.nextInt(256);
    }
    final publicKeyBytes = Uint8List.fromList(
      await fula.derivePublicKeyFromSecret(secretKeyBytes: privateKeyBytes.toList()),
    );

    // Outer fula token anchored to the first cloud file (same rationale as
    // createTagPublicLink — the manifest carries per-file tokens).
    final fulaToken = await fula_service.FulaApiService.instance.createShareToken(
      bucket,
      firstStorageKey,
      publicKeyBytes,
      ShareMode.temporal,
      expiresAtUnix,
    );

    final tokenId = _uuid.v4();
    final token = ShareToken(
      id: tokenId,
      fulaShareToken: fulaToken,
      ownerPublicKey: ownerPublicKey,
      recipientPublicKey: publicKeyBytes,
      pathScope: '',
      bucket: bucket,
      permissions: SharePermissions.readOnly,
      createdAt: now,
      expiresAt: expiresAt,
      label: label ?? resolution.tag.name,
      shareType: ShareType.passwordProtected,
      shareMode: ShareMode.temporal,
    );

    final folderFiles = await _buildManifestEntries(
      bucket: bucket,
      publicKeyBytes: publicKeyBytes,
      shareMode: ShareMode.temporal,
      expiresAtUnix: expiresAtUnix,
      items: resolution.items,
    );

    // Inner payload mirrors the public-tag-link payload but is encrypted
    // below with a password-derived key. Marker `scope: 'tag'` so the portal
    // knows to dispatch to the tag flow after the user supplies the
    // password.
    final innerPayloadMap = {
      'v': 2,
      't': fulaToken,
      'b': bucket,
      'k': '',
      'sk': base64Encode(privateKeyBytes),
      if (label != null) 'l': label,
      'scope': 'tag',
      'tagName': resolution.tag.name,
      'folder': true,
    };

    // Encrypt inner payload using a password-derived key (same approach as
    // createPasswordProtectedLink).
    final salt = _generateSalt(16);
    final passwordKey = await _deriveKeyFromPassword(password, salt);
    final encryptedPayload = await _encrypt(
      Uint8List.fromList(utf8.encode(jsonEncode(innerPayloadMap))),
      passwordKey,
    );

    final outerPayload = {
      'v': 2,
      'p': true, // password-protected flag — the portal prompts before decrypt
      's': base64Encode(salt),
      'e': base64Encode(encryptedPayload),
      'b': bucket,
      'k': '',
    };
    final fragment = base64UrlEncode(utf8.encode(jsonEncode(outerPayload)));

    final baseUrl = gatewayBaseUrl ?? kShareGatewayBaseUrl;
    final url = '$baseUrl/view/$tokenId#$fragment';

    _postManifest(
      baseUrl: baseUrl,
      shareId: tokenId,
      bucket: bucket,
      pathScope: '',
      fulaToken: fulaToken,
      folderFiles: folderFiles,
      shareMode: ShareMode.temporal,
      expiresAt: expiresAt,
      linkSecretKey: privateKeyBytes,
    );

    final outgoingShare = OutgoingShare(
      token: token,
      recipientName: 'Password Protected',
      linkSecretKey: privateKeyBytes,
      passwordSalt: salt,
      encryptedFragment: fragment,
      tagId: tagId,
    );
    await _saveOutgoingShare(outgoingShare);

    debugPrint(
        'SharingService.createTagPasswordProtectedLink: tag "${resolution.tag.name}" '
        '— ${resolution.items.length} cloud, ${resolution.pendingCount} pending');

    return GeneratedShareLink(
      url: url,
      token: token,
      outgoingShare: outgoingShare,
      password: password,
      notIncludedCount: resolution.totalCount - resolution.items.length,
    );
  }

  /// Share a tag with a specific recipient (read-only).
  /// Same dynamic-manifest behavior as [createTagPublicLink], but the per-file
  /// share tokens are issued to [recipientPublicKey] so only that recipient
  /// can decrypt the files.
  Future<OutgoingShare> shareTagWithUser({
    required String tagId,
    required Uint8List recipientPublicKey,
    required String recipientName,
    int? expiryDays,
    String? label,
  }) async {
    final ownerPublicKey = await AuthService.instance.getPublicKey();
    if (ownerPublicKey == null) {
      throw SharingException('Owner public key not available. Please sign in first.');
    }
    if (!fula_service.FulaApiService.instance.isConfigured) {
      throw SharingException('Fula API not configured. Please connect to cloud storage first.');
    }

    final resolution = await _resolveTagShareScope(tagId);
    if (resolution.items.isEmpty) {
      if (resolution.pendingCount > 0) {
        throw SharingException(
          'No cloud files yet. ${resolution.pendingCount} file(s) are uploading — try again in a moment.',
        );
      }
      throw SharingException('Tag "${resolution.tag.name}" has no shareable '
          'files — older files must be re-uploaded to share them.');
    }

    final bucket = resolution.primaryBucket!;
    final firstStorageKey = resolution.items.first.storageKey;

    final now = DateTime.now();
    final expiresAt = expiryDays != null ? now.add(Duration(days: expiryDays)) : null;
    final expiresAtUnix = expiresAt?.millisecondsSinceEpoch != null
        ? expiresAt!.millisecondsSinceEpoch ~/ 1000
        : null;

    // Outer fula token issued to recipient's actual public key.
    final fulaToken = await fula_service.FulaApiService.instance.createShareToken(
      bucket, firstStorageKey, recipientPublicKey, ShareMode.temporal, expiresAtUnix,
    );

    final tokenId = _uuid.v4();
    final token = ShareToken(
      id: tokenId,
      fulaShareToken: fulaToken,
      ownerPublicKey: ownerPublicKey,
      recipientPublicKey: recipientPublicKey,
      pathScope: '',
      bucket: bucket,
      permissions: SharePermissions.readOnly,
      createdAt: now,
      expiresAt: expiresAt,
      label: label ?? resolution.tag.name,
      shareType: ShareType.recipient,
      shareMode: ShareMode.temporal,
    );

    final folderFiles = await _buildManifestEntries(
      bucket: bucket,
      publicKeyBytes: recipientPublicKey,
      shareMode: ShareMode.temporal,
      expiresAtUnix: expiresAtUnix,
      items: resolution.items,
    );

    // Recipient shares post a plaintext manifest (no disposable link key to
    // encrypt with). The per-file fula tokens themselves are recipient-scoped,
    // so anyone fetching them must own the recipient private key.
    _postManifest(
      baseUrl: kShareGatewayBaseUrl,
      shareId: tokenId,
      bucket: bucket,
      pathScope: '',
      fulaToken: fulaToken,
      folderFiles: folderFiles,
      shareMode: ShareMode.temporal,
      expiresAt: expiresAt,
      linkSecretKey: null,
    );

    final outgoingShare = OutgoingShare(
      token: token,
      recipientName: recipientName,
      tagId: tagId,
    );
    await _saveOutgoingShare(outgoingShare);

    debugPrint('SharingService.shareTagWithUser: tag "${resolution.tag.name}" '
        'recipient=$recipientName — ${resolution.items.length} cloud, '
        '${resolution.pendingCount} pending, ${resolution.skippedOtherBucket} skipped');

    return outgoingShare;
  }

  /// Resolve a tag's files into manifest items, decide a primary bucket, and
  /// kick off auto-uploads for any local-only files. The primary bucket is the
  /// one containing the most cloud-synced files in the tag; cloud files in
  /// other buckets are reported as skipped (the folder/tag manifest schema
  /// carries a single outer bucket).
  Future<_TagShareResolution> _resolveTagShareScope(String tagId) async {
    final tag = await TagStorageService.instance.getTag(tagId);
    if (tag == null) {
      throw SharingException('Tag not found: $tagId');
    }

    final taggedFiles = await TagStorageService.instance.getFilesWithTag(tagId);
    await CloudSyncMappingService.instance.ensureLoaded();

    // Each tagged file becomes either a cloud candidate (with a known bucket)
    // or a pending-upload entry.
    final cloudCandidates = <_TagCloudCandidate>[];
    final pending = <TaggedFile>[];
    for (final tf in taggedFiles) {
      // Try to resolve via existing sync mapping first — it's authoritative
      // about which bucket the file ended up in. Falls back to fileName-based
      // category guess only if no mapping exists.
      SyncMapping? mapping;
      if (tf.localPath != null) {
        mapping = CloudSyncMappingService.instance.findByLocalPath(tf.localPath!);
      }
      if (mapping == null && tf.iosAssetId != null) {
        mapping = CloudSyncMappingService.instance.findByIosAssetId(tf.iosAssetId!);
      }

      if (mapping != null) {
        cloudCandidates.add(_TagCloudCandidate(
          remoteKey: mapping.remoteKey,
          // v8: a tag share is v8-native — normalise to the v8 sibling so the
          // primary-bucket vote + the listObjects pass below target it. A
          // legacy-only tagged file maps to the v8 bucket but isn't found in
          // it, so it falls out at the keyToObject lookup = not shared.
          bucket: shareV8Bucket(mapping.bucket),
          fileName: tf.fileName,
        ));
      } else if (tf.remoteKey != null) {
        // Tagged directly with a remoteKey but no mapping (e.g., tagged a
        // file that was uploaded outside this device). Guess bucket from
        // filename extension.
        cloudCandidates.add(_TagCloudCandidate(
          remoteKey: tf.remoteKey!,
          bucket: shareV8Bucket(FileCategory.fromPath(tf.fileName).bucketName),
          fileName: tf.fileName,
        ));
      } else if (tf.localPath != null || tf.iosAssetId != null) {
        pending.add(tf);
      }
    }

    // Determine the primary bucket — the bucket with the most cloud files.
    String? primaryBucket;
    if (cloudCandidates.isNotEmpty) {
      final counts = <String, int>{};
      for (final c in cloudCandidates) {
        counts[c.bucket] = (counts[c.bucket] ?? 0) + 1;
      }
      primaryBucket = counts.entries
          .reduce((a, b) => a.value >= b.value ? a : b)
          .key;
    }

    final inBucket = primaryBucket == null
        ? const <_TagCloudCandidate>[]
        : cloudCandidates.where((c) => c.bucket == primaryBucket).toList();
    final skippedOtherBucket = cloudCandidates.length - inBucket.length;

    // Resolve the actual S3 storage_key (obfuscated CID in FlatNamespace mode)
    // for each cloud candidate. The tagged-file record stores the filename
    // (remoteKey) but fula's createShareToken does head_object on the actual
    // storage_key, so passing the filename would fail with "not found".
    // We do a single listObjects pass on the chosen bucket.
    final keyToObject = <String, FulaObject>{};
    if (primaryBucket != null) {
      try {
        final objects = await fula_service.FulaApiService.instance.listObjects(primaryBucket);
        for (final o in objects) {
          keyToObject[o.key] = o;
        }
      } catch (e) {
        debugPrint('SharingService._resolveTagShareScope: listObjects failed: $e');
      }
    }

    final items = <({String displayName, String storageKey, int size})>[];
    for (final c in inBucket) {
      final obj = keyToObject[c.remoteKey];
      if (obj == null) {
        // Tagged-but-not-in-cloud: file appears in the tag's record but
        // isn't in the bucket right now (deleted from cloud after tagging,
        // or never finished uploading). Skip rather than fail the share.
        debugPrint('SharingService._resolveTagShareScope: skipping ${c.fileName} — not in bucket "${c.bucket}"');
        continue;
      }
      items.add((
        displayName: c.fileName,
        storageKey: obj.storageKey ?? obj.key,
        size: obj.size,
      ));
    }

    // Kick off auto-uploads for pending items. Manifest refresh on upload
    // completion (see SyncService) will pick them up automatically.
    for (final tf in pending) {
      // Fire-and-forget — the share is allowed to publish before uploads
      // finish; updateTagShareManifest re-publishes as uploads land.
      // ignore: discarded_futures
      _kickOffTagAutoUpload(tf);
    }

    return _TagShareResolution(
      tag: tag,
      primaryBucket: primaryBucket,
      items: items,
      totalCount: taggedFiles.length,
      pendingCount: pending.length,
      skippedOtherBucket: skippedOtherBucket,
    );
  }

  /// Queue an upload for a local-only / iOS-only tagged file so it can appear
  /// in the tag share once the upload completes.
  ///
  /// Skips when the source file no longer exists on disk — this happens for
  /// tagged-then-deleted imports (e.g. the user emptied the Imported/ folder).
  /// Without this guard a stale tag membership would queue an upload that
  /// fails repeatedly and eventually pauses the entire upload queue.
  Future<void> _kickOffTagAutoUpload(TaggedFile tf) async {
    try {
      String? uploadPath = tf.localPath;
      String? iosAssetId = tf.iosAssetId;

      if (uploadPath == null && iosAssetId != null && Platform.isIOS) {
        final actual = await MediaService.instance.getOriginalFile(iosAssetId);
        if (actual == null) {
          debugPrint('SharingService: cannot upload iOS asset $iosAssetId — not accessible');
          return;
        }
        uploadPath = actual.path;
      }

      if (uploadPath == null) return;

      // Defensive: skip non-existent files. iOS PhotoKit-resolved paths come
      // from getOriginalFile which already implies existence, but a stored
      // `tf.localPath` may point at a file that was since deleted.
      if (!await File(uploadPath).exists()) {
        debugPrint('SharingService: tag auto-upload skip — file no longer exists: $uploadPath');
        return;
      }

      final category = FileCategory.fromPath(uploadPath);
      await SyncService.instance.queueUpload(
        localPath: uploadPath,
        remoteBucket: category.bucketName,
        remoteKey: tf.fileName,
        iosAssetId: iosAssetId,
      );
    } catch (e) {
      debugPrint('SharingService: tag auto-upload kickoff failed for ${tf.fileName}: $e');
    }
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

    // v8: a folder/category share enumerates a bucket → target the v8 sibling
    // (new shares are v8-native); a single-file share keeps the caller's bucket
    // (the file's own). Flag-off / unmanaged ⇒ effBucket == bucket (no-op).
    final effBucket = pathScope.endsWith('/') ? shareV8Bucket(bucket) : bucket;

    // v8 (P8.3): refuse a purely-pre-v8 folder with a clear message + count the
    // older files left out (for the owner). No-op for single-file shares.
    final notIncludedCount = pathScope.endsWith('/')
        ? await _folderShareEmptyCheckAndNotIncluded(effBucket, pathScope)
        : 0;

    // Get storage key (CID) for the path - needed for file fetching
    debugPrint('SharingService.createPublicLink: bucket=$effBucket, pathScope=$pathScope');
    final storageKey = await _getStorageKeyForPath(effBucket, pathScope);
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
    debugPrint('SharingService.createPublicLink: creating fula share token with bucket=$effBucket, storageKey=$storageKey...');
    String fulaToken;
    try {
      fulaToken = await fula_service.FulaApiService.instance.createShareToken(
        effBucket,  // Bucket name (v8 sibling for folder shares)
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
      bucket: effBucket,
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

    // For folder shares, create per-file share tokens and include manifest
    List<Map<String, dynamic>>? folderFiles;
    if (pathScope.endsWith('/')) {
      final objects = await fula_service.FulaApiService.instance.listObjects(effBucket, prefix: pathScope);
      final fileObjects = objects.where((o) => !o.isDirectory).toList();
      folderFiles = await _buildManifestEntries(
        bucket: effBucket,
        publicKeyBytes: publicKeyBytes,
        shareMode: shareMode,
        expiresAtUnix: expiresAtUnix,
        items: fileObjects.map((obj) => (
          displayName: obj.key.length > pathScope.length
              ? obj.key.substring(pathScope.length)
              : obj.key,
          storageKey: obj.storageKey ?? obj.key,
          size: obj.size,
        )).toList(),
      );
      debugPrint('SharingService.createPublicLink: folder share with ${folderFiles.length} files (per-file tokens)');
    }

    // Build payload with fula token and private key (v2 format)
    // The private key is needed by the recipient to decrypt the share token
    // For folder shares, file manifest is stored server-side (not in URL) to
    // keep URLs short and enable temporal updates. The 'folder' flag tells the
    // portal to fetch the manifest from /api/share/v2/manifest/:shareId.
    final payloadMap = {
      'v': 2,  // Version 2 = fula_client format
      't': fulaToken,
      'b': effBucket,
      'k': pathScope,  // Original path - used for DEK derivation
      'cid': storageKey,  // Storage key/CID - used for fetching file from IPFS
      'sk': base64Encode(privateKeyBytes),  // Secret key for decryption
      if (label != null) 'l': label,
      if (fileName != null) 'f': fileName,
      if (folderFiles != null) 'folder': true,
      // File manifest stored server-side only (not in URL fragment) to avoid
      // URL length limits and to support temporal updates for folder shares.
    };
    final fragment = base64UrlEncode(utf8.encode(jsonEncode(payloadMap)));

    // Build the URL
    final baseUrl = gatewayBaseUrl ?? kShareGatewayBaseUrl;
    final url = '$baseUrl/view/$tokenId#$fragment';

    // Post manifest to server for folder shares (enables temporal updates)
    if (folderFiles != null) {
      _postManifest(
        baseUrl: gatewayBaseUrl ?? kShareGatewayBaseUrl,
        shareId: tokenId,
        bucket: effBucket,
        pathScope: pathScope,
        fulaToken: fulaToken,
        folderFiles: folderFiles,
        shareMode: shareMode,
        expiresAt: expiresAt,
        linkSecretKey: privateKeyBytes,
      );
    }

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
      notIncludedCount: notIncludedCount,
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

    // v8: a folder/category share enumerates a bucket → target the v8 sibling;
    // a single-file share keeps the caller's bucket. Flag-off ⇒ effBucket==bucket.
    final effBucket = pathScope.endsWith('/') ? shareV8Bucket(bucket) : bucket;

    // v8 (P8.3): refuse a purely-pre-v8 folder + count older files left out.
    final notIncludedCount = pathScope.endsWith('/')
        ? await _folderShareEmptyCheckAndNotIncluded(effBucket, pathScope)
        : 0;

    // Get storage key (CID) for the path - needed for file fetching
    final storageKey = await _getStorageKeyForPath(effBucket, pathScope);

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
      effBucket,  // Bucket name (v8 sibling for folder shares)
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
      bucket: effBucket,
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

    // For folder shares, create per-file share tokens and include manifest
    List<Map<String, dynamic>>? folderFiles;
    if (pathScope.endsWith('/')) {
      final objects = await fula_service.FulaApiService.instance.listObjects(effBucket, prefix: pathScope);
      final fileObjects = objects.where((o) => !o.isDirectory).toList();
      folderFiles = await _buildManifestEntries(
        bucket: effBucket,
        publicKeyBytes: publicKeyBytes,
        shareMode: shareMode,
        expiresAtUnix: expiresAtUnix,
        items: fileObjects.map((obj) => (
          displayName: obj.key.length > pathScope.length
              ? obj.key.substring(pathScope.length)
              : obj.key,
          storageKey: obj.storageKey ?? obj.key,
          size: obj.size,
        )).toList(),
      );
    }

    // Build inner payload with fula token and secret key (v2 format)
    // File manifest stored server-side only for folder shares.
    final innerPayloadMap = {
      'v': 2,
      't': fulaToken,
      'b': effBucket,
      'k': pathScope,  // Original path - used for DEK derivation
      'cid': storageKey,  // Storage key/CID - used for fetching file from IPFS
      'sk': base64Encode(privateKeyBytes),  // Secret key for decryption
      if (label != null) 'l': label,
      if (fileName != null) 'f': fileName,
      if (folderFiles != null) 'folder': true,
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
      'b': effBucket,
      'k': pathScope,
    };

    // Encode outer payload for URL
    final fragment = base64UrlEncode(utf8.encode(jsonEncode(outerPayload)));

    // Build the URL
    final baseUrl = gatewayBaseUrl ?? kShareGatewayBaseUrl;
    final url = '$baseUrl/view/$tokenId#$fragment';

    // Post manifest to server for folder shares (enables temporal updates)
    if (folderFiles != null) {
      _postManifest(
        baseUrl: gatewayBaseUrl ?? kShareGatewayBaseUrl,
        shareId: tokenId,
        bucket: effBucket,
        pathScope: pathScope,
        fulaToken: fulaToken,
        folderFiles: folderFiles,
        shareMode: shareMode,
        expiresAt: expiresAt,
        linkSecretKey: privateKeyBytes,
      );
    }

    // Save outgoing share with the encrypted fragment and storage key for regeneration
    final outgoingShare = OutgoingShare(
      token: token,
      recipientName: 'Password Protected',
      linkSecretKey: privateKeyBytes,  // Store for temporal manifest updates
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
      notIncludedCount: notIncludedCount,
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
      // v8: a NEW share is frozen on the `-v8` sibling while the caller may pass
      // the legacy category (or vice-versa) — match the whole bucket FAMILY so
      // the "is shared" badge finds it regardless. Display-only lookup; the
      // recipient fetch still uses each share's own exact bucket.
      BucketVersionResolver.sameFamily(s.bucket, bucket) &&
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
  ///
  /// [linkSecretKey] — for Type 1/2 shares (public link / password
  /// link), pass the ephemeral private key extracted from the URL
  /// fragment's `sk` field. Persisted on the resulting [AcceptedShare]
  /// so the desktop folder-sync service can decrypt the share manifest
  /// + unwrap per-file tokens cross-account. Null for Type 3.
  Future<AcceptedShare> acceptShare(
    ShareToken token, {
    Uint8List? linkSecretKey,
  }) async {
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
      linkSecretKey: linkSecretKey,
    );

    // Save accepted share
    await _saveAcceptedShare(acceptedShare);

    return acceptedShare;
  }

  /// Download a file using an accepted share.
  ///
  /// ## Why this routes through the share-gateway proxy
  ///
  /// Fixed 2026-05-21 after the cross-mode E2E sweep root-caused the
  /// "cross-account share download fails with NoSuchBucket" bug. The
  /// prior implementation used `FulaApiService.instance` (the main
  /// signed-in client, pointed at `s3.cloud.fx.land`). Master's S3 GET
  /// handler scopes every request by `session.hashed_user_id` from the
  /// JWT (see `fula-cli/src/handlers/object.rs::get_object` —
  /// `state.bucket_manager.open_bucket_for_user(&session.hashed_user_id, ...)`).
  /// When the recipient is a different account from the owner, the
  /// owner's bucket isn't in the recipient's namespace, so master
  /// returns 404 NoSuchBucket. Cross-account plain shares were
  /// architecturally broken; only within-account "share to my other
  /// device" worked.
  ///
  /// Collab already solved this correctly at
  /// `collaboration_service.dart::downloadFile` (lines 425-485) by
  /// building an ephemeral fula_client pointed at
  /// `$kShareGatewayBaseUrl/api/share/v2/fetch` — the pinning-webui
  /// share-aware proxy that validates by share token (not JWT) and
  /// CAN serve cross-namespace fetches. This method now mirrors that
  /// pattern.
  ///
  /// ## What changed vs the old implementation
  ///
  /// 1. **No more `_getStorageKeyForPath` call.** That helper called
  ///    `listObjects(share.bucket, prefix: share.pathScope)` against
  ///    master, which is user-scoped and fails cross-account. The
  ///    `share.pathScope` field IS the storage_key directly — the FFI
  ///    `create_share_token_with_mode` sets `path_scope = storage_key`
  ///    at share-creation time. Skip the lookup, use it directly.
  ///
  /// 2. **Ephemeral client per download.** Built with the recipient's
  ///    encryption key so its KeyManager can unwrap the share token's
  ///    wrapped DEK, then aimed at the share proxy for the actual byte
  ///    fetch. Disposed implicitly when the function returns.
  ///
  /// 3. **`fula.getWithToken` instead of `acceptShareToken` +
  ///    `downloadSharedFile`**. Same SDK call collab uses; accepts the
  ///    token + fetches in one shot.
  ///
  /// ## Scope of this fix
  ///
  /// Validated end-to-end for Type 3 (specific-person) shares across
  /// every (owner_mode, recipient_mode) combination via the production
  /// E2E test `sharing_e2e::share_round_trip_e2e` plus crypto-layer
  /// tests in `cross_mode_sharing_e2e.rs`. Type 1/2 (public link /
  /// password-link) shares wrap to an ephemeral pubkey (not the
  /// recipient's master KEK), so the ephemeral client's `secretKey`
  /// must be the URL-embedded ephemeral private key, not the
  /// signed-in user's encryption key. That flow lives in
  /// `acceptShareFromString` and feeds a different code path; this
  /// method specifically handles the AcceptedShare-from-signed-in-user
  /// case.
  Future<Uint8List> downloadSharedFile(AcceptedShare share) async {
    final fulaToken = share.fulaShareToken ?? share.token.fulaShareToken;
    if (fulaToken == null) {
      throw SharingException('Invalid share - no fula token available');
    }

    // For path_scope == storage_key (the FFI's convention) skip the
    // broken listObjects lookup.
    final storageKey = share.pathScope;

    // Recipient's master KEK is what the share was wrapped to (Type 3
    // recipient-specific). Required to unwrap the DEK inside the
    // ephemeral client via accept_share.
    final encryptionKey = await AuthService.instance.getEncryptionKey();
    if (encryptionKey == null) {
      throw SharingException(
        'Cannot download shared file: signed-in user has no encryption '
        'key. Please sign in.',
      );
    }

    final proxyEndpoint = '$kShareGatewayBaseUrl/api/share/v2/fetch';
    final config = fula.FulaConfig(
      endpoint: proxyEndpoint,
      timeoutSeconds: BigInt.from(120),
      maxRetries: 3,
      perChunkDownloadTimeoutSeconds: BigInt.from(300),
      bufferedDownloadMaxBytes: BigInt.from(256 * 1024 * 1024),
      // Health gate on so a proxy outage surfaces fast.
      healthGateEnabled: true,
      healthGateTtlSeconds: BigInt.from(30),
      // Cache off: share fetches are per-download against a different
      // bucket + per-share secret, doesn't fit the user-scoped offline
      // path.
      blockCacheEnabled: false,
      blockCachePath: '',
      blockCacheMaxBytes: BigInt.from(256 * 1024 * 1024),
      // Gateway fallback off: share tokens are validated by the proxy,
      // raw IPFS gateways can't decrypt them.
      gatewayFallbackEnabled: false,
      gatewayFallbackUrls: const [],
      gatewayRaceConcurrency: 3,
      // Cold-start doesn't apply to ephemeral share-fetch client.
      usersIndexChainRpcUrl: '',
      usersIndexAnchorAddress: '',
      usersIndexIpnsName: '',
      usersIndexUserKey: '',
      usersIndexIpnsGatewayUrls: const [],
      usersIndexIpfsGatewayUrls: const [],
      // Match the cloud client to avoid wire-format drift if a future
      // share-side write ever lands.
      walkableV8WriterEnabled: true,
      // fula_client 0.6.0 E2E plan Phase 5 — empty `Uint8List` is the
      // SDK's "None" sentinel and keeps the legacy plaintext path
      // active (Mode A). This client is an ephemeral share-fetch
      // client (no user-bucket index writes, no signed-entry writes),
      // so leaving both inert is the semantically correct default.
      encryptedUserBucketsIndexKey: Uint8List(0),
      userEntrySigningSeed: Uint8List(0),
    );
    final encConfig = fula.EncryptionConfig(
      secretKey: encryptionKey,
      enableMetadataPrivacy: true,
      obfuscationMode: fula.ObfuscationMode.flatNamespace,
    );
    final shareClient = await fula.createEncryptedClient(
      config: config,
      encryption: encConfig,
    );

    return await fula.getWithToken(
      client: shareClient,
      bucket: share.bucket,
      storageKey: storageKey,
      // The FFI's `create_share_token_with_mode` sets the token's
      // `path_scope = storage_key`, so the SDK's prefix check in
      // `get_object_with_token::is_path_allowed` only passes when
      // `originalKey == storageKey`. The web portal does the same:
      // `pinning-webui Collab.tsx:174`.
      originalKey: storageKey,
      tokenJson: fulaToken,
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

  /// Find a single accepted share by id, or null if not found.
  Future<AcceptedShare?> findAcceptedShare(String shareId) async {
    final shares = await getAcceptedShares();
    for (final s in shares) {
      if (s.token.id == shareId) return s;
    }
    return null;
  }

  /// Assign or update a local sync folder for an accepted share. Mirrors
  /// CollaborationService.updateFolderAssignment so the ShareFolderSyncService
  /// has the same persistence shape to work against. Either or both of
  /// [folderPath] and [syncEnabled] may be supplied. Passing
  /// `folderPath: ''` (empty string) clears the assignment.
  Future<void> updateAcceptedShareFolderAssignment(
    String shareId, {
    String? folderPath,
    bool? syncEnabled,
  }) async {
    final shares = await getAcceptedShares();
    var found = false;
    for (var i = 0; i < shares.length; i++) {
      if (shares[i].token.id != shareId) continue;
      found = true;
      final cleared = folderPath != null && folderPath.isEmpty;
      shares[i] = shares[i].copyWith(
        localFolderPath: cleared ? null : (folderPath ?? shares[i].localFolderPath),
        syncEnabled: syncEnabled ?? shares[i].syncEnabled,
      );
    }
    if (!found) {
      throw SharingException('Accepted share not found: $shareId');
    }
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

  /// Post folder manifest to server (non-blocking, fire-and-forget).
  /// Enables temporal folder shares to be updated without changing the URL.
  /// Note: secretKey is NOT sent — it stays in the URL fragment only (client-side).
  /// Build per-file share-token entries for a manifest. Each entry has the
  /// shape `{n, c, s, t}` shared by folder shares and tag shares (the recipient
  /// portal renders both the same way). Continues on individual token-creation
  /// failure so one bad file doesn't kill the whole manifest.
  Future<List<Map<String, dynamic>>> _buildManifestEntries({
    required String bucket,
    required Uint8List publicKeyBytes,
    required ShareMode shareMode,
    required int? expiresAtUnix,
    required List<({String displayName, String storageKey, int size})> items,
  }) async {
    final out = <Map<String, dynamic>>[];
    for (final it in items) {
      try {
        final token = await fula_service.FulaApiService.instance.createShareToken(
          bucket, it.storageKey, publicKeyBytes, shareMode, expiresAtUnix,
        );
        out.add({
          'n': it.displayName,
          'c': it.storageKey,
          's': it.size,
          't': token,
        });
      } catch (e) {
        debugPrint('SharingService._buildManifestEntries: token failed for ${it.displayName}: $e');
      }
    }
    return out;
  }

  void _postManifest({
    required String baseUrl,
    required String shareId,
    required String bucket,
    required String pathScope,
    required String fulaToken,
    required List<Map<String, dynamic>> folderFiles,
    required ShareMode shareMode,
    DateTime? expiresAt,
    Uint8List? linkSecretKey,
  }) {
    Future(() async {
      try {
        final manifestUrl = '$baseUrl/api/share/v2/manifest/$shareId';
        String manifestBody;

        if (linkSecretKey != null) {
          // Encrypted path: encrypt all metadata into opaque blob
          final manifest = {
            'bucket': bucket,
            'pathScope': pathScope,
            'tokenJson': fulaToken,
            'files': folderFiles,
            'shareMode': shareMode == ShareMode.temporal ? 'temporal' : 'snapshot',
          };
          final encrypted = await CollaborationService.instance
              .encryptManifestPayload(manifest, linkSecretKey, shareId);
          manifestBody = jsonEncode({
            'encryptedManifest': encrypted,
            'expiresAt': expiresAt?.toIso8601String(),
          });
        } else {
          manifestBody = jsonEncode({
            'bucket': bucket,
            'pathScope': pathScope,
            'tokenJson': fulaToken,
            'files': folderFiles,
            'shareMode': shareMode == ShareMode.temporal ? 'temporal' : 'snapshot',
            'expiresAt': expiresAt?.toIso8601String(),
          });
        }

        final response = await http.put(
          Uri.parse(manifestUrl),
          headers: {'Content-Type': 'application/json'},
          body: manifestBody,
        ).timeout(const Duration(seconds: 30));
        if (response.statusCode == 200 || response.statusCode == 201) {
          debugPrint('SharingService: manifest posted for share $shareId');
        } else {
          debugPrint('SharingService: manifest post FAILED for share $shareId: ${response.statusCode} ${response.body}');
        }
      } catch (e) {
        debugPrint('SharingService: manifest post failed (non-fatal): $e');
      }
    });
  }

  /// Update the server manifest for an active temporal folder share.
  /// Called after a new file is uploaded to a folder with an active share.
  /// [uploadedPrefix] is the immediate parent folder of the uploaded file,
  /// but we match any ancestor share (e.g., share "A/" matches upload in "A/sub/").
  Future<void> updateFolderShareManifest(String bucket, String uploadedPrefix) async {
    debugPrint('[ManifestUpdate] START bucket=$bucket, prefix=$uploadedPrefix');
    try {
      final shares = await getActiveOutgoingShares();
      debugPrint('[ManifestUpdate] Found ${shares.length} active shares');

      final matchingShares = shares.where(
        (s) => s.token.shareMode == ShareMode.temporal &&
               s.pathScope.endsWith('/') &&
               s.bucket == bucket &&
               uploadedPrefix.startsWith(s.pathScope),
      ).toList();

      if (matchingShares.isEmpty) {
        debugPrint('[ManifestUpdate] NO matching temporal folder share for bucket=$bucket, prefix=$uploadedPrefix');
        for (final s in shares) {
          debugPrint('[ManifestUpdate]   share: mode=${s.token.shareMode}, pathScope=${s.pathScope}, bucket=${s.bucket}, hasSecretKey=${s.linkSecretKey != null}');
        }
        return;
      }
      final folderShare = matchingShares.first;
      final pathScope = folderShare.pathScope;
      debugPrint('[ManifestUpdate] Matched share id=${folderShare.token.id}, pathScope=$pathScope');

      final privateKeyBytes = folderShare.linkSecretKey;
      if (privateKeyBytes == null) {
        debugPrint('[ManifestUpdate] ABORT: no stored secret key for share ${folderShare.token.id}');
        return;
      }
      if (folderShare.token.fulaShareToken == null) {
        debugPrint('[ManifestUpdate] ABORT: no fula token for share ${folderShare.token.id}');
        return;
      }

      debugPrint('[ManifestUpdate] Listing objects in bucket=$bucket, prefix=$pathScope...');
      final objects = await fula_service.FulaApiService.instance.listObjects(bucket, prefix: pathScope);
      final fileObjects = objects.where((o) => !o.isDirectory).toList();
      debugPrint('[ManifestUpdate] Found ${fileObjects.length} files');

      final publicKeyBytes = Uint8List.fromList(
        await fula.derivePublicKeyFromSecret(secretKeyBytes: privateKeyBytes.toList()),
      );
      final expiresAtUnix = folderShare.token.expiresAt != null
          ? folderShare.token.expiresAt!.millisecondsSinceEpoch ~/ 1000
          : 0;

      final folderFiles = await _buildManifestEntries(
        bucket: bucket,
        publicKeyBytes: publicKeyBytes,
        shareMode: ShareMode.temporal,
        expiresAtUnix: expiresAtUnix,
        items: fileObjects.map((obj) => (
          displayName: obj.key.length > pathScope.length
              ? obj.key.substring(pathScope.length)
              : obj.key,
          storageKey: obj.storageKey ?? obj.key,
          size: obj.size,
        )).toList(),
      );

      if (folderFiles.isEmpty) {
        debugPrint('[ManifestUpdate] ABORT: no files with valid tokens');
        return;
      }

      final manifestUrl = '$kShareGatewayBaseUrl/api/share/v2/manifest/${folderShare.token.id}';
      debugPrint('[ManifestUpdate] PUTting ${folderFiles.length} files to $manifestUrl...');

      // Encrypt manifest metadata so server stores only opaque blob
      String manifestBody;
      if (privateKeyBytes != null) {
        final manifest = {
          'bucket': bucket,
          'pathScope': pathScope,
          'tokenJson': folderShare.token.fulaShareToken,
          'files': folderFiles,
          'shareMode': 'temporal',
        };
        final encrypted = await CollaborationService.instance
            .encryptManifestPayload(manifest, privateKeyBytes, folderShare.token.id);
        manifestBody = jsonEncode({
          'encryptedManifest': encrypted,
          'expiresAt': folderShare.token.expiresAt?.toIso8601String(),
        });
      } else {
        manifestBody = jsonEncode({
          'bucket': bucket,
          'pathScope': pathScope,
          'tokenJson': folderShare.token.fulaShareToken,
          'files': folderFiles,
          'shareMode': 'temporal',
          'expiresAt': folderShare.token.expiresAt?.toIso8601String(),
        });
      }

      final response = await http.put(
        Uri.parse(manifestUrl),
        headers: {'Content-Type': 'application/json'},
        body: manifestBody,
      ).timeout(const Duration(seconds: 30));
      debugPrint('[ManifestUpdate] PUT response: ${response.statusCode}');
    } catch (e, stack) {
      debugPrint('[ManifestUpdate] EXCEPTION: $e');
      debugPrint('[ManifestUpdate] Stack: $stack');
    }
  }

  /// Re-publish the server manifest for every active temporal share targeting
  /// the given [tagId]. Called (debounced) from SyncService when a file is
  /// tagged/untagged with this tag, when a queued upload completes, and from
  /// the periodic / app-start sweep ([refreshAllTagShares]).
  ///
  /// If the tag has no shareable cloud files (every member untagged, or all
  /// pending upload), an empty manifest is still pushed so the recipient
  /// stops seeing the previous file set. Otherwise an untag would leave the
  /// recipient looking at stale data — a real privacy regression because the
  /// user's visible action ("remove this tag") wouldn't change access.
  Future<void> updateTagShareManifest(String tagId) async {
    debugPrint('[TagManifestUpdate] START tagId=$tagId');
    try {
      final shares = await getActiveOutgoingShares();
      final matching = shares.where(
        (s) => s.tagId == tagId && s.token.shareMode == ShareMode.temporal,
      ).toList();
      if (matching.isEmpty) {
        debugPrint('[TagManifestUpdate] no active tag shares for $tagId');
        return;
      }

      // Resolve the tag once — all shares of the same tag share scope.
      final resolution = await _resolveTagShareScope(tagId);

      for (final share in matching) {
        final fulaToken = share.token.fulaShareToken;
        if (fulaToken == null) {
          debugPrint('[TagManifestUpdate] ABORT share ${share.token.id}: no fula token');
          continue;
        }

        // For public-link tag shares the linkSecretKey is required to
        // re-derive the disposable public key (per-file tokens must keep
        // accepting the same recipient identity across refreshes).
        // For recipient shares we reuse the recipient's public key directly.
        Uint8List publicKeyBytes;
        if (share.token.shareType == ShareType.publicLink) {
          final privateKeyBytes = share.linkSecretKey;
          if (privateKeyBytes == null) {
            debugPrint('[TagManifestUpdate] ABORT share ${share.token.id}: no link secret key');
            continue;
          }
          publicKeyBytes = Uint8List.fromList(
            await fula.derivePublicKeyFromSecret(secretKeyBytes: privateKeyBytes.toList()),
          );
        } else {
          publicKeyBytes = share.token.recipientPublicKey;
        }

        final expiresAtUnix = share.token.expiresAt != null
            ? share.token.expiresAt!.millisecondsSinceEpoch ~/ 1000
            : 0;

        // Keep the original share's bucket label when the tag has no current
        // cloud files — the manifest goes out empty but with a consistent
        // bucket field so the wire format stays valid.
        final bucket = resolution.primaryBucket ?? share.bucket;
        final folderFiles = resolution.items.isEmpty
            ? const <Map<String, dynamic>>[]
            : await _buildManifestEntries(
                bucket: bucket,
                publicKeyBytes: publicKeyBytes,
                shareMode: ShareMode.temporal,
                expiresAtUnix: expiresAtUnix,
                items: resolution.items,
              );

        _postManifest(
          baseUrl: kShareGatewayBaseUrl,
          shareId: share.token.id,
          bucket: bucket,
          pathScope: '',
          fulaToken: fulaToken,
          folderFiles: folderFiles,
          shareMode: ShareMode.temporal,
          expiresAt: share.token.expiresAt,
          linkSecretKey: share.linkSecretKey,
        );

        debugPrint('[TagManifestUpdate] re-published share ${share.token.id} '
            'with ${folderFiles.length} files');
      }
    } catch (e, stack) {
      debugPrint('[TagManifestUpdate] EXCEPTION: $e');
      debugPrint('[TagManifestUpdate] Stack: $stack');
    }
  }

  /// Re-publish manifests for every active temporal tag share. Invoked once
  /// on app start and periodically thereafter to catch tag-membership changes
  /// that originated outside this device (e.g., another device or webui).
  Future<void> refreshAllTagShares() async {
    try {
      final shares = await getActiveOutgoingShares();
      final tagIds = shares
          .where((s) => s.tagId != null && s.token.shareMode == ShareMode.temporal)
          .map((s) => s.tagId!)
          .toSet();
      if (tagIds.isEmpty) return;

      debugPrint('SharingService.refreshAllTagShares: sweeping ${tagIds.length} tag(s)');
      for (final tagId in tagIds) {
        await updateTagShareManifest(tagId);
      }
    } catch (e) {
      debugPrint('SharingService.refreshAllTagShares: $e');
    }
  }

  /// Whether [remoteKey] is included in any active tag share. Cheap lookup
  /// used by SyncService after a successful upload to know which tag shares
  /// need a manifest refresh.
  Future<Set<String>> activeTagSharesContaining({
    required String bucket,
    required String remoteKey,
  }) async {
    final shares = await getActiveOutgoingShares();
    final tagShares = shares.where(
      (s) => s.tagId != null && s.token.shareMode == ShareMode.temporal,
    ).toList();
    if (tagShares.isEmpty) return const {};

    final tagIds = tagShares.map((s) => s.tagId!).toSet();
    final hit = <String>{};
    await CloudSyncMappingService.instance.ensureLoaded();
    for (final tagId in tagIds) {
      final taggedFiles = await TagStorageService.instance.getFilesWithTag(tagId);
      for (final tf in taggedFiles) {
        // Match by direct remoteKey or by mapping resolution.
        if (tf.remoteKey == remoteKey) {
          hit.add(tagId);
          break;
        }
        SyncMapping? mapping;
        if (tf.localPath != null) {
          mapping = CloudSyncMappingService.instance.findByLocalPath(tf.localPath!);
        }
        if (mapping == null && tf.iosAssetId != null) {
          mapping = CloudSyncMappingService.instance.findByIosAssetId(tf.iosAssetId!);
        }
        if (mapping != null && mapping.remoteKey == remoteKey && mapping.bucket == bucket) {
          hit.add(tagId);
          break;
        }
      }
    }
    return hit;
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
      // Propagate the revocation to cloud so other devices restoring from
      // cloud also honour it. Best-effort — network failures stay local.
      unawaited(CloudShareStorageService.instance
          .uploadRevokedList(revokedIds));
    }
  }

  /// Merge a cloud-sourced revoked ID list into local storage. Used on
  /// restore so that revokes made on another device are respected here.
  Future<void> importRevokedShareIds(List<String> cloudIds) async {
    if (cloudIds.isEmpty) return;
    final local = await _getRevokedShareIds();
    final merged = {...local, ...cloudIds}.toList();
    if (merged.length == local.length) return;
    await SecureStorageService.instance.write(
      _revokedSharesKey,
      jsonEncode(merged),
    );
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

  /// Import accepted shares (used for cloud sync restore)
  Future<void> importAcceptedShares(List<AcceptedShare> shares) async {
    await _saveAcceptedShares(shares);
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

/// Internal: one cloud-resolved candidate file in a tag share.
class _TagCloudCandidate {
  final String remoteKey;
  final String bucket;
  final String fileName;

  _TagCloudCandidate({
    required this.remoteKey,
    required this.bucket,
    required this.fileName,
  });
}

/// Internal: the result of resolving a tag into shareable items.
/// Used by tag share creation and manifest refresh paths.
class _TagShareResolution {
  final FileTag tag;
  final String? primaryBucket;
  final List<({String displayName, String storageKey, int size})> items;
  final int totalCount;
  final int pendingCount;
  final int skippedOtherBucket;

  _TagShareResolution({
    required this.tag,
    required this.primaryBucket,
    required this.items,
    required this.totalCount,
    required this.pendingCount,
    required this.skippedOtherBucket,
  });
}
