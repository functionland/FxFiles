import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:fula_files/core/models/collaboration_group.dart';
import 'package:fula_files/core/models/share_token.dart' show ShareMode;
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart' as fula_service;
import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/share_link_builder.dart';
import 'package:fula_files/features/sharing/utils/collab_folder_add.dart';

/// Gateway base URL for collaboration links
const String kCollabGatewayBaseUrl = 'https://cloud.fx.land';

/// Service for managing collaboration groups
///
/// A collaboration group is a named collection of documents that both
/// the creator and receiver can contribute to. Files are shared via
/// a single link, and both parties can add documents.
class CollaborationService {
  static final CollaborationService instance = CollaborationService._();
  CollaborationService._();

  static const String _outgoingCollabsKey = 'outgoing_collaborations';
  static const String _acceptedCollabsKey = 'accepted_collaborations';
  static const String _metadataBucket = 'fula-metadata';
  static const String _collabPrefix = '.fula/collab/';

  /// The bucket the per-group manifest is WRITTEN to (and which the manifest
  /// share-token + link `'b'` bind to): `fula-metadata-v8` once the shared
  /// bucket is v8-managed (legacy forest is gc-damaged), else `fula-metadata`.
  /// Reads MERGE both buckets via `_downloadMergedManifest`. No-op until
  /// `fula-metadata` joins the managed set.
  String get _writeBucket =>
      BucketVersionResolver.writeBucket(_metadataBucket);

  final _uuid = const Uuid();
  final _random = Random.secure();

  /// Rejects any action against an expired collaboration group. Expiry is an
  /// owner-set window (`CollaborationGroup.expiresAt`); once past, all reads
  /// and writes from either side must stop.
  void _assertNotExpired(CollaborationGroup group) {
    if (group.isExpired) {
      throw CollaborationException('Collaboration has expired');
    }
  }

  // ============================================================================
  // COLLABORATION KEY DERIVATION (matching Web Crypto API HKDF)
  // ============================================================================

  /// Derive a per-file encryption key from the link secret and file ID
  ///
  /// Uses HKDF-SHA256 with info="collab-file-v1:{fileId}"
  /// Both Flutter and web portal derive identical keys from same inputs.
  Future<Uint8List> deriveCollabFileKey(Uint8List linkSecret, String fileId) async {
    final hkdf = Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    );
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(linkSecret),
      info: utf8.encode('collab-file-v1:$fileId'),
      nonce: Uint8List(0),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  // The AES-GCM envelope (nonce||ct||mac) and the 'ENC1:' manifest wire
  // format are single-sourced in share_link_builder.dart — the web
  // shell posts the same encrypted tag/folder manifests, so a drifted
  // copy here would produce manifests the portal can't decrypt. These
  // wrappers keep the original call sites unchanged.

  /// Encrypt file bytes with AES-256-GCM using a collab-derived key
  ///
  /// Output format: [12-byte nonce][ciphertext][16-byte tag]
  Future<Uint8List> encryptCollabFile(Uint8List data, Uint8List key) =>
      sharePasswordEncrypt(data, key);

  /// Decrypt file bytes encrypted with collab key
  Future<Uint8List> decryptCollabFile(Uint8List encrypted, Uint8List key) =>
      sharePasswordDecrypt(encrypted, key);

  /// Derive AES-256 key for manifest encryption (domain-separated from file keys)
  Future<Uint8List> _deriveManifestKey(Uint8List linkSecret, String scopeId) =>
      shareManifestDeriveKey(linkSecret, scopeId);

  /// Encrypt manifest JSON → "ENC1:{base64}" wire format
  Future<String> encryptManifestPayload(Map<String, dynamic> manifest,
          Uint8List linkSecret, String scopeId) =>
      shareManifestEncrypt(manifest, linkSecret, scopeId);

  /// Reverse of [encryptManifestPayload]: decrypt an "ENC1:{base64}"
  /// blob back to its JSON map. Returns the original manifest map.
  ///
  /// Used by recipient-side flows that fetch the manifest from
  /// `/api/share/v2/manifest/{shareId}` and need to enumerate files in
  /// the share. Mirrors the parsing logic already in
  /// `_parseManifestData` / `_fetchManifestFromServer`, exposed as a
  /// public API so [ShareFolderSyncService] doesn't need to copy it.
  Future<Map<String, dynamic>> decryptManifestPayload(
    String enc1Blob,
    Uint8List linkSecret,
    String scopeId,
  ) =>
      shareManifestDecrypt(enc1Blob, linkSecret, scopeId);

  // ============================================================================
  // GROUP CREATION & MANAGEMENT
  // ============================================================================

  /// Create a new collaboration group with initial files
  ///
  /// 1. Generates a disposable keypair for the collab link
  /// 2. Creates fula share tokens for each file
  /// 3. Builds and uploads the manifest
  /// 4. Generates the collaboration link
  Future<OutgoingCollaboration> createGroup({
    required String name,
    required List<CollabFileInput> files,
    int expiryDays = 365,
  }) async {
    if (!fula_service.FulaApiService.instance.isConfigured) {
      throw CollaborationException('Cloud storage not configured.');
    }
    final Uint8List ownerPublicKey;
    try {
      ownerPublicKey =
          await fula_service.FulaApiService.instance.getPublicKey();
    } catch (_) {
      throw CollaborationException('Not signed in. Please sign in first.');
    }

    final ownerPublicKeyBase64 = base64Encode(ownerPublicKey);
    final groupId = _uuid.v4();
    final now = DateTime.now();
    final expiresAt = now.add(Duration(days: expiryDays));

    // Generate disposable keypair for the collaboration link
    final privateKeyBytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      privateKeyBytes[i] = _random.nextInt(256);
    }
    final publicKeyBytes = Uint8List.fromList(
      await fula.derivePublicKeyFromSecret(secretKeyBytes: privateKeyBytes.toList()),
    );

    final expiresAtUnix = expiresAt.millisecondsSinceEpoch ~/ 1000;

    // Create share tokens for each file
    final collabFiles = <CollaborationFile>[];
    for (final fileInput in files) {
      final storageKey = await _getStorageKeyForPath(fileInput.bucket, fileInput.pathScope);

      // Create fula share token with the disposable public key
      final fulaToken = await fula_service.FulaApiService.instance.createShareToken(
        fileInput.bucket,
        storageKey,
        publicKeyBytes,
        ShareMode.temporal,
        expiresAtUnix,
      );

      collabFiles.add(CollaborationFile(
        id: _uuid.v4(),
        fileName: fileInput.fileName,
        contentType: fileInput.contentType,
        bucket: fileInput.bucket,
        storageKey: storageKey,
        pathScope: fileInput.pathScope,
        addedByPublicKey: ownerPublicKeyBase64,
        addedAt: now,
        fileSize: fileInput.fileSize,
        encType: 'fula',
        shareTokenJson: fulaToken,
      ));
    }

    final manifestKey = '$_collabPrefix$groupId/manifest.json';

    final group = CollaborationGroup(
      id: groupId,
      name: name,
      ownerPublicKey: ownerPublicKeyBase64,
      manifestBucket: _writeBucket,
      manifestKey: manifestKey,
      createdAt: now,
      expiresAt: expiresAt,
      files: collabFiles,
      version: 1,
      updatedAt: now,
    );

    // Upload manifest (encrypted with link secret key)
    await _uploadManifest(group, linkSecretKey: privateKeyBytes);

    // Create a temporal share token for the manifest itself. The storage-key
    // lookup + the token MUST bind to the SAME bucket the manifest was just
    // written to (_writeBucket), routed HERE at the call site — never inside
    // the dual-use `_getStorageKeyForPath` (which also serves content buckets).
    final manifestStorageKey =
        await _getStorageKeyForPath(_writeBucket, manifestKey);
    final manifestShareToken = await fula_service.FulaApiService.instance.createShareToken(
      _writeBucket,
      manifestStorageKey,
      publicKeyBytes,
      ShareMode.temporal,
      expiresAtUnix,
    );

    // Build the collaboration link
    final payloadMap = {
      'v': 2,
      'type': 'collab',
      'g': groupId,
      't': manifestShareToken,
      'sk': base64Encode(privateKeyBytes),
      'b': _writeBucket,
      'k': manifestKey,
      'n': name,
    };
    final fragment = base64UrlEncode(utf8.encode(jsonEncode(payloadMap)));

    final outgoing = OutgoingCollaboration(
      group: group,
      sharedAt: now,
      linkSecretKey: privateKeyBytes,
      encryptedFragment: fragment,
      manifestShareToken: manifestShareToken,
    );

    await _saveOutgoingCollaboration(outgoing);

    return outgoing;
  }

  /// Add a file from cloud storage to an existing group
  ///
  /// The file must already be synced to cloud. Creates a fula share token
  /// so all group members can decrypt it.
  Future<CollaborationFile> addFileToGroup({
    required String groupId,
    required String pathScope,
    required String bucket,
    required String fileName,
    required int fileSize,
    String? contentType,
  }) async {
    debugPrint('[CollabService] addFileToGroup: groupId=$groupId, bucket=$bucket, pathScope=$pathScope, fileName=$fileName');
    final Uint8List ownerPublicKey;
    try {
      ownerPublicKey =
          await fula_service.FulaApiService.instance.getPublicKey();
    } catch (_) {
      throw CollaborationException('Not signed in.');
    }

    // Find the outgoing collaboration
    final outgoing = await _findOutgoingCollab(groupId);
    if (outgoing == null) {
      debugPrint('[CollabService] Group $groupId not found in local storage');
      throw CollaborationException('Group not found.');
    }
    _assertNotExpired(outgoing.group);
    if (outgoing.linkSecretKey == null) {
      debugPrint('[CollabService] Group $groupId has no linkSecretKey');
      throw CollaborationException('Missing link secret key.');
    }
    debugPrint('[CollabService] Found group "${outgoing.name}", getting storage key...');

    final storageKey = await _getStorageKeyForPath(bucket, pathScope);
    debugPrint('[CollabService] Got storageKey=$storageKey');

    // Derive the disposable public key from the stored secret key
    final publicKeyBytes = Uint8List.fromList(
      await fula.derivePublicKeyFromSecret(secretKeyBytes: outgoing.linkSecretKey!.toList()),
    );
    final expiresAtUnix = outgoing.group.expiresAt != null
        ? outgoing.group.expiresAt!.millisecondsSinceEpoch ~/ 1000
        : null;

    // Create fula share token for the new file
    final fulaToken = await fula_service.FulaApiService.instance.createShareToken(
      bucket,
      storageKey,
      publicKeyBytes,
      ShareMode.temporal,
      expiresAtUnix,
    );

    final collabFile = CollaborationFile(
      id: _uuid.v4(),
      fileName: fileName,
      contentType: contentType,
      bucket: bucket,
      storageKey: storageKey,
      pathScope: pathScope,
      addedByPublicKey: base64Encode(ownerPublicKey),
      addedAt: DateTime.now(),
      fileSize: fileSize,
      encType: 'fula',
      shareTokenJson: fulaToken,
    );

    // Update the manifest
    final updatedGroup = outgoing.group.copyWith(
      files: [...outgoing.group.files, collabFile],
      version: outgoing.group.version + 1,
      updatedAt: DateTime.now(),
    );

    await _uploadManifest(updatedGroup, linkSecretKey: outgoing.linkSecretKey);

    // Update local storage
    final updated = OutgoingCollaboration(
      group: updatedGroup,
      sharedAt: outgoing.sharedAt,
      linkSecretKey: outgoing.linkSecretKey,
      encryptedFragment: outgoing.encryptedFragment,
      manifestShareToken: outgoing.manifestShareToken,
    );
    await _updateOutgoingCollaboration(updated);

    return collabFile;
  }

  /// Add every file under [folderPrefix] in [bucket] to the group (REQ2).
  ///
  /// Enumerates the cloud folder via `listObjects(prefix)` and loops
  /// [addFileToGroup], PRESERVING each object's `pathScope` (its storage key)
  /// so the per-file fula share token binds to the right object. Directories and
  /// the hidden `.fula_keep` folder markers are skipped, as are files already in
  /// the group (idempotent re-add). A per-file failure is non-fatal — it is
  /// counted as skipped and the rest continue.
  ///
  /// [folderPrefix] is a key prefix inside [bucket] (`''` = the whole bucket).
  /// Returns `(added, skipped)`. Each [addFileToGroup] re-publishes the manifest,
  /// so this is O(n) manifest writes — fine for typical folders; a future
  /// optimization could batch a single manifest write.
  Future<({int added, int skipped})> addFolderToGroup({
    required String groupId,
    required String bucket,
    required String folderPrefix,
  }) async {
    final outgoing = await _findOutgoingCollab(groupId);
    if (outgoing == null) {
      throw CollaborationException('Group not found: $groupId');
    }
    _assertNotExpired(outgoing.group);

    final objects = await fula_service.FulaApiService.instance
        .listObjects(bucket, prefix: folderPrefix);

    // pathScopes already in the group at the start → skip (idempotent).
    final existing = outgoing.group.files
        .map((f) => f.pathScope)
        .whereType<String>()
        .toSet();
    final plan = planCollabFolderAdd(objects, existing);

    var added = 0;
    var skipped = plan.skipped;
    for (final obj in plan.toAdd) {
      try {
        await addFileToGroup(
          groupId: groupId,
          pathScope: obj.key,
          bucket: obj.sourceBucket ?? bucket,
          fileName: obj.name,
          fileSize: obj.size,
          contentType: obj.metadata?['content-type'],
        );
        added++;
      } catch (e) {
        debugPrint('[CollabService] addFolderToGroup: skipped ${obj.key}: $e');
        skipped++;
      }
    }
    debugPrint('[CollabService] addFolderToGroup($bucket/$folderPrefix): '
        'added=$added skipped=$skipped');
    return (added: added, skipped: skipped);
  }

  /// Parse manifest data, handling both plaintext JSON and encrypted formats.
  /// Tries JSON first, then decrypts if linkSecretKey is available.
  Future<CollaborationGroup?> _parseManifestData(Uint8List data, String groupId, Uint8List? linkSecretKey) async {
    final text = utf8.decode(data);

    // Try plaintext JSON first (Flutter's _uploadManifest writes plaintext to S3)
    try {
      return CollaborationGroup.fromJson(
        jsonDecode(text) as Map<String, dynamic>,
      );
    } catch (_) {}

    // Try encrypted format (portal writes "ENC1:{base64}" via updateCollabManifest)
    if (linkSecretKey != null && text.startsWith('ENC1:')) {
      try {
        final encoded = text.substring(5);
        final encrypted = base64Decode(encoded);
        final key = await _deriveManifestKey(linkSecretKey, groupId);
        final decrypted = await decryptCollabFile(Uint8List.fromList(encrypted), key);
        return CollaborationGroup.fromJson(
          jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>,
        );
      } catch (e) {
        debugPrint('[CollabService] Failed to decrypt manifest: $e');
      }
    }

    return null;
  }

  /// Read the per-group manifest from BOTH the v8 and legacy S3 buckets and
  /// MERGE them via [CollaborationGroup.mergeWith] (unions files + tombstones,
  /// keeps the security scalars monotonic). Returns null if neither has it.
  /// Non-throwing — a bucket miss/error is swallowed so a transient S3 failure
  /// can't drop the caller's other merge inputs (local + the portal server-DB
  /// manifest). This is what makes the app↔portal manifest fork impossible: an
  /// old-link recipient drives the portal to write LEGACY S3 while the app
  /// writes v8, and merge-both keeps both.
  Future<CollaborationGroup?> _downloadMergedManifest(
    String manifestKey,
    String groupId,
    Uint8List? linkSecretKey,
  ) async {
    List<Uint8List> blobs;
    try {
      blobs = await fula_service.FulaApiService.instance
          .downloadObjectMerged(_metadataBucket, manifestKey);
    } catch (e) {
      debugPrint('[CollabService] S3 manifest merged-download failed: $e');
      return null;
    }
    CollaborationGroup? merged;
    for (final data in blobs) {
      try {
        final parsed = await _parseManifestData(data, groupId, linkSecretKey);
        if (parsed == null) continue;
        merged = merged == null ? parsed : merged.mergeWith(parsed);
      } catch (e) {
        debugPrint('[CollabService] manifest parse/merge skipped: $e');
      }
    }
    return merged;
  }

  /// Fetch manifest from the server DB (manifest-sync endpoint).
  /// This catches updates made by the portal that may not be in S3 yet.
  Future<CollaborationGroup?> _fetchManifestFromServer(String groupId, Uint8List? linkSecretKey) async {
    try {
      final url = '$kCollabGatewayBaseUrl/api/collab/$groupId/manifest-sync';
      final response = await http.get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;

      if (json.containsKey('encryptedManifest') && linkSecretKey != null) {
        final encStr = json['encryptedManifest'] as String;
        if (encStr.startsWith('ENC1:')) {
          final encoded = encStr.substring(5);
          final encrypted = base64Decode(encoded);
          final key = await _deriveManifestKey(linkSecretKey, groupId);
          final decrypted = await decryptCollabFile(Uint8List.fromList(encrypted), key);
          return CollaborationGroup.fromJson(
            jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>,
          );
        }
      } else if (json.containsKey('data')) {
        return CollaborationGroup.fromJson(
          jsonDecode(json['data'] as String) as Map<String, dynamic>,
        );
      }
    } catch (e) {
      debugPrint('[CollabService] Failed to fetch manifest from server: $e');
    }
    return null;
  }

  /// Download a collab file's decrypted bytes.
  ///
  /// For 'collab' encType (portal uploads): fetches from server, decrypts with collab key.
  /// For 'fula' encType (Flutter uploads): downloads from fula S3 via share token.
  Future<Uint8List> downloadCollabFile(String groupId, CollaborationFile file) async {
    // Find the link secret key for decryption
    Uint8List? linkSecretKey;
    final outgoing = await _findOutgoingCollab(groupId);
    CollaborationGroup? group;
    if (outgoing != null) {
      linkSecretKey = outgoing.linkSecretKey;
      group = outgoing.group;
    } else {
      final accepted = await _findAcceptedCollab(groupId);
      linkSecretKey = accepted?.linkSecretKey;
      group = accepted?.group;
    }
    if (group != null) _assertNotExpired(group);

    if (file.encType == 'collab') {
      // Portal-uploaded file: fetch encrypted bytes from server, decrypt with collab key
      final url = '$kCollabGatewayBaseUrl/api/collab/$groupId/file/${file.id}';
      final response = await http.get(Uri.parse(url))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw CollaborationException('Failed to download file: ${response.statusCode}');
      }

      if (linkSecretKey == null) {
        throw CollaborationException('Missing link secret key for decryption');
      }

      final encrypted = Uint8List.fromList(response.bodyBytes);
      final key = await _deriveCollabFileKey(linkSecretKey, file.id);
      return decryptCollabFile(encrypted, key);
    } else {
      // Fula-encrypted file: use fula_client with share token for chunk-aware download + decryption
      if (file.shareTokenJson != null && linkSecretKey != null) {
        // Create a temporary fula_client pointing to the share proxy endpoint.
        // The proxy routes requests to S3 (handles chunked files like cid.chunks/00000000).
        // The fula_client uses linkSecretKey to accept the share token and decrypt the file.
        final proxyEndpoint = '$kCollabGatewayBaseUrl/api/share/v2/fetch';
        final config = fula.FulaConfig(
          endpoint: proxyEndpoint,
          timeoutSeconds: BigInt.from(120),
          maxRetries: 3,
          perChunkDownloadTimeoutSeconds: BigInt.from(300),
          bufferedDownloadMaxBytes: BigInt.from(256 * 1024 * 1024),
          // Share-fetch is an ephemeral, anonymous-ish client created per
          // download against the share proxy. Enable health gate so a
          // proxy outage is detected fast. Block cache stays OFF: share
          // fetches use a different bucket + transient linkSecretKey per
          // share, which doesn't fit the user-scoped offline path.
          // Gateway fallback stays OFF: share tokens are validated by
          // the proxy, raw IPFS gateways can't decrypt them.
          healthGateEnabled: true,
          healthGateTtlSeconds: BigInt.from(30),
          blockCacheEnabled: false,
          blockCachePath: '',
          blockCacheMaxBytes: BigInt.from(256 * 1024 * 1024),
          gatewayFallbackEnabled: false,
          gatewayFallbackUrls: const [],
          gatewayRaceConcurrency: 3,
          // Cold-start does not apply to share-fetch — there is no
          // signed-in user identity to anchor against.
          usersIndexChainRpcUrl: '',
          usersIndexAnchorAddress: '',
          usersIndexIpnsName: '',
          usersIndexUserKey: '',
          usersIndexIpnsGatewayUrls: const [],
          usersIndexIpfsGatewayUrls: const [],
          // Share-fetch reads existing data through the proxy; it never
          // writes a forest manifest. The walkable-v8 writer flag has
          // no observable effect on this code path — set to true to
          // match the cloud client and avoid wire-format drift if a
          // future share-side write ever lands.
          walkableV8WriterEnabled: true,
          // fula_client 0.6.0 E2E plan Phase 5 — empty `Uint8List` is
          // the SDK's "None" sentinel and keeps the legacy plaintext
          // path active (Mode A). This client is an ephemeral share-
          // fetch client (no user-bucket index writes, no signed-entry
          // writes), so leaving both inert is semantically correct.
          encryptedUserBucketsIndexKey: Uint8List(0),
          userEntrySigningSeed: Uint8List(0),
        );
        final encConfig = fula.EncryptionConfig(
          secretKey: linkSecretKey,
          enableMetadataPrivacy: true,
          obfuscationMode: fula.ObfuscationMode.flatNamespace,
        );
        final shareClient = await fula.createEncryptedClient(
          config: config,
          encryption: encConfig,
        );
        return await fula.getWithToken(
          client: shareClient,
          bucket: file.bucket,
          storageKey: file.storageKey,
          // fula-flutter's create_share_token_with_mode sets the token's
          // path_scope to storage_key (the CID), so the prefix check in
          // get_object_with_share only passes when originalKey == storageKey.
          // The web portal does the same: pinning-webui Collab.tsx:174.
          originalKey: file.storageKey,
          tokenJson: file.shareTokenJson!,
        );
      } else {
        throw CollaborationException(
          'Cannot download fula file: missing share token or link secret key',
        );
      }
    }
  }

  /// Derive AES-256 key for a specific collab file (domain-separated by fileId)
  Future<Uint8List> _deriveCollabFileKey(Uint8List linkSecret, String fileId) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(linkSecret),
      info: utf8.encode('collab-file-v1:$fileId'),
      nonce: Uint8List(0),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  /// Refresh a group by re-fetching its manifest from cloud
  ///
  /// Used to see files added by collaborators.
  /// Checks both S3 (Flutter uploads) and server DB (portal uploads).
  Future<CollaborationGroup?> refreshGroup(String groupId) async {
    // Try outgoing first
    final outgoing = await _findOutgoingCollab(groupId);
    if (outgoing != null) {
      _assertNotExpired(outgoing.group);
      try {
        // Source 1: S3 manifest (written by Flutter) — MERGE both v8 + legacy.
        final s3Manifest = await _downloadMergedManifest(
            outgoing.group.manifestKey, groupId, outgoing.linkSecretKey);

        // Source 2: Server DB manifest (written by portal)
        final serverManifest = await _fetchManifestFromServer(groupId, outgoing.linkSecretKey);

        // Merge all sources: local + S3 + server
        var merged = outgoing.group;
        if (s3Manifest != null) merged = merged.mergeWith(s3Manifest);
        if (serverManifest != null) merged = merged.mergeWith(serverManifest);

        final updated = OutgoingCollaboration(
          group: merged,
          sharedAt: outgoing.sharedAt,
          linkSecretKey: outgoing.linkSecretKey,
          encryptedFragment: outgoing.encryptedFragment,
          manifestShareToken: outgoing.manifestShareToken,
          localFolderPath: outgoing.localFolderPath,
          syncEnabled: outgoing.syncEnabled,
        );
        await _updateOutgoingCollaboration(updated);
        return merged;
      } catch (e) {
        debugPrint('CollaborationService: Failed to refresh group $groupId: $e');
        return outgoing.group;
      }
    }

    // Try accepted
    final accepted = await _findAcceptedCollab(groupId);
    if (accepted != null) {
      _assertNotExpired(accepted.group);
      try {
        // Source 1: S3 manifest — MERGE both v8 + legacy.
        final s3Manifest = await _downloadMergedManifest(
            accepted.group.manifestKey, groupId, accepted.linkSecretKey);

        // Source 2: Server DB manifest
        final serverManifest = await _fetchManifestFromServer(groupId, accepted.linkSecretKey);

        // Merge all sources
        var merged = accepted.group;
        if (s3Manifest != null) merged = merged.mergeWith(s3Manifest);
        if (serverManifest != null) merged = merged.mergeWith(serverManifest);

        final updated = AcceptedCollaboration(
          group: merged,
          manifestShareToken: accepted.manifestShareToken,
          linkSecretKey: accepted.linkSecretKey,
          acceptedAt: accepted.acceptedAt,
          localFolderPath: accepted.localFolderPath,
          syncEnabled: accepted.syncEnabled,
        );
        await _updateAcceptedCollaboration(updated);
        return merged;
      } catch (e) {
        debugPrint('CollaborationService: Failed to refresh group $groupId: $e');
        return accepted.group;
      }
    }

    return null;
  }

  // ============================================================================
  // LINK GENERATION & PARSING
  // ============================================================================

  /// Generate (or regenerate) the collaboration link URL
  String generateCollaborationLink(
    OutgoingCollaboration collab, {
    String? gatewayBaseUrl,
  }) {
    final baseUrl = gatewayBaseUrl ?? kCollabGatewayBaseUrl;

    // If we have a stored fragment, reuse it
    if (collab.encryptedFragment != null) {
      return '$baseUrl/collab/${collab.id}#${collab.encryptedFragment}';
    }

    // Rebuild from parts
    if (collab.linkSecretKey == null || collab.manifestShareToken == null) {
      throw CollaborationException('Cannot generate link - missing required data');
    }

    final payloadMap = {
      'v': 2,
      'type': 'collab',
      'g': collab.group.id,
      't': collab.manifestShareToken,
      'sk': base64Encode(collab.linkSecretKey!),
      'b': _writeBucket,
      'k': collab.group.manifestKey,
      'n': collab.group.name,
    };
    final fragment = base64UrlEncode(utf8.encode(jsonEncode(payloadMap)));
    return '$baseUrl/collab/${collab.id}#$fragment';
  }

  /// Check if a URL is a collaboration link
  static bool isCollaborationLink(String url) {
    return url.contains('/collab/');
  }

  /// Parse a collaboration link URL
  ///
  /// Returns the decoded payload or null if the URL is not a valid collab link.
  static Map<String, dynamic>? parseCollaborationLink(String url) {
    try {
      final uri = Uri.parse(url);
      final fragment = uri.fragment;
      if (fragment.isEmpty) return null;

      // Decode base64url fragment
      String normalized = fragment;
      while (normalized.length % 4 != 0) {
        normalized += '=';
      }
      final bytes = base64Url.decode(normalized);
      final payload = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

      if (payload['type'] != 'collab') return null;
      return payload;
    } catch (e) {
      debugPrint('CollaborationService: Failed to parse collab link: $e');
      return null;
    }
  }

  /// Accept a collaboration link and save it locally
  Future<AcceptedCollaboration> acceptCollaboration(String url) async {
    final payload = parseCollaborationLink(url);
    if (payload == null) {
      throw CollaborationException('Invalid collaboration link');
    }

    final groupId = payload['g'] as String;
    final manifestShareToken = payload['t'] as String;
    final secretKeyBase64 = payload['sk'] as String;
    final manifestKey = payload['k'] as String;
    final groupName = payload['n'] as String? ?? 'Untitled';
    final linkSecretKey = base64Decode(secretKeyBase64);

    // Check if already accepted
    final existing = await _findAcceptedCollab(groupId);
    if (existing != null) {
      return existing;
    }

    // Fetch the manifest — MERGE both S3 buckets (v8 + legacy). _parseManifestData
    // (inside the helper) handles plaintext (Flutter) AND ENC1 (portal) formats.
    final fetched = await _downloadMergedManifest(
        manifestKey, groupId, Uint8List.fromList(linkSecretKey));
    final CollaborationGroup group = fetched ??
        CollaborationGroup(
          id: groupId,
          name: groupName,
          ownerPublicKey: '',
          manifestBucket: _writeBucket,
          manifestKey: manifestKey,
          createdAt: DateTime.now(),
          files: [],
          version: 0,
          updatedAt: DateTime.now(),
        );

    final accepted = AcceptedCollaboration(
      group: group,
      manifestShareToken: manifestShareToken,
      linkSecretKey: Uint8List.fromList(linkSecretKey),
    );

    await _saveAcceptedCollaboration(accepted);
    return accepted;
  }

  /// Revoke a collaboration group
  Future<void> revokeGroup(String groupId) async {
    final collabs = await getOutgoingCollaborations();
    final index = collabs.indexWhere((c) => c.id == groupId);
    if (index == -1) {
      throw CollaborationException('Group not found');
    }

    final revoked = OutgoingCollaboration(
      group: collabs[index].group.copyWith(isRevoked: true),
      sharedAt: collabs[index].sharedAt,
      linkSecretKey: collabs[index].linkSecretKey,
      encryptedFragment: collabs[index].encryptedFragment,
      manifestShareToken: collabs[index].manifestShareToken,
    );

    // Upload revoked manifest
    await _uploadManifest(revoked.group, linkSecretKey: collabs[index].linkSecretKey);

    collabs[index] = revoked;
    await _saveOutgoingCollaborations(collabs);
  }

  // ============================================================================
  // STORAGE METHODS (LOCAL)
  // ============================================================================

  Future<List<OutgoingCollaboration>> getOutgoingCollaborations() async {
    final json = await SecureStorageService.instance.read(_outgoingCollabsKey);
    if (json == null) return [];
    try {
      final list = jsonDecode(json) as List;
      return list
          .map((e) => OutgoingCollaboration.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('CollaborationService: Error loading outgoing collabs: $e');
      return [];
    }
  }

  Future<List<AcceptedCollaboration>> getAcceptedCollaborations() async {
    final json = await SecureStorageService.instance.read(_acceptedCollabsKey);
    if (json == null) return [];
    try {
      final list = jsonDecode(json) as List;
      return list
          .map((e) => AcceptedCollaboration.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('CollaborationService: Error loading accepted collabs: $e');
      return [];
    }
  }

  /// Import outgoing collaborations (used for cloud sync restore)
  Future<void> importOutgoingCollaborations(List<OutgoingCollaboration> collabs) async {
    await _saveOutgoingCollaborations(collabs);
  }

  /// Import accepted collaborations (used for cloud sync restore)
  Future<void> importAcceptedCollaborations(List<AcceptedCollaboration> collabs) async {
    await _saveAcceptedCollaborations(collabs);
  }

  Future<void> clearAll() async {
    await SecureStorageService.instance.delete(_outgoingCollabsKey);
    await SecureStorageService.instance.delete(_acceptedCollabsKey);
  }

  // ============================================================================
  // PRIVATE HELPERS
  // ============================================================================

  Future<String> _getStorageKeyForPath(String bucket, String path) async {
    debugPrint('[CollabService] _getStorageKeyForPath: bucket=$bucket, path=$path');

    // Try original path first
    var objects = await fula_service.FulaApiService.instance.listObjects(bucket, prefix: path);
    var match = objects.where((o) => o.key == path).toList();

    // If no match and path starts with "bucket/", strip the prefix and retry
    // (syncState.remotePath includes bucket prefix but keys inside the bucket don't)
    if (match.isEmpty && path.startsWith('$bucket/')) {
      final stripped = path.substring(bucket.length + 1);
      debugPrint('[CollabService] No match with full path, retrying with stripped: $stripped');
      objects = await fula_service.FulaApiService.instance.listObjects(bucket, prefix: stripped);
      match = objects.where((o) => o.key == stripped).toList();
    }

    if (match.isEmpty) {
      debugPrint('[CollabService] listObjects returned ${objects.length} objects but no exact match:');
      for (final o in objects) {
        debugPrint('[CollabService]   key="${o.key}", storageKey=${o.storageKey}, size=${o.size}');
      }
      throw CollaborationException('File not found in bucket "$bucket": $path');
    }

    final storageKey = match.first.storageKey ?? match.first.key;
    debugPrint('[CollabService] Found storageKey=$storageKey');
    return storageKey;
  }

  Future<void> _uploadManifest(CollaborationGroup group, {Uint8List? linkSecretKey}) async {
    await _ensureBucketExists();
    final jsonString = jsonEncode(group.toJson());
    final data = Uint8List.fromList(utf8.encode(jsonString));
    await fula_service.FulaApiService.instance.uploadObject(
      _writeBucket,
      group.manifestKey,
      data,
      contentType: 'application/json',
    );
    debugPrint('CollaborationService: Uploaded manifest for group ${group.id}');

    // Also sync to server so portal can fetch the latest version
    // (fula CID changes on each upload, making the embedded share token stale)
    await _syncManifestToServer(group, linkSecretKey: linkSecretKey);
  }

  /// Push manifest to the server DB (collab_manifests) so the portal AND the
  /// AI-authorize path can find the group. Returns the outcome: best-effort
  /// callers (uploads) ignore it; AI pairing REQUIRES ok and surfaces the error.
  Future<({bool ok, int? statusCode, String? detail})> _syncManifestToServer(
      CollaborationGroup group, {Uint8List? linkSecretKey}) async {
    try {
      final url = '$kCollabGatewayBaseUrl/api/collab/${group.id}/manifest-sync';

      Map<String, dynamic> body;
      if (linkSecretKey != null) {
        final encrypted = await encryptManifestPayload(group.toJson(), linkSecretKey, group.id);
        body = {'encryptedManifest': encrypted};
      } else {
        body = {'data': jsonEncode(group.toJson())};
      }

      final jwt = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);

      final response = await http.put(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          if (jwt != null && jwt.isNotEmpty) 'Authorization': 'Bearer $jwt',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        debugPrint('[CollabService] Manifest synced to server for group ${group.id}');
        return (ok: true, statusCode: 200, detail: null);
      }
      debugPrint('[CollabService] Server manifest sync failed: ${response.statusCode} ${response.body}');
      final b = response.body;
      return (ok: false, statusCode: response.statusCode, detail: b.length > 200 ? b.substring(0, 200) : b);
    } catch (e) {
      debugPrint('[CollabService] Server manifest sync error (non-fatal): $e');
      return (ok: false, statusCode: null, detail: e.toString());
    }
  }

  /// Register (upsert) [groupId]'s manifest on the server DB and REPORT the
  /// outcome — for callers (AI pairing) that must NOT proceed if the group is
  /// not server-registered (the AI-authorize endpoint rejects unknown groups).
  /// Idempotent. On failure returns the server's status + a body snippet so the
  /// caller can surface a precise, diagnosable error instead of a later opaque
  /// "Unknown collab group".
  Future<({bool ok, int? statusCode, String? detail})> syncGroupToServerChecked(
      String groupId) async {
    final outgoing = await _findOutgoingCollab(groupId);
    if (outgoing == null) {
      return (ok: false, statusCode: null, detail: 'group not found in local outgoing collaborations');
    }
    return _syncManifestToServer(outgoing.group, linkSecretKey: outgoing.linkSecretKey);
  }

  Future<void> _ensureBucketExists() async {
    try {
      final exists = await fula_service.FulaApiService.instance.bucketExists(_writeBucket);
      if (!exists) {
        await fula_service.FulaApiService.instance.createBucket(_writeBucket);
      }
    } catch (e) {
      debugPrint('CollaborationService: Could not ensure bucket exists: $e');
    }
  }

  Future<OutgoingCollaboration?> _findOutgoingCollab(String groupId) async {
    final collabs = await getOutgoingCollaborations();
    try {
      return collabs.firstWhere((c) => c.id == groupId);
    } catch (_) {
      return null;
    }
  }

  Future<AcceptedCollaboration?> _findAcceptedCollab(String groupId) async {
    final collabs = await getAcceptedCollaborations();
    try {
      return collabs.firstWhere((c) => c.id == groupId);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveOutgoingCollaboration(OutgoingCollaboration collab) async {
    final collabs = await getOutgoingCollaborations();
    collabs.add(collab);
    await _saveOutgoingCollaborations(collabs);
  }

  Future<void> _updateOutgoingCollaboration(OutgoingCollaboration collab) async {
    final collabs = await getOutgoingCollaborations();
    final index = collabs.indexWhere((c) => c.id == collab.id);
    if (index >= 0) {
      collabs[index] = collab;
    } else {
      collabs.add(collab);
    }
    await _saveOutgoingCollaborations(collabs);
  }

  Future<void> _saveOutgoingCollaborations(List<OutgoingCollaboration> collabs) async {
    final json = jsonEncode(collabs.map((c) => c.toJson()).toList());
    await SecureStorageService.instance.write(_outgoingCollabsKey, json);
  }

  Future<void> _saveAcceptedCollaboration(AcceptedCollaboration collab) async {
    final collabs = await getAcceptedCollaborations();
    collabs.removeWhere((c) => c.id == collab.id);
    collabs.add(collab);
    await _saveAcceptedCollaborations(collabs);
  }

  Future<void> _updateAcceptedCollaboration(AcceptedCollaboration collab) async {
    final collabs = await getAcceptedCollaborations();
    final index = collabs.indexWhere((c) => c.id == collab.id);
    if (index >= 0) {
      collabs[index] = collab;
    } else {
      collabs.add(collab);
    }
    await _saveAcceptedCollaborations(collabs);
  }

  Future<void> _saveAcceptedCollaborations(List<AcceptedCollaboration> collabs) async {
    final json = jsonEncode(collabs.map((c) => c.toJson()).toList());
    await SecureStorageService.instance.write(_acceptedCollabsKey, json);
  }

  // ============================================================================
  // FOLDER ASSIGNMENT
  // ============================================================================

  /// Update the local folder path and sync state for a collab group
  Future<void> updateFolderAssignment(String groupId, {String? folderPath, bool? syncEnabled}) async {
    final outgoing = await _findOutgoingCollab(groupId);
    if (outgoing != null) {
      final updated = outgoing.copyWith(
        localFolderPath: folderPath ?? outgoing.localFolderPath,
        syncEnabled: syncEnabled ?? outgoing.syncEnabled,
      );
      await _updateOutgoingCollaboration(updated);
      return;
    }

    final accepted = await _findAcceptedCollab(groupId);
    if (accepted != null) {
      final updated = accepted.copyWith(
        localFolderPath: folderPath ?? accepted.localFolderPath,
        syncEnabled: syncEnabled ?? accepted.syncEnabled,
      );
      await _updateAcceptedCollaboration(updated);
      return;
    }

    throw CollaborationException('Group not found: $groupId');
  }

  /// Upload a local file to a collab group using collab encryption.
  ///
  /// Used by CollabFolderSyncService for receiver-side uploads.
  /// Encrypts file with HKDF-derived key, uploads to server, updates manifest.
  Future<CollaborationFile> uploadCollabFileFromLocal({
    required String groupId,
    required String fileName,
    required Uint8List fileData,
    required Uint8List linkSecretKey,
    String? contentType,
    String? pathScope,
  }) async {
    final outgoing = await _findOutgoingCollab(groupId);
    final accepted = await _findAcceptedCollab(groupId);
    final preCheckGroup = outgoing?.group ?? accepted?.group;
    if (preCheckGroup != null) _assertNotExpired(preCheckGroup);

    final fileId = _uuid.v4();

    // Derive per-file key and encrypt
    final key = await deriveCollabFileKey(linkSecretKey, fileId);
    final encrypted = await encryptCollabFile(fileData, key);

    // Upload encrypted blob to server
    final url = Uri.parse('$kCollabGatewayBaseUrl/api/collab/$groupId/upload');
    final jwt = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/octet-stream',
        'x-collab-file-id': fileId,
        if (jwt != null && jwt.isNotEmpty) 'Authorization': 'Bearer $jwt',
      },
      body: encrypted,
    ).timeout(const Duration(minutes: 5));
    if (response.statusCode != 200) {
      throw CollaborationException('Failed to upload file: ${response.statusCode}');
    }

    final result = jsonDecode(response.body) as Map<String, dynamic>;
    String? publicKey;
    try {
      publicKey = base64Encode(
          await fula_service.FulaApiService.instance.getPublicKey());
    } catch (_) {
      publicKey = null;
    }

    final file = CollaborationFile(
      id: fileId,
      fileName: fileName,
      contentType: contentType,
      bucket: result['bucket'] as String? ?? _metadataBucket,
      storageKey: result['storageKey'] as String,
      pathScope: pathScope,
      addedByPublicKey: publicKey ?? 'local-collaborator',
      addedAt: DateTime.now(),
      fileSize: fileData.length,
      encType: 'collab',
    );

    // Update manifest
    CollaborationGroup? group;
    Uint8List? groupLinkKey;

    if (outgoing != null) {
      group = outgoing.group;
      groupLinkKey = outgoing.linkSecretKey;
    } else if (accepted != null) {
      group = accepted.group;
      groupLinkKey = accepted.linkSecretKey;
    }

    if (group != null) {
      final updatedGroup = group.copyWith(
        files: [...group.files, file],
        version: group.version + 1,
        updatedAt: DateTime.now(),
      );
      await _uploadManifest(updatedGroup, linkSecretKey: groupLinkKey);

      if (outgoing != null) {
        await _updateOutgoingCollaboration(outgoing.copyWith(group: updatedGroup));
      } else if (accepted != null) {
        await _updateAcceptedCollaboration(accepted.copyWith(group: updatedGroup));
      }
    }

    return file;
  }

  /// Remove a file from a collaboration group by adding it to the tombstone list.
  ///
  /// Updates the manifest in S3 and server DB. The file entry is removed
  /// from [files] and its ID is added to [removedFileIds] so that
  /// [mergeWith] correctly suppresses it across all manifest sources.
  Future<void> removeFileFromGroup({
    required String groupId,
    required String fileId,
    bool deleteFromStorage = true,
  }) async {
    final outgoing = await _findOutgoingCollab(groupId);
    final accepted = await _findAcceptedCollab(groupId);
    CollaborationGroup? group;
    Uint8List? linkSecretKey;

    if (outgoing != null) {
      group = outgoing.group;
      linkSecretKey = outgoing.linkSecretKey;
    } else if (accepted != null) {
      group = accepted.group;
      linkSecretKey = accepted.linkSecretKey;
    }

    if (group == null) {
      throw CollaborationException('Group not found: $groupId');
    }
    _assertNotExpired(group);

    final updatedFiles = group.files.where((f) => f.id != fileId).toList();
    final updatedTombstones = [...group.removedFileIds, fileId];

    final updatedGroup = group.copyWith(
      files: updatedFiles,
      removedFileIds: updatedTombstones,
      version: group.version + 1,
      updatedAt: DateTime.now(),
    );

    await _uploadManifest(updatedGroup, linkSecretKey: linkSecretKey);

    if (outgoing != null) {
      await _updateOutgoingCollaboration(outgoing.copyWith(group: updatedGroup));
    } else if (accepted != null) {
      await _updateAcceptedCollaboration(accepted.copyWith(group: updatedGroup));
    }

    // Clean up encrypted file blob from S3 (non-fatal on failure)
    if (deleteFromStorage) {
      try {
        final jwt = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
        final url = '$kCollabGatewayBaseUrl/api/collab/$groupId/file/$fileId';
        await http.delete(
          Uri.parse(url),
          headers: {
            if (jwt != null && jwt.isNotEmpty) 'Authorization': 'Bearer $jwt',
          },
        ).timeout(const Duration(seconds: 30));
      } catch (e) {
        debugPrint('[CollabService] S3 file deletion failed (non-fatal): $e');
      }
    }

    debugPrint('[CollabService] Removed file $fileId from group $groupId');
  }
}

/// Input data for a file being added to a collaboration group
class CollabFileInput {
  final String fileName;
  final String pathScope;
  final String bucket;
  final int fileSize;
  final String? contentType;

  const CollabFileInput({
    required this.fileName,
    required this.pathScope,
    required this.bucket,
    required this.fileSize,
    this.contentType,
  });
}

class CollaborationException implements Exception {
  final String message;
  CollaborationException(this.message);

  @override
  String toString() => 'CollaborationException: $message';
}
