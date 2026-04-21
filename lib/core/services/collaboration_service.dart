import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:fula_files/core/models/collaboration_group.dart';
import 'package:fula_files/core/models/share_token.dart' show ShareMode;
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart' as fula_service;
import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_files/core/services/secure_storage_service.dart';

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
  static const String _filesBucket = 'files';

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

  /// Encrypt file bytes with AES-256-GCM using a collab-derived key
  ///
  /// Output format: [12-byte nonce][ciphertext][16-byte tag]
  Future<Uint8List> encryptCollabFile(Uint8List data, Uint8List key) async {
    final aesGcm = AesGcm.with256bits();
    final secretKey = SecretKey(key);
    final nonce = aesGcm.newNonce();
    final secretBox = await aesGcm.encrypt(data, secretKey: secretKey, nonce: nonce);
    return Uint8List.fromList([
      ...nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
  }

  /// Decrypt file bytes encrypted with collab key
  Future<Uint8List> decryptCollabFile(Uint8List encrypted, Uint8List key) async {
    final aesGcm = AesGcm.with256bits();
    final nonceLength = aesGcm.nonceLength;
    final macLength = aesGcm.macAlgorithm.macLength;

    final nonce = encrypted.sublist(0, nonceLength);
    final cipherText = encrypted.sublist(nonceLength, encrypted.length - macLength);
    final mac = encrypted.sublist(encrypted.length - macLength);

    final secretKey = SecretKey(key);
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
    final decrypted = await aesGcm.decrypt(secretBox, secretKey: secretKey);
    return Uint8List.fromList(decrypted);
  }

  /// Derive AES-256 key for manifest encryption (domain-separated from file keys)
  Future<Uint8List> _deriveManifestKey(Uint8List linkSecret, String scopeId) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(linkSecret),
      info: utf8.encode('manifest-enc-v1:$scopeId'),
      nonce: Uint8List(0),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  /// Encrypt manifest JSON → "ENC1:{base64}" wire format
  Future<String> encryptManifestPayload(Map<String, dynamic> manifest, Uint8List linkSecret, String scopeId) async {
    final key = await _deriveManifestKey(linkSecret, scopeId);
    final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
    final encrypted = await encryptCollabFile(plaintext, key);
    return 'ENC1:${base64Encode(encrypted)}';
  }

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
    final ownerPublicKey = await AuthService.instance.getPublicKey();
    if (ownerPublicKey == null) {
      throw CollaborationException('Not signed in. Please sign in first.');
    }
    if (!fula_service.FulaApiService.instance.isConfigured) {
      throw CollaborationException('Cloud storage not configured.');
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
      manifestBucket: _metadataBucket,
      manifestKey: manifestKey,
      createdAt: now,
      expiresAt: expiresAt,
      files: collabFiles,
      version: 1,
      updatedAt: now,
    );

    // Upload manifest (encrypted with link secret key)
    await _uploadManifest(group, linkSecretKey: privateKeyBytes);

    // Create a temporal share token for the manifest itself
    final manifestStorageKey = await _getStorageKeyForPath(_metadataBucket, manifestKey);
    final manifestShareToken = await fula_service.FulaApiService.instance.createShareToken(
      _metadataBucket,
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
      'b': _metadataBucket,
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
    final ownerPublicKey = await AuthService.instance.getPublicKey();
    if (ownerPublicKey == null) {
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
        // Source 1: S3 manifest (written by Flutter)
        CollaborationGroup? s3Manifest;
        try {
          final data = await fula_service.FulaApiService.instance.downloadObject(
            _metadataBucket,
            outgoing.group.manifestKey,
          );
          s3Manifest = await _parseManifestData(data, groupId, outgoing.linkSecretKey);
        } catch (e) {
          debugPrint('[CollabService] S3 manifest download failed: $e');
        }

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
        // Source 1: S3 manifest
        CollaborationGroup? s3Manifest;
        try {
          final data = await fula_service.FulaApiService.instance.downloadObject(
            _metadataBucket,
            accepted.group.manifestKey,
          );
          s3Manifest = await _parseManifestData(data, groupId, accepted.linkSecretKey);
        } catch (e) {
          debugPrint('[CollabService] S3 manifest download failed: $e');
        }

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
      'b': _metadataBucket,
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

    // Fetch the manifest
    CollaborationGroup group;
    try {
      final data = await fula_service.FulaApiService.instance.downloadObject(
        _metadataBucket,
        manifestKey,
      );
      group = CollaborationGroup.fromJson(
        jsonDecode(utf8.decode(data)) as Map<String, dynamic>,
      );
    } catch (e) {
      // If we can't fetch the manifest, create a placeholder
      group = CollaborationGroup(
        id: groupId,
        name: groupName,
        ownerPublicKey: '',
        manifestBucket: _metadataBucket,
        manifestKey: manifestKey,
        createdAt: DateTime.now(),
        files: [],
        version: 0,
        updatedAt: DateTime.now(),
      );
    }

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
      _metadataBucket,
      group.manifestKey,
      data,
      contentType: 'application/json',
    );
    debugPrint('CollaborationService: Uploaded manifest for group ${group.id}');

    // Also sync to server so portal can fetch the latest version
    // (fula CID changes on each upload, making the embedded share token stale)
    await _syncManifestToServer(group, linkSecretKey: linkSecretKey);
  }

  /// Push manifest to server for portal access (encrypted if key available)
  Future<void> _syncManifestToServer(CollaborationGroup group, {Uint8List? linkSecretKey}) async {
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
      } else {
        debugPrint('[CollabService] Server manifest sync failed: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      debugPrint('[CollabService] Server manifest sync error (non-fatal): $e');
    }
  }

  Future<void> _ensureBucketExists() async {
    try {
      final exists = await fula_service.FulaApiService.instance.bucketExists(_metadataBucket);
      if (!exists) {
        await fula_service.FulaApiService.instance.createBucket(_metadataBucket);
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
    final publicKey = await AuthService.instance.getPublicKeyString();

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
