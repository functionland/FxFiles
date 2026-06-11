import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/cloud_share_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/share_link_builder.dart';
import 'package:fula_files/web/services/web_tag_service.dart';

/// Which share backend to invoke — mirror of the native ShareChoice in
/// lib/features/sharing/widgets/create_share_dialog.dart (that file is
/// dart:io-tainted, so the web shell carries its own copy of the enum).
enum WebShareChoice { recipient, password, public }

/// A created share: the URL to hand out, the recorded OutgoingShare,
/// and whether the record reached the cloud shares manifest (when
/// false, the link still works but won't appear in the app's Sharing
/// tab until recreated — surfaced as a warning in the result dialog).
class WebShareResult {
  final String url;
  final OutgoingShare share;
  final WebShareChoice choice;
  final bool persisted;

  /// Tag shares: tagged files left OUT of the share (no cloud copy in
  /// the primary bucket) so the owner can be told, native-style.
  final int notIncludedCount;

  const WebShareResult({
    required this.url,
    required this.share,
    required this.choice,
    required this.persisted,
    this.notIncludedCount = 0,
  });

  ShareToken get token => share.token;
}

/// Web-shell share creation. Each method replicates the corresponding
/// native SharingService recipe step-for-step (createPublicLink /
/// createPasswordProtectedLink / createShare+shareWithUser in
/// lib/core/services/sharing_service.dart) — same token construction,
/// same URL builders, same OutgoingShare fields — then records the
/// share in the SAME cloud manifest the native app syncs
/// (CloudShareStorageService), so web-created shares show up in the
/// app's Sharing tab and can be revoked from there.
///
/// Native-only steps intentionally absent: folder-share manifests (web
/// shares single files only for now) and the local Hive share store
/// (the cloud manifest is the web's only record).
class WebShareService {
  WebShareService._();

  static final _uuid = const Uuid();
  static final _random = Random.secure();

  /// Disposable X25519 keypair for link shares; private key rides in
  /// the URL fragment. Same construction as native (Random.secure +
  /// Rust-side public-key derivation, so the keypair is fula-compatible).
  static Future<({Uint8List priv, Uint8List pub})> _disposableKeypair() async {
    final priv = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      priv[i] = _random.nextInt(256);
    }
    final pub = Uint8List.fromList(
      await fula.derivePublicKeyFromSecret(secretKeyBytes: priv.toList()),
    );
    return (priv: priv, pub: pub);
  }

  /// "Anyone with the link" — v2 public link.
  static Future<WebShareResult> createPublicLink({
    required String bucket,
    required String pathScope,
    required String storageKey,
    required int expiryDays,
    String? label,
    ShareMode shareMode = ShareMode.temporal,
    SnapshotBinding? snapshotBinding,
    String? fileName,
    String? contentType,
  }) async {
    final ownerPublicKey = await FulaApiService.instance.getPublicKey();

    final now = DateTime.now();
    final expiresAt = now.add(Duration(days: expiryDays));
    final expiresAtUnix = expiresAt.millisecondsSinceEpoch ~/ 1000;

    final kp = await _disposableKeypair();
    final fulaToken = await FulaApiService.instance.createShareToken(
      bucket,
      storageKey,
      kp.pub,
      shareMode,
      expiresAtUnix,
    );

    final tokenId = _uuid.v4();
    final token = ShareToken(
      id: tokenId,
      fulaShareToken: fulaToken,
      ownerPublicKey: ownerPublicKey,
      recipientPublicKey: kp.pub,
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

    final url = buildPublicShareUrl(
      baseUrl: kShareGatewayBaseUrl,
      tokenId: tokenId,
      fulaToken: fulaToken,
      bucket: bucket,
      pathScope: pathScope,
      storageKey: storageKey,
      linkSecretKey: kp.priv,
      label: label,
      fileName: fileName,
    );

    final share = OutgoingShare(
      token: token,
      recipientName: 'Anyone with link',
      linkSecretKey: kp.priv,
      storageKey: storageKey,
    );

    final persisted = await _persist(share);
    return WebShareResult(
      url: url,
      share: share,
      choice: WebShareChoice.public,
      persisted: persisted,
    );
  }

  /// "Protected link" — password-encrypted v2 payload.
  static Future<WebShareResult> createPasswordProtectedLink({
    required String bucket,
    required String pathScope,
    required String storageKey,
    required int expiryDays,
    required String password,
    String? label,
    ShareMode shareMode = ShareMode.temporal,
    SnapshotBinding? snapshotBinding,
    String? fileName,
    String? contentType,
  }) async {
    if (password.isEmpty) {
      throw StateError('Password cannot be empty');
    }
    final ownerPublicKey = await FulaApiService.instance.getPublicKey();

    final now = DateTime.now();
    final expiresAt = now.add(Duration(days: expiryDays));
    final expiresAtUnix = expiresAt.millisecondsSinceEpoch ~/ 1000;

    final kp = await _disposableKeypair();
    final fulaToken = await FulaApiService.instance.createShareToken(
      bucket,
      storageKey,
      kp.pub,
      shareMode,
      expiresAtUnix,
    );

    final tokenId = _uuid.v4();
    final token = ShareToken(
      id: tokenId,
      fulaShareToken: fulaToken,
      ownerPublicKey: ownerPublicKey,
      recipientPublicKey: kp.pub,
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

    final built = await buildPasswordProtectedShareUrl(
      baseUrl: kShareGatewayBaseUrl,
      tokenId: tokenId,
      fulaToken: fulaToken,
      bucket: bucket,
      pathScope: pathScope,
      storageKey: storageKey,
      linkSecretKey: kp.priv,
      password: password,
      label: label,
      fileName: fileName,
    );

    final share = OutgoingShare(
      token: token,
      recipientName: 'Password Protected',
      linkSecretKey: kp.priv,
      passwordSalt: built.salt,
      encryptedFragment: built.fragment,
      storageKey: storageKey,
    );

    final persisted = await _persist(share);
    return WebShareResult(
      url: built.url,
      share: share,
      choice: WebShareChoice.password,
      persisted: persisted,
    );
  }

  /// "Specific Person" — recipient share against a pasted FULA share
  /// ID. The link is the app deep link (fxblox://share/…), same as the
  /// native flow; only the recipient's app (holding their private key)
  /// can use it.
  static Future<WebShareResult> createRecipientShare({
    required String bucket,
    required String pathScope,
    required String storageKey,
    required String recipientShareId,
    required String recipientName,
    int? expiryDays,
    String? label,
    ShareMode shareMode = ShareMode.temporal,
    SnapshotBinding? snapshotBinding,
    String? fileName,
    String? contentType,
  }) async {
    final recipientPublicKey = decodeFulaShareId(recipientShareId);
    final ownerPublicKey = await FulaApiService.instance.getPublicKey();

    final now = DateTime.now();
    final expiresAt =
        expiryDays != null ? now.add(Duration(days: expiryDays)) : null;
    final expiresAtUnix =
        expiresAt != null ? expiresAt.millisecondsSinceEpoch ~/ 1000 : null;

    final fulaToken = await FulaApiService.instance.createShareToken(
      bucket,
      storageKey,
      recipientPublicKey,
      shareMode,
      expiresAtUnix,
    );

    final token = ShareToken(
      id: _uuid.v4(),
      fulaShareToken: fulaToken,
      ownerPublicKey: ownerPublicKey,
      recipientPublicKey: recipientPublicKey,
      pathScope: pathScope,
      bucket: bucket,
      permissions: SharePermissions.readOnly,
      createdAt: now,
      expiresAt: expiresAt,
      label: label,
      shareType: ShareType.recipient,
      shareMode: shareMode,
      snapshotBinding: snapshotBinding,
      fileName: fileName,
      contentType: contentType,
    );

    final share = OutgoingShare(
      token: token,
      recipientName: recipientName,
    );

    final persisted = await _persist(share);
    return WebShareResult(
      url: buildRecipientShareUrl(token.encode()),
      share: share,
      choice: WebShareChoice.recipient,
      persisted: persisted,
    );
  }

  // ------------------------------------------------------------ tag shares
  //
  // Mirrors of SharingService.createTagPublicLink /
  // createTagPasswordProtectedLink / shareTagWithUser: the outer fula
  // token anchors to the tag's first cloud file, per-file tokens ride
  // in a server-side manifest (PUT /api/share/v2/manifest/<id>,
  // ENC1-encrypted when a link secret exists), and the link payload
  // carries scope:'tag' + folder:true so the portal fetches the
  // manifest. Tag shares are always temporal (a tag has no snapshot).

  /// Per-file `{n, c, s, t}` manifest entries (continues past a failed
  /// token so one bad file doesn't kill the share) — mirror of
  /// SharingService._buildManifestEntries.
  static Future<List<Map<String, dynamic>>> _buildManifestEntries({
    required String bucket,
    required Uint8List publicKeyBytes,
    required int? expiresAtUnix,
    required List<({String displayName, String storageKey, int size})> items,
  }) async {
    final out = <Map<String, dynamic>>[];
    for (final it in items) {
      try {
        final token = await FulaApiService.instance.createShareToken(
          bucket,
          it.storageKey,
          publicKeyBytes,
          ShareMode.temporal,
          expiresAtUnix,
        );
        out.add({
          'n': it.displayName,
          'c': it.storageKey,
          's': it.size,
          't': token,
        });
      } catch (e) {
        debugPrint(
            'WebShareService: manifest token failed for ${it.displayName}: $e');
      }
    }
    return out;
  }

  /// PUT the share manifest (fire-and-forget on native; the web awaits
  /// so the result dialog can warn when the manifest didn't land) —
  /// mirror of SharingService._postManifest.
  static Future<void> _postManifest({
    required String shareId,
    required String bucket,
    required String fulaToken,
    required List<Map<String, dynamic>> folderFiles,
    DateTime? expiresAt,
    Uint8List? linkSecretKey,
  }) async {
    final manifestUrl =
        '$kShareGatewayBaseUrl/api/share/v2/manifest/$shareId';
    String manifestBody;
    if (linkSecretKey != null) {
      final manifest = {
        'bucket': bucket,
        'pathScope': '',
        'tokenJson': fulaToken,
        'files': folderFiles,
        'shareMode': 'temporal',
      };
      final encrypted =
          await shareManifestEncrypt(manifest, linkSecretKey, shareId);
      manifestBody = jsonEncode({
        'encryptedManifest': encrypted,
        'expiresAt': expiresAt?.toIso8601String(),
      });
    } else {
      manifestBody = jsonEncode({
        'bucket': bucket,
        'pathScope': '',
        'tokenJson': fulaToken,
        'files': folderFiles,
        'shareMode': 'temporal',
        'expiresAt': expiresAt?.toIso8601String(),
      });
    }
    final response = await http
        .put(
          Uri.parse(manifestUrl),
          headers: {'Content-Type': 'application/json'},
          body: manifestBody,
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw StateError(
          'Manifest post failed: ${response.statusCode} ${response.body}');
    }
  }

  static Never _noShareableFiles(String tagName) => throw StateError(
      'Tag "$tagName" has no shareable files — newly uploaded files are '
      'shareable; older files must be re-uploaded to share them.');

  /// "Anyone with the link" for a tag.
  static Future<WebShareResult> createTagPublicLink({
    required String tagId,
    required int expiryDays,
    String? label,
  }) async {
    final ownerPublicKey = await FulaApiService.instance.getPublicKey();
    final scope = await WebTagService.instance.resolveTagShareScope(tagId);
    if (scope.items.isEmpty) _noShareableFiles(scope.tag.name);
    final bucket = scope.primaryBucket!;

    final now = DateTime.now();
    final expiresAt = now.add(Duration(days: expiryDays));
    final expiresAtUnix = expiresAt.millisecondsSinceEpoch ~/ 1000;

    final kp = await _disposableKeypair();
    final fulaToken = await FulaApiService.instance.createShareToken(
      bucket,
      scope.items.first.storageKey,
      kp.pub,
      ShareMode.temporal,
      expiresAtUnix,
    );

    final tokenId = _uuid.v4();
    final token = ShareToken(
      id: tokenId,
      fulaShareToken: fulaToken,
      ownerPublicKey: ownerPublicKey,
      recipientPublicKey: kp.pub,
      // pathScope empty so folder checks never misclassify a tag share.
      pathScope: '',
      bucket: bucket,
      permissions: SharePermissions.readOnly,
      createdAt: now,
      expiresAt: expiresAt,
      label: label ?? scope.tag.name,
      shareType: ShareType.publicLink,
      shareMode: ShareMode.temporal,
    );

    final folderFiles = await _buildManifestEntries(
      bucket: bucket,
      publicKeyBytes: kp.pub,
      expiresAtUnix: expiresAtUnix,
      items: scope.items,
    );

    final payloadMap = {
      'v': 2,
      't': fulaToken,
      'b': bucket,
      'k': '',
      'sk': base64Encode(kp.priv),
      if (label != null) 'l': label,
      'scope': 'tag',
      'tagName': scope.tag.name,
      'folder': true,
    };
    final fragment = base64UrlEncode(utf8.encode(jsonEncode(payloadMap)));
    final url = '$kShareGatewayBaseUrl/view/$tokenId#$fragment';

    await _postManifest(
      shareId: tokenId,
      bucket: bucket,
      fulaToken: fulaToken,
      folderFiles: folderFiles,
      expiresAt: expiresAt,
      linkSecretKey: kp.priv,
    );

    final share = OutgoingShare(
      token: token,
      recipientName: 'Anyone with link',
      linkSecretKey: kp.priv,
      tagId: tagId,
    );
    final persisted = await _persist(share);
    return WebShareResult(
      url: url,
      share: share,
      choice: WebShareChoice.public,
      persisted: persisted,
      notIncludedCount: scope.totalCount - scope.items.length,
    );
  }

  /// Password-protected tag link.
  static Future<WebShareResult> createTagPasswordLink({
    required String tagId,
    required int expiryDays,
    required String password,
    String? label,
  }) async {
    if (password.isEmpty) {
      throw StateError('Password cannot be empty');
    }
    final ownerPublicKey = await FulaApiService.instance.getPublicKey();
    final scope = await WebTagService.instance.resolveTagShareScope(tagId);
    if (scope.items.isEmpty) _noShareableFiles(scope.tag.name);
    final bucket = scope.primaryBucket!;

    final now = DateTime.now();
    final expiresAt = now.add(Duration(days: expiryDays));
    final expiresAtUnix = expiresAt.millisecondsSinceEpoch ~/ 1000;

    final kp = await _disposableKeypair();
    final fulaToken = await FulaApiService.instance.createShareToken(
      bucket,
      scope.items.first.storageKey,
      kp.pub,
      ShareMode.temporal,
      expiresAtUnix,
    );

    final tokenId = _uuid.v4();
    final token = ShareToken(
      id: tokenId,
      fulaShareToken: fulaToken,
      ownerPublicKey: ownerPublicKey,
      recipientPublicKey: kp.pub,
      pathScope: '',
      bucket: bucket,
      permissions: SharePermissions.readOnly,
      createdAt: now,
      expiresAt: expiresAt,
      label: label ?? scope.tag.name,
      shareType: ShareType.passwordProtected,
      shareMode: ShareMode.temporal,
    );

    final folderFiles = await _buildManifestEntries(
      bucket: bucket,
      publicKeyBytes: kp.pub,
      expiresAtUnix: expiresAtUnix,
      items: scope.items,
    );

    // Inner payload mirrors the public-tag-link payload, encrypted under
    // the password key; outer envelope is the standard {v,p,s,e,b,k}.
    final innerPayloadMap = {
      'v': 2,
      't': fulaToken,
      'b': bucket,
      'k': '',
      'sk': base64Encode(kp.priv),
      if (label != null) 'l': label,
      'scope': 'tag',
      'tagName': scope.tag.name,
      'folder': true,
    };
    final salt = generateShareSalt(16);
    final passwordKey = await sharePasswordDeriveKey(password, salt);
    final encryptedPayload = await sharePasswordEncrypt(
      Uint8List.fromList(utf8.encode(jsonEncode(innerPayloadMap))),
      passwordKey,
    );
    final outerPayload = {
      'v': 2,
      'p': true,
      's': base64Encode(salt),
      'e': base64Encode(encryptedPayload),
      'b': bucket,
      'k': '',
    };
    final fragment = base64UrlEncode(utf8.encode(jsonEncode(outerPayload)));
    final url = '$kShareGatewayBaseUrl/view/$tokenId#$fragment';

    await _postManifest(
      shareId: tokenId,
      bucket: bucket,
      fulaToken: fulaToken,
      folderFiles: folderFiles,
      expiresAt: expiresAt,
      linkSecretKey: kp.priv,
    );

    final share = OutgoingShare(
      token: token,
      recipientName: 'Password Protected',
      linkSecretKey: kp.priv,
      passwordSalt: salt,
      encryptedFragment: fragment,
      tagId: tagId,
    );
    final persisted = await _persist(share);
    return WebShareResult(
      url: url,
      share: share,
      choice: WebShareChoice.password,
      persisted: persisted,
      notIncludedCount: scope.totalCount - scope.items.length,
    );
  }

  /// Share a tag with a specific recipient (per-file tokens issued to
  /// their key; plaintext manifest — the tokens themselves are
  /// recipient-scoped).
  static Future<WebShareResult> createTagRecipientShare({
    required String tagId,
    required String recipientShareId,
    required String recipientName,
    int? expiryDays,
    String? label,
  }) async {
    final recipientPublicKey = decodeFulaShareId(recipientShareId);
    final ownerPublicKey = await FulaApiService.instance.getPublicKey();
    final scope = await WebTagService.instance.resolveTagShareScope(tagId);
    if (scope.items.isEmpty) _noShareableFiles(scope.tag.name);
    final bucket = scope.primaryBucket!;

    final now = DateTime.now();
    final expiresAt =
        expiryDays != null ? now.add(Duration(days: expiryDays)) : null;
    final expiresAtUnix =
        expiresAt != null ? expiresAt.millisecondsSinceEpoch ~/ 1000 : null;

    final fulaToken = await FulaApiService.instance.createShareToken(
      bucket,
      scope.items.first.storageKey,
      recipientPublicKey,
      ShareMode.temporal,
      expiresAtUnix,
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
      label: label ?? scope.tag.name,
      shareType: ShareType.recipient,
      shareMode: ShareMode.temporal,
    );

    final folderFiles = await _buildManifestEntries(
      bucket: bucket,
      publicKeyBytes: recipientPublicKey,
      expiresAtUnix: expiresAtUnix,
      items: scope.items,
    );

    await _postManifest(
      shareId: tokenId,
      bucket: bucket,
      fulaToken: fulaToken,
      folderFiles: folderFiles,
      expiresAt: expiresAt,
      linkSecretKey: null,
    );

    final share = OutgoingShare(
      token: token,
      recipientName: recipientName,
      tagId: tagId,
    );
    final persisted = await _persist(share);
    return WebShareResult(
      url: buildRecipientShareUrl(token.encode()),
      share: share,
      choice: WebShareChoice.recipient,
      persisted: persisted,
      notIncludedCount: scope.totalCount - scope.items.length,
    );
  }

  /// Record the share in the cloud shares manifest (the one the native
  /// app merges into its Sharing tab): download existing, add (new
  /// wins its id), upload. Best-effort — a failure must not eat a link
  /// whose fula token already exists, so the caller gets `false` and
  /// warns instead.
  static Future<bool> _persist(OutgoingShare share) async {
    try {
      final existing = await CloudShareStorageService.instance.downloadShares();
      final byId = <String, OutgoingShare>{
        for (final s in existing) s.id: s,
      };
      byId[share.id] = share;
      final merged = byId.values.toList()
        ..sort((a, b) => b.sharedAt.compareTo(a.sharedAt));
      await CloudShareStorageService.instance.uploadShares(merged);
      return true;
    } catch (e) {
      debugPrint('WebShareService: share created but not recorded: $e');
      return false;
    }
  }

  // ===========================================================  Shared tab
  // Web counterparts of the SharingService owner/recipient flows the
  // Shared screen needs. Outgoing shares live in the cloud manifest
  // (the web has no Hive copy); accepted shares persist in (web)
  // SecureStorage under the SAME key the native service uses, plus the
  // cloud accepted-shares manifest for cross-device restore.

  static const String _acceptedSharesKey = 'accepted_shares';

  /// Outgoing shares straight from the cloud manifest (newest first).
  static Future<List<OutgoingShare>> listOutgoingShares() async {
    final shares = await CloudShareStorageService.instance.downloadShares();
    shares.sort((a, b) => b.sharedAt.compareTo(a.sharedAt));
    return shares;
  }

  /// Revoke an outgoing share: flip the token in the cloud manifest and
  /// append the id to the monotonic revoked-ids list (mirrors the
  /// native revokeShare + revoked-list propagation).
  static Future<void> revokeShare(String shareId) async {
    final shares = await CloudShareStorageService.instance.downloadShares();
    final index = shares.indexWhere((s) => s.id == shareId);
    if (index == -1) {
      throw StateError('Share not found');
    }
    final share = shares[index];
    shares[index] = OutgoingShare(
      token: share.token.revoke(),
      recipientName: share.recipientName,
      sharedAt: share.sharedAt,
    );
    await CloudShareStorageService.instance.uploadShares(shares);
    final revoked =
        await CloudShareStorageService.instance.downloadRevokedList();
    if (!revoked.contains(shareId)) {
      await CloudShareStorageService.instance
          .uploadRevokedList([...revoked, shareId]);
    }
  }

  /// Delete an outgoing share record from the cloud manifest.
  static Future<void> deleteOutgoingShare(String shareId) async {
    final shares = await CloudShareStorageService.instance.downloadShares();
    shares.removeWhere((s) => s.id == shareId);
    await CloudShareStorageService.instance.uploadShares(shares);
  }

  /// Rebuild the share URL for an outgoing share (native
  /// generateShareLinkFromOutgoing semantics).
  static String shareUrlFor(OutgoingShare share) {
    final token = share.token;
    if (token.shareType == ShareType.passwordProtected &&
        share.encryptedFragment != null) {
      return '$kShareGatewayBaseUrl/view/${token.id}#${share.encryptedFragment}';
    }
    if (token.shareType == ShareType.publicLink &&
        share.linkSecretKey != null) {
      return buildPublicShareUrl(
        baseUrl: kShareGatewayBaseUrl,
        tokenId: token.id,
        fulaToken: token.fulaShareToken ?? '',
        bucket: token.bucket,
        pathScope: token.pathScope,
        storageKey: share.storageKey ?? token.pathScope,
        linkSecretKey: share.linkSecretKey!,
        label: token.label,
        fileName: token.fileName,
      );
    }
    return buildRecipientShareUrl(token.encode());
  }

  // --------------------------------------------------- accepted shares

  static Future<List<AcceptedShare>> listAcceptedShares() async {
    final local = <String, AcceptedShare>{};
    try {
      final json =
          await SecureStorageService.instance.read(_acceptedSharesKey);
      if (json != null) {
        for (final e in (jsonDecode(json) as List)) {
          try {
            final s = AcceptedShare.fromJson(e as Map<String, dynamic>);
            local[s.id] = s;
          } catch (_) {}
        }
      }
    } catch (_) {}
    // Merge the cloud accepted-shares manifest (additive; local wins).
    try {
      for (final s in await CloudShareStorageService.instance
          .downloadAcceptedShares()) {
        local.putIfAbsent(s.id, () => s);
      }
    } catch (_) {}
    final list = local.values.toList()
      ..sort((a, b) => b.acceptedAt.compareTo(a.acceptedAt));
    return list;
  }

  static Future<void> _saveAcceptedShares(List<AcceptedShare> shares) async {
    await SecureStorageService.instance.write(
      _acceptedSharesKey,
      jsonEncode(shares.map((s) => s.toJson()).toList()),
    );
    try {
      await CloudShareStorageService.instance.uploadAcceptedShares(shares);
    } catch (e) {
      debugPrint('WebShareService: accepted-shares cloud sync skipped: $e');
    }
  }

  /// Accept a pasted share link or raw token. Handles fxblox://share/…
  /// deep links, raw encoded tokens and v1 public-link payloads (v2
  /// public/password links open in the share portal, like native).
  static Future<AcceptedShare> acceptFromInput(String input) async {
    final trimmed = input.trim();

    // Public-link payload form (v1 fragments carry the full token).
    if (trimmed.contains('#')) {
      try {
        final fragment = Uri.parse(trimmed).fragment;
        if (fragment.isNotEmpty) {
          final payload = PublicLinkPayload.decode(fragment);
          if (!payload.isPasswordProtected) {
            return acceptShare(payload.token,
                linkSecretKey: payload.linkSecretKey);
          }
        }
      } catch (_) {
        // Not a v1 payload — fall through to the token forms.
      }
    }

    var encoded = trimmed;
    if (encoded.startsWith('fxblox://share/')) {
      encoded = encoded.substring('fxblox://share/'.length);
    }
    final ShareToken token;
    try {
      token = ShareToken.decode(encoded);
    } catch (e) {
      throw StateError('Invalid share link');
    }
    return acceptShare(token);
  }

  /// Mirror of SharingService.acceptShare (validation order, error
  /// strings and persisted fields).
  static Future<AcceptedShare> acceptShare(
    ShareToken token, {
    Uint8List? linkSecretKey,
  }) async {
    if (token.isExpired) {
      throw StateError('Share has expired');
    }
    if (token.isRevoked) {
      throw StateError('Share has been revoked');
    }
    try {
      final revoked =
          await CloudShareStorageService.instance.downloadRevokedList();
      if (revoked.contains(token.id)) {
        throw StateError('Share has been revoked by owner');
      }
    } on StateError {
      rethrow;
    } catch (_) {}

    if (token.shareType == ShareType.recipient) {
      final myPublicKey = await FulaApiService.instance.getPublicKey();
      final mine = myPublicKey;
      final theirs = token.recipientPublicKey;
      var match = mine.length == theirs.length;
      if (match) {
        for (var i = 0; i < mine.length; i++) {
          if (mine[i] != theirs[i]) {
            match = false;
            break;
          }
        }
      }
      if (!match) {
        throw StateError('This share was not intended for you');
      }
    }

    final fulaToken = token.fulaShareToken;
    if (fulaToken == null) {
      throw StateError('Invalid share token format - missing fula token');
    }
    try {
      await FulaApiService.instance.acceptShareToken(fulaToken);
    } catch (e) {
      throw StateError('Failed to validate share token: $e');
    }

    final accepted = AcceptedShare(
      token: token,
      fulaShareToken: fulaToken,
      linkSecretKey: linkSecretKey,
    );
    final shares = await listAcceptedShares();
    await _saveAcceptedShares([accepted, ...shares]);
    return accepted;
  }

  static Future<void> removeAcceptedShare(String shareId) async {
    final shares = await listAcceptedShares();
    shares.removeWhere((s) => s.id == shareId);
    await _saveAcceptedShares(shares);
  }

  /// Download an accepted share's file — mirror of
  /// SharingService.downloadSharedFile: an ephemeral fula client (the
  /// recipient's encryption key) pointed at the share-gateway proxy,
  /// fetching by token in one shot.
  static Future<Uint8List> downloadSharedFile(AcceptedShare share) async {
    final fulaToken = share.fulaShareToken ?? share.token.fulaShareToken;
    if (fulaToken == null) {
      throw StateError('Invalid share - no fula token available');
    }
    final storageKey = share.token.pathScope;

    final kekB64 = await SecureStorageService.instance
        .read(SecureStorageKeys.encryptionKey);
    if (kekB64 == null || kekB64.isEmpty) {
      throw StateError(
          'Cannot download shared file: signed-in user has no encryption '
          'key. Please sign in.');
    }
    final encryptionKey = Uint8List.fromList(base64Decode(kekB64));

    final proxyEndpoint = '$kShareGatewayBaseUrl/api/share/v2/fetch';
    final config = fula.FulaConfig(
      endpoint: proxyEndpoint,
      timeoutSeconds: BigInt.from(120),
      maxRetries: 3,
      perChunkDownloadTimeoutSeconds: BigInt.from(300),
      bufferedDownloadMaxBytes: BigInt.from(256 * 1024 * 1024),
      healthGateEnabled: true,
      healthGateTtlSeconds: BigInt.from(30),
      blockCacheEnabled: false,
      blockCachePath: '',
      blockCacheMaxBytes: BigInt.from(256 * 1024 * 1024),
      gatewayFallbackEnabled: false,
      gatewayFallbackUrls: const [],
      gatewayRaceConcurrency: 3,
      usersIndexChainRpcUrl: '',
      usersIndexAnchorAddress: '',
      usersIndexIpnsName: '',
      usersIndexUserKey: '',
      usersIndexIpnsGatewayUrls: const [],
      usersIndexIpfsGatewayUrls: const [],
      walkableV8WriterEnabled: true,
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
    return fula.getWithToken(
      client: shareClient,
      bucket: share.token.bucket,
      storageKey: storageKey,
      originalKey: storageKey,
      tokenJson: fulaToken,
    );
  }
}
