import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/cloud_share_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/share_link_builder.dart';

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

  const WebShareResult({
    required this.url,
    required this.share,
    required this.choice,
    required this.persisted,
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
}
