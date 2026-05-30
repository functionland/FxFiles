import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import 'package:fula_files/core/models/website_group_pointer.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/ipns_name.dart';
import 'package:fula_files/core/services/ipns_record.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';

/// Manages a stable, app-updatable IPNS pointer per website group, so a link
/// the user shares once keeps resolving to the group's latest generation even
/// after regeneration — and keeps working even if fx's own servers are down.
/// Name -> CID resolution goes through the Cloudflare Worker reading w3name
/// (both non-fx); the content is then fetched from public IPFS gateways. A bare
/// `{name}.ipns.dweb.link` does NOT resolve until the record is also published
/// to the IPFS DHT (w3name doesn't do that) — see cloudflare/README.md.
///
/// Source of truth = IPNS (a per-group Ed25519 keypair the app holds). The
/// pointer is published to the free, no-account **w3name** service and resolved
/// by public gateways; an optional stateless Cloudflare Worker provides a fast,
/// pretty front door over the same IPNS name (see Phase 5).
///
/// Phase 1 (this file): keypair generation, `k51…` name derivation, and local
/// persistence. Signing + publishing the IPNS record to w3name lands in
/// [publishLatest] (Phase 2); pipeline wiring + cloud backup in Phase 3.
class IpnsPointerService {
  IpnsPointerService._();
  static final IpnsPointerService instance = IpnsPointerService._();

  /// Bundled default front-door base (stateless Cloudflare resolver Worker on
  /// the fxfiles.top zone). The IPNS name is appended: `{base}{ipnsName}`.
  /// Overridable via [SecureStorageKeys.websiteLinkWorkerBaseUrl].
  static const String defaultWorkerBase = 'https://fxfiles.top/w/';

  /// Subdomain IPNS gateway template for the name's raw address. `{name}` is the
  /// IPNS name. NOTE: this only resolves once the record is on the IPFS DHT
  /// (w3name doesn't publish there) — the working link is the Worker front door.
  static const String ipnsGatewayTemplate = 'https://{name}.ipns.dweb.link/';

  /// Default IPNS publishing service (free, no account; the app holds the key
  /// and only POSTs the signed record). Overridable via
  /// [SecureStorageKeys.websiteIpnsPublishEndpoint].
  static const String defaultW3nameEndpoint = 'https://name.web3.storage';

  static final Ed25519 _ed25519 = Ed25519();

  /// Cloud backup lives in the same encrypted bucket as website metadata, under
  /// a distinct object key — reusing [FulaApiService]'s encrypted channel as-is
  /// (the encryption code itself is untouched).
  static const String _metadataBucket = 'website-metadata';
  static const Duration _backupDebounce = Duration(seconds: 5);

  Box<WebsiteGroupPointer>? _box;
  bool _isInitialized = false;
  bool _backupScheduled = false;
  bool _restoreAttempted = false;

  bool get isInitialized => _isInitialized;

  /// Open the Hive box and register the adapter. Mirrors the lazy,
  /// non-blocking init pattern used by the other services (see
  /// `WebsiteService.init`).
  Future<void> init() async {
    if (_isInitialized) return;
    try {
      if (!Hive.isAdapterRegistered(28)) {
        Hive.registerAdapter(WebsiteGroupPointerAdapter());
      }
      _box = await Hive.openBox<WebsiteGroupPointer>('website_group_pointers');
      _isInitialized = true;
      debugPrint(
          'IpnsPointerService initialized with ${_box!.length} pointers');
    } catch (e) {
      debugPrint('Failed to initialize IpnsPointerService: $e');
    }
  }

  /// The stored pointer for [tagId], or null if one hasn't been minted yet.
  WebsiteGroupPointer? pointerFor(String tagId) {
    if (!_isInitialized) return null;
    return _box!.get(tagId);
  }

  /// Lazily mint (on first call) and return the stable pointer for a group.
  ///
  /// On first use this generates a fresh per-group Ed25519 keypair, derives the
  /// permanent `k51…` IPNS name, stores the private seed in secure storage
  /// (NOT in the box), builds the front-door + gateway URLs, and persists the
  /// pointer. Idempotent: subsequent calls return the existing pointer, so a
  /// group never gets a second name.
  Future<WebsiteGroupPointer> getOrCreate(String tagId) async {
    if (!_isInitialized) await init();
    final existing = _box!.get(tagId);
    if (existing != null) return existing;

    // Before minting a brand-new name, pull any cloud backup once so a second
    // device / reinstall adopts the group's existing IPNS name instead of
    // diverging to a new one. Best-effort: offline / not-configured falls
    // through to minting.
    if (!_restoreAttempted) {
      _restoreAttempted = true;
      await restoreFromCloud();
      final adopted = _box!.get(tagId);
      if (adopted != null) return adopted;
    }

    final keyPair = await _ed25519.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes(); // 32-byte Ed25519 seed
    final publicKey = await keyPair.extractPublicKey();
    final ipnsName = IpnsName.fromEd25519PublicKey(
      Uint8List.fromList(publicKey.bytes),
    );

    // Persist the private seed per-group in secure storage. Never in the box,
    // never logged. Backed up in the encrypted cloud sync in Phase 3.
    await SecureStorageService.instance.write(
      SecureStorageKeys.groupIpnsPrivKeyPrefix + tagId,
      base64Encode(seed),
    );

    final now = DateTime.now();
    final pointer = WebsiteGroupPointer(
      tagId: tagId,
      ipnsName: ipnsName,
      frontDoorUrl: '${await _workerBase()}$ipnsName',
      ipnsGatewayUrl: ipnsGatewayTemplate.replaceAll('{name}', ipnsName),
      createdAt: now,
      updatedAt: now,
    );
    await _box!.put(tagId, pointer);
    _scheduleBackup(); // persist the new name + key off-device
    debugPrint('Minted IPNS pointer for tag $tagId -> $ipnsName');
    return pointer;
  }

  /// Load the per-group Ed25519 keypair from secure storage, or null if absent
  /// (e.g. key lost / never minted). Used by [publishLatest] to re-sign updates.
  Future<SimpleKeyPair?> loadKeyPair(String tagId) async {
    final b64 = await SecureStorageService.instance
        .read(SecureStorageKeys.groupIpnsPrivKeyPrefix + tagId);
    if (b64 == null || b64.isEmpty) return null;
    final seed = base64Decode(b64);
    return _ed25519.newKeyPairFromSeed(seed);
  }

  Future<String> _workerBase() async {
    final stored = await SecureStorageService.instance
        .read(SecureStorageKeys.websiteLinkWorkerBaseUrl);
    return (stored != null && stored.isNotEmpty) ? stored : defaultWorkerBase;
  }

  /// Persist mutations to a pointer (sequence/currentCid/published/updatedAt).
  Future<void> savePointer(WebsiteGroupPointer pointer) async {
    if (!_isInitialized) await init();
    pointer.updatedAt = DateTime.now();
    await _box!.put(pointer.tagId, pointer);
    _scheduleBackup();
  }

  /// Build, sign, and publish an updated IPNS record (name -> `/ipfs/{cid}`) to
  /// the IPNS service, bumping the sequence so the shared link now resolves to
  /// [cid]. The private key never leaves the device — only the signed record is
  /// uploaded.
  ///
  /// **Fetch-before-publish:** the currently-live record's sequence is the
  /// source of truth, so we publish `max(local, network) + 1`. This self-heals
  /// across reinstall / lost local state / a second device — without it, a
  /// device that lost its counter would republish a lower sequence that
  /// resolvers ignore, silently freezing the link (the long EOL would make that
  /// stall last years).
  ///
  /// Residual (accepted): two devices that fetch the same live sequence
  /// concurrently both publish `seq+1`; the IPNS "newest wins" tie-break keeps
  /// one, matching the "latest regeneration wins" intent. True multi-writer
  /// coordination is out of scope.
  Future<void> publishLatest(String tagId, String cid) async {
    if (!_isInitialized) await init();
    final pointer = await getOrCreate(tagId);
    final keyPair = await loadKeyPair(tagId);
    if (keyPair == null) {
      throw StateError('No IPNS signing key stored for website group $tagId');
    }

    final endpoint = await _publishEndpoint();
    final url = Uri.parse('$endpoint/name/${pointer.ipnsName}');

    final networkSeq = await _resolveNetworkSequence(url);
    final localSeq = pointer.published ? pointer.sequence : -1;
    final seq = max(localSeq, networkSeq) + 1; // -1 + 1 == 0 on first publish

    final record =
        await IpnsRecord.build(keyPair: keyPair, cid: cid, sequence: seq);

    // Defensive: never publish a record that doesn't verify against our own
    // public key (the one embedded in the name).
    final pub = IpnsName.ed25519PublicKeyFromName(pointer.ipnsName);
    if (pub == null || !await IpnsRecord.verify(record, pub)) {
      throw StateError('Built IPNS record failed self-verification');
    }

    final resp = await http
        .post(url, body: base64.encode(record))
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(
          'IPNS publish failed (${resp.statusCode}): ${resp.body}');
    }

    pointer.sequence = seq;
    pointer.currentCid = cid;
    pointer.published = true;
    await savePointer(pointer);
    debugPrint('Published IPNS ${pointer.ipnsName} seq=$seq -> $cid');
  }

  /// Resolve the currently-published sequence for [url] from the IPNS service,
  /// or -1 when there's no live record / offline / unparseable. Best-effort: any
  /// failure falls back to the local sequence (single-device still works).
  Future<int> _resolveNetworkSequence(Uri url) async {
    try {
      final resp = await http.get(url).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return -1;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final recordB64 = json['record'] as String?;
      if (recordB64 == null || recordB64.isEmpty) return -1;
      final seq = IpnsRecord.sequenceOf(base64.decode(recordB64));
      // Ignore absurd values (sanity cap well below 2^53).
      if (seq == null || seq < 0 || seq > 1000000000000000) return -1;
      return seq;
    } catch (_) {
      return -1;
    }
  }

  Future<String> _publishEndpoint() async {
    final stored = await SecureStorageService.instance
        .read(SecureStorageKeys.websiteIpnsPublishEndpoint);
    final base = (stored != null && stored.isNotEmpty)
        ? stored
        : defaultW3nameEndpoint;
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  // ============================================================================
  // CLOUD BACKUP (encrypted) — so a reinstall / second device keeps the SAME
  // IPNS name + key and can keep updating the link. Reuses FulaApiService's
  // encrypted channel unchanged; the private seed travels in the blob,
  // encrypted at the fula layer (same protection as other website metadata).
  // ============================================================================

  void _scheduleBackup() {
    if (_backupScheduled) return;
    _backupScheduled = true;
    Future.delayed(_backupDebounce, () async {
      _backupScheduled = false;
      await backupToCloud();
    });
  }

  /// Back up every pointer AND its private seed to the encrypted cloud blob.
  /// Best-effort: any failure is logged and ignored (the link still works on
  /// this device; only cross-device/reinstall durability is affected).
  Future<void> backupToCloud() async {
    if (!_isInitialized) return;
    if (!FulaApiService.instance.isConfigured) return;
    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;
      final userId = await _userId();
      if (userId == null) return;
      final objectKey = '.fula/website_pointers/$userId.json';

      // Merge with the existing cloud blob (keyed by tagId) so we never drop
      // another device's entries — or a group's only key backup.
      final merged = <String, Map<String, dynamic>>{};
      try {
        final existing = await FulaApiService.instance
            .downloadAndDecrypt(_metadataBucket, objectKey, encryptionKey);
        final ej = jsonDecode(utf8.decode(existing)) as Map<String, dynamic>;
        for (final raw in (ej['pointers'] as List<dynamic>? ?? const [])) {
          final m = raw as Map<String, dynamic>;
          final tid = m['tagId'] as String?;
          if (tid != null) merged[tid] = m;
        }
      } catch (_) {
        // No existing blob / offline / unreadable — start fresh.
      }

      // Overlay this device's pointers (authoritative for the groups it has).
      // If the local key is missing, preserve any key already in the cloud blob.
      for (final pointer in _box!.values) {
        final seedB64 = await SecureStorageService.instance
            .read(SecureStorageKeys.groupIpnsPrivKeyPrefix + pointer.tagId);
        final entry = <String, dynamic>{...pointer.toJson()};
        final priv = (seedB64 != null && seedB64.isNotEmpty)
            ? seedB64
            : merged[pointer.tagId]?['privKey'] as String?;
        if (priv != null && priv.isNotEmpty) entry['privKey'] = priv;
        merged[pointer.tagId] = entry;
      }

      final jsonStr = jsonEncode(<String, dynamic>{
        'pointers': merged.values.toList(),
        'updatedAt': DateTime.now().toIso8601String(),
      });
      final data = Uint8List.fromList(utf8.encode(jsonStr));
      await FulaApiService.instance.encryptAndUpload(
        _metadataBucket,
        objectKey,
        data,
        encryptionKey,
        contentType: 'application/json',
      );
      debugPrint('IPNS pointers backed up: ${merged.length}');
    } catch (e) {
      debugPrint('IpnsPointerService.backupToCloud error: $e');
    }
  }

  /// Restore pointers + private keys from the encrypted cloud blob (called on a
  /// fresh install alongside website-data restore — see
  /// `WebsiteService.restoreFromCloud`). Never clobbers a pointer that already
  /// exists locally (the local one is at least as fresh).
  Future<void> restoreFromCloud() async {
    if (!_isInitialized) await init();
    if (!FulaApiService.instance.isConfigured) return;
    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;
      final userId = await _userId();
      if (userId == null) return;

      final data = await FulaApiService.instance.downloadAndDecrypt(
        _metadataBucket,
        '.fula/website_pointers/$userId.json',
        encryptionKey,
      );
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final list = json['pointers'] as List<dynamic>? ?? const [];

      var restored = 0;
      for (final raw in list) {
        final map = raw as Map<String, dynamic>;
        final pointer = WebsiteGroupPointer.fromJson(map);
        final keyName = SecureStorageKeys.groupIpnsPrivKeyPrefix + pointer.tagId;

        // Don't clobber a local pointer (it's at least as fresh as the backup).
        final hadLocalPointer = _box!.get(pointer.tagId) != null;
        if (!hadLocalPointer) {
          await _box!.put(pointer.tagId, pointer);
        }

        // The pointer now authoritative locally for this tagId.
        final effective = _box!.get(pointer.tagId)!;

        // Restore the signing key only when missing AND it actually derives to
        // the locally-authoritative pointer's name — never associate a key with
        // the wrong name (e.g. if this device already minted a divergent name
        // for the same group). Also covers the Android case where the Hive box
        // survived a reinstall but secure storage was wiped.
        final existingKey = await SecureStorageService.instance.read(keyName);
        final priv = map['privKey'] as String?;
        if ((existingKey == null || existingKey.isEmpty) &&
            priv != null &&
            priv.isNotEmpty) {
          final derivedName = await _nameForSeed(priv);
          if (derivedName != null && derivedName == effective.ipnsName) {
            await SecureStorageService.instance.write(keyName, priv);
          } else {
            debugPrint(
                'IPNS restore: skipped key for ${pointer.tagId} (name mismatch)');
          }
        }

        if (!hadLocalPointer) restored++;
      }
      if (restored > 0) {
        debugPrint('Restored $restored IPNS pointers from cloud');
      }
    } catch (e) {
      final s = e.toString();
      if (s.contains('NoSuchKey') ||
          s.contains('not found') ||
          s.contains('404')) {
        debugPrint('IPNS pointers: no cloud backup found');
      } else {
        debugPrint('IpnsPointerService.restoreFromCloud error: $e');
      }
    }
  }

  /// Derive the IPNS name a base64 Ed25519 seed would produce, or null if the
  /// seed is malformed (bad base64 / wrong length). Used to prove a restored
  /// key matches the pointer it would sign for.
  Future<String?> _nameForSeed(String seedB64) async {
    try {
      final seed = base64Decode(seedB64);
      if (seed.length != 32) return null;
      final keyPair = await _ed25519.newKeyPairFromSeed(seed);
      final publicKey = await keyPair.extractPublicKey();
      return IpnsName.fromEd25519PublicKey(
        Uint8List.fromList(publicKey.bytes),
      );
    } catch (_) {
      return null;
    }
  }

  /// Stable per-user id for the cloud object key — `sha256(publicKey)[:16]`,
  /// matching WebsiteService's scheme so both blobs key off the same id.
  Future<String?> _userId() async {
    try {
      final pk = await AuthService.instance.getPublicKeyString();
      if (pk == null || pk.isEmpty) return null;
      return sha256.convert(utf8.encode(pk)).toString().substring(0, 16);
    } catch (_) {
      return null;
    }
  }
}
