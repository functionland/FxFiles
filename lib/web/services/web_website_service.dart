import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/models/website_group_pointer.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/generation_poll_policy.dart';
import 'package:fula_files/core/services/ipfs_gateway_helper.dart';
import 'package:fula_files/core/services/ipns_name.dart';
import 'package:fula_files/core/services/ipns_record.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/website_manifest_logic.dart';
import 'package:fula_files/core/services/website_prompt_builder.dart';
import 'package:fula_files/core/utils/file_type_utils.dart' as file_utils;
import 'package:fula_files/web/services/web_cache_sync.dart';
import 'package:fula_files/web/services/web_features.dart';
import 'package:fula_files/web/services/web_generation_steps.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';
import 'package:fula_files/web/services/web_listing_swr.dart';
import 'package:fula_files/web/services/web_tag_service.dart';
import 'package:fula_files/web/services/web_website_asset_upload_logic.dart';
import 'package:fula_files/web/services/web_website_jobs_logic.dart';

/// One asset for a website generation. ALWAYS CID-backed and byteless:
/// browser-picked files are eagerly streamed to the public
/// `website-assets` bucket at import time (WebWebsiteAssetUploader), so
/// by the time generation runs every asset is just a name + CID + notes.
/// File bytes never live in this object — that's what keeps the tab's
/// memory flat regardless of asset size.
class WebPickedAsset {
  final String fileName;
  final String? cid;
  final String? gatewayUrl;

  /// Byte size when known (fresh imports report the Blob size; assets
  /// carried over from an earlier generation may not know it).
  final int? size;

  /// Tag-manifest association row id when a current tag row exists —
  /// enables removal by row; null for rows removed by remoteKey.
  final String? taggedFileId;

  /// Parsed text content recorded by a previous generation — lets the
  /// parse phase skip re-reading the source entirely.
  final String? parsedContent;

  /// Session-only `URL.createObjectURL` preview for images (fresh
  /// imports) — bridges the gateway-propagation lag for new CIDs.
  final String? previewUrl;

  String note;

  WebPickedAsset({
    required this.fileName,
    this.cid,
    this.gatewayUrl,
    this.size,
    this.taggedFileId,
    this.parsedContent,
    this.previewUrl,
    this.note = '',
  });

  bool get isCidBacked => cid != null && cid!.isNotEmpty;

  int? get knownSize => size;

  String get type => file_utils.classifyFileType(fileName);

  /// Public gateway URL (recorded URL when present, else rebuilt from
  /// the CID via the configured template).
  String? get resolvedGatewayUrl {
    if (gatewayUrl != null && gatewayUrl!.isNotEmpty) return gatewayUrl;
    final c = cid;
    if (c != null && c.isNotEmpty) return IpfsGatewayHelper.buildUrlForCid(c);
    return null;
  }
}

/// Web counterpart of IpnsPointerService: same per-group Ed25519 key →
/// `k51…` IPNS name, same w3name publish protocol, same encrypted
/// cloud blob (`.fula/website_pointers/{userId}.json`, entries carry
/// `privKey` so any device can keep updating the link). No Hive — the
/// cloud blob IS the store; seeds are cached in (web) SecureStorage
/// under the same key prefix as native.
class WebIpnsService {
  WebIpnsService._();
  static final WebIpnsService instance = WebIpnsService._();

  // Same defaults as the native IpnsPointerService (kept in sync by
  // comment-reference; they are config-overridable on both platforms).
  static const String _defaultWorkerBase = 'https://fxfiles.top/w/';
  static const String _ipnsGatewayTemplate = 'https://{name}.ipns.dweb.link/';
  static const String _defaultW3nameEndpoint = 'https://name.web3.storage';

  static const String _metadataBucket = 'website-metadata';
  static final Ed25519 _ed25519 = Ed25519();

  String get _writeBucket =>
      BucketVersionResolver.writeBucket(_metadataBucket);

  final Map<String, WebsiteGroupPointer> _pointers = {};
  bool _loaded = false;

  /// Single-flight guard for [load] and serialization chain for
  /// [_backup] — concurrent UI callers must not race the blob.
  Future<void>? _loadFuture;
  Future<void> _backupChain = Future.value();

  Map<String, WebsiteGroupPointer> get pointersByTag =>
      Map.unmodifiable(_pointers);

  static Future<Uint8List> _kek() async {
    final b64 = await SecureStorageService.instance
        .read(SecureStorageKeys.encryptionKey);
    if (b64 == null || b64.isEmpty) {
      throw StateError('No session encryption key');
    }
    return Uint8List.fromList(base64Decode(b64));
  }

  static Future<String> _userId() => WebTagService.userId();

  String _pointerObjectKey(String userId) =>
      '.fula/website_pointers/$userId.json';

  /// Load pointers from the cloud blob; entries carrying a `privKey`
  /// seed are stashed into SecureStorage (validated against the IPNS
  /// name first, same rule as the native restore). Single-flight:
  /// concurrent NON-FORCE callers await the same download.
  ///
  /// A FORCE load never joins an in-flight non-force flight (same rule as
  /// `WebTagService.load`). It used to, which meant a caller asking for
  /// authoritative freshness — the mint path at `:217` does
  /// read-modify-write on the pointers manifest — could be served a
  /// flight that started earlier and, worse, could be parked behind one
  /// that had stalled. With a gc-damaged metadata bucket that stall was
  /// 30s+, so the detail screen's forced load inherited someone else's
  /// hang instead of doing its own bounded read.
  Future<void> load({bool force = false}) {
    if (_loaded && !force) return Future.value();
    if (!force) {
      final inFlight = _loadFuture;
      if (inFlight != null) return inFlight;
    }
    final f = _doLoad().whenComplete(() => _loadFuture = null);
    _loadFuture = f;
    return f;
  }

  Future<void> _doLoad() async {
    final kek = await _kek();
    final uid = await _userId();
    // First pass: collect entries first-wins by tagId ([v8, legacy]
    // order — v8 wins), keeping each winner's privKey alongside it.
    final winners = <String, ({WebsiteGroupPointer pointer, String? privKey})>{};
    // The core downloadMetadataMerged has NO timeout of its own and reads
    // [v8, legacy] in series, so on a gc-damaged legacy bucket this could
    // hang the caller indefinitely. It never throws (a failed half is just
    // skipped), so a bound here degrades to "no pointers" rather than an
    // error — the detail screen already treats a missing pointer as "no
    // stable link yet".
    for (final blob in await FulaApiService.instance
        .downloadMetadataMerged(_metadataBucket, _pointerObjectKey(uid), kek)
        .timeout(const Duration(seconds: 12), onTimeout: () {
      debugPrint('WebIpnsService: pointer manifest read timed out');
      return const <Uint8List>[];
    })) {
      try {
        final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
        for (final raw in (j['pointers'] as List<dynamic>? ?? const [])) {
          if (raw is! Map<String, dynamic>) continue;
          try {
            final pointer = WebsiteGroupPointer.fromJson(raw);
            winners.putIfAbsent(pointer.tagId,
                () => (pointer: pointer, privKey: raw['privKey'] as String?));
          } catch (e) {
            debugPrint('WebIpnsService: pointer entry skipped: $e');
          }
        }
      } catch (e) {
        debugPrint('WebIpnsService: pointer blob skipped: $e');
      }
    }

    // Second pass: adopt winners and store ONLY the seed that derives
    // the WINNING pointer's name. A losing (e.g. legacy) entry's seed
    // must never overwrite the winner's — signing with it would fail
    // self-verification forever and strand the link.
    for (final entry in winners.values) {
      final pointer = entry.pointer;
      _pointers.putIfAbsent(pointer.tagId, () => pointer);
      final privKey = entry.privKey;
      if (privKey == null || privKey.isEmpty) continue;
      try {
        final seed = base64Decode(privKey);
        final kp = await _ed25519.newKeyPairFromSeed(seed);
        final pub = await kp.extractPublicKey();
        final derived =
            IpnsName.fromEd25519PublicKey(Uint8List.fromList(pub.bytes));
        final winningName = _pointers[pointer.tagId]!.ipnsName;
        if (derived == winningName) {
          await SecureStorageService.instance.write(
            SecureStorageKeys.groupIpnsPrivKeyPrefix + pointer.tagId,
            privKey,
          );
        } else {
          debugPrint('WebIpnsService: seed/name mismatch for '
              '${pointer.tagId} — seed ignored');
        }
      } catch (e) {
        debugPrint('WebIpnsService: seed restore skipped: $e');
      }
    }
    _loaded = true;
  }

  WebsiteGroupPointer? pointerFor(String tagId) => _pointers[tagId];

  /// Mint-or-return the group's stable pointer (cloud-restore first so
  /// a group never gets a second name).
  Future<WebsiteGroupPointer> getOrCreate(String tagId) async {
    await load();
    var existing = _pointers[tagId];
    if (existing != null) return existing;

    // About to mint a NEW permanent name: re-pull the blob once more so
    // a name minted seconds ago by another device/tab is adopted
    // instead of diverging (same narrow race as native, not wider).
    await load(force: true);
    existing = _pointers[tagId];
    if (existing != null) return existing;

    final keyPair = await _ed25519.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    final ipnsName =
        IpnsName.fromEd25519PublicKey(Uint8List.fromList(publicKey.bytes));

    await SecureStorageService.instance.write(
      SecureStorageKeys.groupIpnsPrivKeyPrefix + tagId,
      base64Encode(seed),
    );

    final now = DateTime.now();
    final pointer = WebsiteGroupPointer(
      tagId: tagId,
      ipnsName: ipnsName,
      frontDoorUrl: '$_defaultWorkerBase$ipnsName',
      ipnsGatewayUrl: _ipnsGatewayTemplate.replaceAll('{name}', ipnsName),
      createdAt: now,
      updatedAt: now,
    );
    _pointers[tagId] = pointer;
    await _backup();
    debugPrint('WebIpnsService: minted IPNS pointer $tagId -> $ipnsName');
    return pointer;
  }

  /// Build, sign and publish an updated IPNS record (same
  /// fetch-before-publish sequence rule as native: max(local, network)+1).
  Future<void> publishLatest(String tagId, String cid) async {
    final pointer = await getOrCreate(tagId);
    final seedB64 = await SecureStorageService.instance
        .read(SecureStorageKeys.groupIpnsPrivKeyPrefix + tagId);
    if (seedB64 == null || seedB64.isEmpty) {
      throw StateError('No IPNS signing key stored for website group $tagId');
    }
    final keyPair = await _ed25519.newKeyPairFromSeed(base64Decode(seedB64));

    final url =
        Uri.parse('$_defaultW3nameEndpoint/name/${pointer.ipnsName}');
    final networkSeq = await _resolveNetworkSequence(url);
    final localSeq = pointer.published ? pointer.sequence : -1;
    final seq = max(localSeq, networkSeq) + 1;

    final record =
        await IpnsRecord.build(keyPair: keyPair, cid: cid, sequence: seq);
    final pub = IpnsName.ed25519PublicKeyFromName(pointer.ipnsName);
    if (pub == null || !await IpnsRecord.verify(record, pub)) {
      throw StateError('Built IPNS record failed self-verification');
    }

    final resp = await http
        .post(url, body: base64.encode(record))
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('IPNS publish failed (${resp.statusCode}): ${resp.body}');
    }

    pointer.sequence = seq;
    pointer.currentCid = cid;
    pointer.published = true;
    pointer.updatedAt = DateTime.now();
    _pointers[tagId] = pointer;
    await _backup();
    debugPrint('WebIpnsService: published ${pointer.ipnsName} seq=$seq');
  }

  Future<int> _resolveNetworkSequence(Uri url) async {
    try {
      final resp = await http.get(url).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return -1;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final recordB64 = json['record'] as String?;
      if (recordB64 == null || recordB64.isEmpty) return -1;
      final seq = IpnsRecord.sequenceOf(base64.decode(recordB64));
      if (seq == null || seq < 0 || seq > 1000000000000000) return -1;
      return seq;
    } catch (_) {
      return -1;
    }
  }

  /// Merge-preserving cloud backup, same blob shape as native
  /// (`{pointers:[{...pointer, privKey?}], updatedAt}`) — entries from
  /// other devices (and their seeds) are never dropped. Serialized:
  /// overlapping backups would download the same base blob and the
  /// loser's upload would erase the winner's changes.
  Future<void> _backup() {
    final next = _backupChain.then((_) => _doBackup());
    // Keep the chain alive even when a backup fails.
    _backupChain = next.catchError((_) {});
    return next;
  }

  Future<void> _doBackup() async {
    try {
      final kek = await _kek();
      final uid = await _userId();
      final objectKey = _pointerObjectKey(uid);

      final merged = <String, Map<String, dynamic>>{};
      for (final blob in await FulaApiService.instance
          .downloadMetadataMerged(_metadataBucket, objectKey, kek)) {
        try {
          final ej = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
          for (final raw in (ej['pointers'] as List<dynamic>? ?? const [])) {
            final m = raw as Map<String, dynamic>;
            final tid = m['tagId'] as String?;
            if (tid != null) merged.putIfAbsent(tid, () => m);
          }
        } catch (_) {}
      }

      for (final pointer in _pointers.values) {
        final seedB64 = await SecureStorageService.instance
            .read(SecureStorageKeys.groupIpnsPrivKeyPrefix + pointer.tagId);
        final entry = <String, dynamic>{...pointer.toJson()};
        final priv = (seedB64 != null && seedB64.isNotEmpty)
            ? seedB64
            : merged[pointer.tagId]?['privKey'] as String?;
        if (priv != null && priv.isNotEmpty) entry['privKey'] = priv;
        merged[pointer.tagId] = entry;
      }

      final data = Uint8List.fromList(utf8.encode(jsonEncode({
        'pointers': merged.values.toList(),
        'updatedAt': DateTime.now().toIso8601String(),
      })));
      try {
        await FulaApiService.instance.createBucket(_writeBucket);
      } catch (_) {}
      await FulaApiService.instance.encryptAndUpload(
        _writeBucket,
        objectKey,
        data,
        kek,
        contentType: 'application/json',
      );
      // Write-through to the SWR cache (read by WebFeatures.loadWebsites).
      await WebListingCache.instance
          .writeManifest(_writeBucket, objectKey, data);
      WebCacheSync.instance.sendInvalidateManifest(_writeBucket, objectKey);
      debugPrint('WebIpnsService: pointers backed up (${merged.length})');
    } catch (e) {
      debugPrint('WebIpnsService: backup failed (non-fatal): $e');
    }
  }
}

/// Multi-pass generation (design brief → build → polish) legitimately runs
/// past the old 5-minute ceiling; the server's own job timeout is 15 min.
const Duration kWebsiteGenerationTimeout = Duration(minutes: 20);

/// Thrown to stop a poll loop WITHOUT failing the generation — this tab
/// couldn't reach the server (or isn't signed in), which says nothing about
/// the job running on the backend. The pending record stays on disk so a
/// later load resumes it.
class _WebsitePollPaused implements Exception {
  final String message;
  const _WebsitePollPaused(this.message);
}

/// Web counterpart of the native WebsiteService generation pipeline:
/// upload assets (unencrypted, same bucket/key/caps) → parse what the
/// browser can (text; placeholders elsewhere — same as the desktop app,
/// which has no ML Kit either) → call the AI endpoint and poll → append
/// the completed generation to the same encrypted cloud manifest the
/// app restores from → re-point the group's stable IPNS link.
class WebWebsiteService extends ChangeNotifier {
  WebWebsiteService._();
  static final WebWebsiteService instance = WebWebsiteService._();

  static const String _defaultAiEndpoint = 'https://ai.cloud.fx.land';
  static const String _websiteMetadataBucket = 'website-metadata';

  static const _uuid = Uuid();

  /// In-flight generations for this browser session (completed ones
  /// also land in the cloud manifest). Screens listen to this service
  /// (ChangeNotifier) for live status updates.
  final List<WebsiteGeneration> liveGenerations = [];

  /// AI job ids with a live poll loop in THIS tab — stops [resumePendingJobs]
  /// from double-polling a job the fresh-generation path is already driving.
  final Set<String> _activeJobIds = {};

  /// Serializes read-modify-write cycles on the pending-jobs sidecar.
  Future<void> _pendingChain = Future.value();

  /// Transient per-generation progress detail, keyed by generation id.
  ///
  /// Deliberately NOT persisted and deliberately NOT fields on
  /// [WebsiteGeneration]: that model is `@HiveType(typeId: 25)` and is
  /// shared with the native app, so adding fields there would drag a Hive
  /// migration into a web-only change. Both values are re-established by
  /// the first poll after a resume, which is the only way they can be
  /// lost.
  ///
  /// [_serverPhase] is the AI service's own phase from
  /// `GET /api/v1/status/:jobId` ('pending' | 'generating' |
  /// 'publishing'); [_lastActiveStatus] is the last non-error client
  /// phase, needed because a failure overwrites `status` with `error` and
  /// would otherwise lose which step actually broke.
  final Map<String, String> _serverPhase = {};
  final Map<String, WebsiteGenStatus> _lastActiveStatus = {};

  /// Furthest generation PASS observed, per generation. Derived from the
  /// server's `statusMessage` ('Designing…' / 'Building…' / 'Polishing…')
  /// and, like the phase above, monotonic and transient.
  final Map<String, WebsiteSubStep> _subStep = {};

  WebsiteSubStep? subStepFor(String generationId) => _subStep[generationId];

  /// The website group's stable IPNS front door
  /// (`https://fxfiles.top/w/<k51…>`), or null before the pointer has
  /// been minted.
  ///
  /// This is the link the app shows as "the" website address, and the
  /// one the public directory should carry: it survives regeneration,
  /// whereas the per-generation `gatewayUrl` points at a single build.
  /// The SERVER cannot work it out — the pointer lives in this user's
  /// encrypted manifest and is published to w3name from the browser —
  /// so the client has to hand it over.
  String? _frontDoorUrlFor(String tagId) {
    final url = WebIpnsService.instance.pointersByTag[tagId]?.frontDoorUrl;
    return (url != null && url.isNotEmpty) ? url : null;
  }

  /// Directory opt-in for an IN-FLIGHT generation, keyed by generation
  /// id. Transient for the same reason as the two maps above: it is only
  /// needed between `startGeneration` and the `/generate` POST, after
  /// which the server owns the flag and the website screen's toggle is
  /// what changes it.
  final Map<String, bool> _listInDirectory = {};

  /// Server phase for [generationId], or null if none has been observed.
  String? serverPhaseFor(String generationId) => _serverPhase[generationId];

  /// Last non-error client phase for [generationId].
  WebsiteGenStatus? lastActiveStatusFor(String generationId) =>
      _lastActiveStatus[generationId];

  void _notify(WebsiteGeneration g) {
    // Record the last phase the generation was genuinely working in, so a
    // later `error` can be attributed to the right step.
    if (g.status != WebsiteGenStatus.error &&
        g.status != WebsiteGenStatus.completed) {
      _lastActiveStatus[g.id] = g.status;
    }
    notifyListeners();
  }

  /// Fold a freshly-polled server phase in, never walking backwards.
  void _recordServerPhase(String generationId, String? phase) {
    final next = advanceServerPhase(_serverPhase[generationId], phase);
    if (next != null) _serverPhase[generationId] = next;
  }

  /// Drop transient progress detail once a generation is finished with.
  void _forgetPhase(String generationId) {
    _serverPhase.remove(generationId);
    _lastActiveStatus.remove(generationId);
    _listInDirectory.remove(generationId);
    _subStep.remove(generationId);
  }

  /// Turn a completed website's public-directory listing on or off.
  ///
  /// Deliberately available AFTER generation: a user must not have to
  /// regenerate a site to take it out of the directory. Throws with a
  /// readable message so the caller can surface a failure instead of
  /// silently reverting the switch.
  ///
  /// Also (re)sends the group's stable share link — see
  /// [_frontDoorUrlFor].
  Future<void> setDirectoryListing(
    WebsiteGeneration generation, {
    required bool listed,
  }) async {
    // Throws 'No API key configured' when the session is gone.
    final jwt = await _jwt();
    final aiEndpoint = await SecureStorageService.instance
            .read(SecureStorageKeys.aiEndpointUrl) ??
        _defaultAiEndpoint;

    final http.Response response;
    try {
      response = await http
          .post(
            // Keyed on the website GROUP, not the generation.
            //
            // `generation.id` is a CLIENT-side uuid; the server's row id
            // is the jobId it returned from /generate, which this client
            // only holds while the job is in flight and discards on
            // completion. Addressing the server by generation.id 404s for
            // every finished site — which is what silently hid the
            // listing switch. The group (tag id) is stable and always
            // known here.
            Uri.parse('$aiEndpoint/api/v1/websites/${generation.tagId}/listing'),
            headers: {
              'Authorization': 'Bearer $jwt',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'listed': listed,
              'name': generation.tagName,
              // The group's stable IPNS front door, when it has been
              // minted. The directory falls back to the raw
              // per-generation gateway URL without it — which points at
              // ONE build and goes stale on the next regeneration.
              if (_frontDoorUrlFor(generation.tagId) != null)
                'url': _frontDoorUrlFor(generation.tagId),
            }),
          )
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw Exception('Request timed out. Please try again.');
    }

    if (response.statusCode == 409) {
      throw Exception('This site was removed from the directory by a moderator');
    }
    if (response.statusCode == 404) {
      throw Exception('This website is not on the server yet');
    }
    if (response.statusCode != 200) {
      throw Exception('Could not update the listing (${response.statusCode})');
    }
    // `urlAccepted` tells us whether the server actually stored the link
    // it was sent — a malformed one is rejected without failing the
    // toggle, and recording it as stored would suppress the repair.
    var stored = _listedOnServer[generation.tagId]?.hasStableUrl ?? false;
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['urlAccepted'] == true) stored = true;
    } catch (_) {
      // A 200 with an unreadable body still toggled; leave `stored` as
      // it was so the repair can retry later.
    }
    _listedOnServer[generation.tagId] = (
      listed: listed,
      delistedByAdmin: false,
      hasStableUrl: stored,
    );
    _notify(generation);
  }

  /// Last known server-side listing state, keyed by website GROUP (tag
  /// id), so the switch reflects reality after a toggle without
  /// re-fetching.
  final Map<
      String,
      ({
        bool listed,
        bool delistedByAdmin,
        bool hasStableUrl,
      })> _listedOnServer = {};

  ({bool listed, bool delistedByAdmin, bool hasStableUrl})? listedOnServer(
          String tagId) =>
      _listedOnServer[tagId];

  /// Groups this session has already tried to repair, so a site whose
  /// front door genuinely cannot be published does not re-POST on every
  /// visit to the screen.
  final Set<String> _linkRepairAttempted = {};

  /// Push the stable share link for a site that is listed without one.
  ///
  /// The server CANNOT work this address out. The IPNS pointer lives in
  /// this user's encrypted manifest and is published to w3name from the
  /// browser, so only the client can supply it — and a site listed
  /// before the client started sending it shows the raw per-generation
  /// gateway URL in the directory, which points at ONE build and goes
  /// stale on the next regeneration.
  ///
  /// Repairing that silently is deliberate: the alternative is asking a
  /// user to toggle listing off and on to fix data they did not break.
  /// Failures are swallowed — this is a background repair, and the entry
  /// keeps its old link either way.
  Future<void> ensureStableLinkPublished(WebsiteGeneration generation) async {
    final tagId = generation.tagId;
    final state = _listedOnServer[tagId];
    if (state == null || !state.listed || state.hasStableUrl) return;
    if (_frontDoorUrlFor(tagId) == null) return;
    if (!_linkRepairAttempted.add(tagId)) return;
    try {
      await setDirectoryListing(generation, listed: true);
    } catch (e) {
      debugPrint('Could not publish the stable link for $tagId: $e');
    }
  }

  /// Read a website's directory state from the server.
  ///
  /// Keyed on the GROUP: the client's generation id is not the server's
  /// row id (that is the jobId, discarded once a job completes), so an
  /// id-keyed lookup 404s for every finished site — which is what hid
  /// the switch entirely.
  ///
  /// Returns null when the state cannot be determined, and the caller
  /// then shows no switch rather than a wrong one.
  Future<({bool listed, bool delistedByAdmin, bool hasStableUrl})?>
      fetchListingState(String tagId) async {
    final cached = _listedOnServer[tagId];
    if (cached != null) return cached;
    try {
      final jwt = await _jwt();
      final aiEndpoint = await SecureStorageService.instance
              .read(SecureStorageKeys.aiEndpointUrl) ??
          _defaultAiEndpoint;
      final response = await http.get(
        Uri.parse('$aiEndpoint/api/v1/websites/$tagId/listing'),
        headers: {'Authorization': 'Bearer $jwt'},
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      // An older backend that predates the directory omits these; treat
      // a missing field as "not listed" rather than inventing a state.
      final state = (
        listed: body['listed'] == true,
        delistedByAdmin: body['delistedByAdmin'] == true,
        // Absent on a backend that predates the stable link, which is
        // the same situation as "no link stored": treat it as missing
        // and let the repair push one.
        hasStableUrl: body['hasStableUrl'] == true,
      );
      _listedOnServer[tagId] = state;
      return state;
    } catch (e) {
      debugPrint('Listing state unavailable for $tagId: $e');
      return null;
    }
  }

  /// Create a website group — a `websites-` prefixed tag, exactly like
  /// the app (websiteProvider.createWebsite).
  Future<FileTag> createWebsite(String name) =>
      WebTagService.instance.createTag(
        name: 'websites-$name',
        colorValue: TagColors.getRandomColor(),
      );

  /// Web default routes through the cloud.fx.land passthrough — the
  /// analytics host itself serves no CORS headers, so a direct browser
  /// read would be blocked (native reads it directly, no CORS there).
  static const String _defaultAnalyticsEndpoint =
      'https://cloud.fx.land/analytics';

  /// Same contract as WebsiteService.fetchAnalytics: stats keyed by the
  /// site's CID; 404 → zero counts; transport error → null
  /// ("unavailable" in the card).
  Future<({int pageviews, int uniqueVisitors})?> fetchAnalytics(
      String cid) async {
    if (cid.isEmpty) return null;
    final analyticsEndpoint = await SecureStorageService.instance
            .read(SecureStorageKeys.analyticsEndpointUrl) ??
        _defaultAnalyticsEndpoint;
    try {
      final response = await http
          .get(Uri.parse('$analyticsEndpoint/api/v1/stats/$cid'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 404) {
        return (pageviews: 0, uniqueVisitors: 0);
      }
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return (
        pageviews: (body['pageviews'] as num?)?.toInt() ?? 0,
        uniqueVisitors: (body['uniqueVisitors'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      debugPrint('fetchAnalytics($cid) error: $e');
      return null;
    }
  }

  Future<({int costFula, int costFulaWithTracking})?> fetchPricing() async {
    try {
      final response = await http
          .get(Uri.parse('$_defaultAiEndpoint/api/v1/pricing'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final base = body['generationCostFula'];
        final tracked = body['generationCostFulaWithTracking'];
        if (base is num && tracked is num && base >= 0 && tracked >= 0) {
          return (
            costFula: base.toInt(),
            costFulaWithTracking: tracked.toInt(),
          );
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String> _jwt() async {
    final jwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    if (jwt == null || jwt.isEmpty) {
      throw Exception('No API key configured');
    }
    return jwt;
  }

  /// Start the full pipeline. Returns the live generation record
  /// (status updates flow through [ticker]).
  Future<WebsiteGeneration> startGeneration({
    required String tagId,
    required String tagName,
    required String prompt,
    required List<WebPickedAsset> picked,
    bool enableTracking = false,

    /// Opt into the public directory ("yellow pages").
    ///
    /// Defaults OFF, and the checkbox in the pre-generation disclaimer
    /// starts unticked: a pre-ticked box does not constitute consent
    /// (GDPR Recital 32), so listing requires a deliberate act. The
    /// SERVER column also defaults to false, so a site is listed only
    /// when a user actively asked for it — here, or later via the
    /// website screen's toggle.
    bool listInDirectory = false,
  }) async {
    final websiteName = tagName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

    final assets = picked
        .map((a) => WebsiteAsset(
              localPath: '', // web: in-memory bytes, no path
              fileName: a.fileName,
              type: a.type,
              comment: a.note.trim().isEmpty ? null : a.note.trim(),
            ))
        .toList();

    final generation = WebsiteGeneration(
      id: _uuid.v4(),
      tagId: tagId,
      tagName: tagName,
      prompt: prompt,
      status: WebsiteGenStatus.uploading,
      statusMessage: 'Starting upload...',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      totalAssets: assets.length,
      uploadedAssets: 0,
      assets: assets,
      trackingEnabled: enableTracking,
    );
    _listInDirectory[generation.id] = listInDirectory;
    liveGenerations.insert(0, generation);
    _notify(generation);

    // Run asynchronously, native-style.
    unawaited(_runPipeline(generation, websiteName, picked));
    return generation;
  }

  Future<void> _runPipeline(WebsiteGeneration generation, String websiteName,
      List<WebPickedAsset> picked) async {
    try {
      await _ensureUploadedPhase(generation, websiteName, picked);
      await _parsePhase(generation, websiteName, picked);
      await _generatePhase(generation);
    } catch (e) {
      generation.status = WebsiteGenStatus.error;
      generation.errorMessage = e.toString();
      generation.updatedAt = DateTime.now();
      _notify(generation);
      debugPrint('Web website generation failed: $e');
    }
  }

  /// Assets arrive here already IN the public bucket — fresh imports were
  /// eagerly streamed at import time (WebWebsiteAssetUploader) and
  /// carried-over assets kept their prior CID (same content → same key →
  /// same object). So this phase moves ZERO bytes: it stamps each
  /// generation asset with its recorded CID (one defensive HEAD when a
  /// CID is missing) and enforces the per-job file cap. Type/size caps
  /// were enforced at import time from Blob metadata; the backend
  /// mirrors them as defence in depth.
  Future<void> _ensureUploadedPhase(WebsiteGeneration generation,
      String websiteName, List<WebPickedAsset> picked) async {
    int failedCount = 0;
    int uploadedCount = 0;
    final skipReasons = <String>[];

    generation.statusMessage = 'Checking assets...';
    generation.updatedAt = DateTime.now();
    _notify(generation);

    for (var i = 0; i < generation.assets.length; i++) {
      final asset = generation.assets[i];

      if (uploadedCount >= kWebsiteMaxFilesPerJob) {
        asset.uploaded = false;
        failedCount++;
        skipReasons
            .add('${asset.fileName}: $kWebsiteMaxFilesPerJob-file cap reached');
        continue;
      }

      var cid = picked[i].cid;
      if (cid == null || cid.isEmpty) {
        // Defensive — the screen only passes CID-backed assets. One HEAD
        // attempt against the expected key recovers a lost ETag.
        cid = await WebFeatures.websiteAssetCidByHead(
            '$websiteName/${asset.fileName}');
      }
      if (cid == null || cid.isEmpty) {
        asset.uploaded = false;
        failedCount++;
        skipReasons.add('${asset.fileName}: not uploaded');
        continue;
      }

      asset.cid = cid;
      final recordedUrl = picked[i].gatewayUrl;
      asset.gatewayUrl = (recordedUrl != null && recordedUrl.isNotEmpty)
          ? recordedUrl
          : IpfsGatewayHelper.buildUrlForCid(cid);
      asset.uploaded = true;
      uploadedCount++;
      generation.uploadedAssets = uploadedCount;
      _notify(generation);
    }

    if (failedCount > 0) {
      final summary = skipReasons.length <= 3
          ? skipReasons.join('; ')
          : '${skipReasons.take(3).join('; ')} (+${skipReasons.length - 3} more)';
      generation.statusMessage =
          '$failedCount of ${generation.totalAssets} assets skipped — $summary';
      generation.updatedAt = DateTime.now();
      _notify(generation);
    }
  }

  /// Content extraction WITHOUT resident bytes. Priority per asset:
  /// parsed content recorded by a previous generation (no fetch at all)
  /// → a bounded ≤16KB ranged GET of the object's prefix (text types
  /// only — enough for the 2000-char truncation below) → the same
  /// name-based placeholders the desktop app produces. The whole file is
  /// never read.
  Future<void> _parsePhase(WebsiteGeneration generation, String websiteName,
      List<WebPickedAsset> picked) async {
    generation.status = WebsiteGenStatus.parsing;
    generation.statusMessage = 'Parsing content...';
    generation.updatedAt = DateTime.now();
    _notify(generation);

    const textExts = [
      '.txt', '.md', '.json', '.xml', '.yaml', '.yml', '.log', '.csv',
      '.html', '.css', '.js',
    ];
    for (var i = 0; i < generation.assets.length; i++) {
      final asset = generation.assets[i];
      if (!asset.uploaded) continue;
      final dot = asset.fileName.lastIndexOf('.');
      final ext =
          dot >= 0 ? asset.fileName.substring(dot).toLowerCase() : '';
      String? content;
      try {
        switch (asset.type) {
          case 'image':
            content = 'Image: ${asset.fileName}';
            break;
          case 'video':
            content = 'Video: ${asset.fileName}';
            break;
          case 'audio':
            content =
                'Audio file: ${asset.fileName} (format: ${ext.replaceAll('.', '')})';
            break;
          default: // document
            final recorded = picked[i].parsedContent;
            if (recorded != null && recorded.isNotEmpty) {
              content = recorded;
            } else if (textExts.contains(ext)) {
              final text = await WebFeatures.websiteAssetTextPrefix(
                  '$websiteName/${asset.fileName}');
              if (text != null && text.isNotEmpty) {
                content = text.length > 2000
                    ? '${text.substring(0, 2000)}...'
                    : text;
              } else {
                content = 'Document: ${asset.fileName}';
              }
            } else if (ext == '.pdf') {
              content = 'PDF document: ${asset.fileName}';
            } else {
              content = 'Document: ${asset.fileName}';
            }
        }
      } catch (e) {
        debugPrint('Parse skipped for ${asset.fileName}: $e');
      }
      if (content != null && content.isNotEmpty) {
        asset.parsedContent = content.length > kWebsiteMaxParsedContentBytes
            ? content.substring(0, kWebsiteMaxParsedContentBytes)
            : content;
      }
    }
    _notify(generation);
  }

  Future<void> _generatePhase(WebsiteGeneration generation) async {
    generation.status = WebsiteGenStatus.generating;
    generation.statusMessage = 'Generating website...';
    generation.updatedAt = DateTime.now();
    _notify(generation);

    final jwt = await _jwt();
    final aiEndpoint = await SecureStorageService.instance
            .read(SecureStorageKeys.aiEndpointUrl) ??
        _defaultAiEndpoint;

    final uploadedAssets =
        generation.assets.where((a) => a.uploaded).toList();
    final validAssets = uploadedAssets
        .where((a) => a.gatewayUrl != null && a.gatewayUrl!.isNotEmpty)
        .toList();
    final assetPayloads = validAssets.map((a) => a.toAiPayload()).toList();
    final assetNotes = <AssetNote>[
      for (final a in validAssets)
        if (a.comment != null && a.comment!.trim().isNotEmpty)
          (fileName: a.fileName, cid: a.cid, comment: a.comment!),
    ];

    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$aiEndpoint/api/v1/generate'),
            headers: {
              'Authorization': 'Bearer $jwt',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'prompt':
                  buildWebsiteAiPrompt(generation.prompt, assetNotes: assetNotes),
              'assets': assetPayloads,
              'enable_tracking': generation.trackingEnabled,
              // Capability: opt into the backend's multi-pass pipeline
              // (this client polls for up to 20 minutes below).
              'pipeline_version': 2,
              // Public directory. Sent explicitly — the server column
              // defaults to false, so an older client (or a resumed job)
              // can never publish a user into the directory by omission.
              'listed': _listInDirectory[generation.id] ?? false,
              // The group's display name, sent as its own field rather
              // than scraped from the prompt (free text the user wrote).
              'listing_name': generation.tagName,
              // Per-WEBSITE key so the directory shows one entry per
              // website instead of one per regeneration.
              'listing_group': generation.tagId,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw Exception('Request timed out. Please try again.');
    }

    if (response.statusCode == 402) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final required = body['required'];
      final balance = body['balance'];
      if (required != null && balance != null) {
        throw Exception(
            'Insufficient credits: need $required FULA, have $balance FULA');
      }
      throw Exception(
          'Insufficient credits. Please top up your FULA balance.');
    }
    if (response.statusCode == 429) {
      throw Exception('Rate limit exceeded. Please try again later.');
    }
    if (response.statusCode != 202) {
      throw Exception(
          'Generation request failed (${response.statusCode}): ${response.body}');
    }

    final jobId =
        (jsonDecode(response.body) as Map<String, dynamic>)['jobId'] as String;

    // Persist the job handle BEFORE polling. Everything up to here lived
    // only in this tab's memory; from this point a closed/killed tab (the
    // norm on mobile, where Chrome evicts background tabs) can pick the
    // job back up on reopen instead of losing a paid generation.
    await _writePendingJob(generation, jobId);

    await _pollGenerationJob(
      generation,
      jobId,
      jwt,
      aiEndpoint,
      deadline: DateTime.now().add(kWebsiteGenerationTimeout),
    );
  }

  /// Poll an accepted generation job to a terminal state, then run the
  /// completion side-effects (cloud manifest, group membership, stable
  /// link). Shared by the fresh-generation path and by [resumePendingJobs].
  ///
  /// Failure classification mirrors the social poller: only the SERVER's
  /// verdict terminalizes. A transport failure or an expired session throws
  /// [_WebsitePollPaused], which stops this loop but leaves the pending
  /// record on disk so a later load resumes it.
  Future<void> _pollGenerationJob(
    WebsiteGeneration generation,
    String jobId,
    String jwt,
    String aiEndpoint, {
    required DateTime deadline,
  }) async {
    if (!_activeJobIds.add(jobId)) return;
    try {
      await _runGenerationPollLoop(
          generation, jobId, jwt, aiEndpoint, deadline);
    } on _WebsitePollPaused catch (paused) {
      // Not a job failure — keep the generation in its running state and
      // leave the pending record intact so reopening resumes it.
      generation.statusMessage = paused.message;
      generation.updatedAt = DateTime.now();
      _notify(generation);
      debugPrint('WebWebsiteService: poll paused — ${paused.message}');
    } catch (_) {
      // Terminal: the server failed the job, or it is genuinely gone.
      await _clearPendingJob(generation.id);
      rethrow;
    } finally {
      _activeJobIds.remove(jobId);
    }
  }

  Future<void> _runGenerationPollLoop(
    WebsiteGeneration generation,
    String jobId,
    String jwt,
    String aiEndpoint,
    DateTime deadline,
  ) async {
    Duration pollInterval = const Duration(seconds: 2);
    const maxPollInterval = Duration(seconds: 10);
    int consecutiveErrors = 0;

    // Poll-first, deadline-after: a mobile tab backgrounded/screen-off has
    // its timers frozen, so wall-clock time keeps passing while no polls
    // run. On resume the loop MUST ask the server once more before giving
    // up — the job very likely completed server-side while the tab slept,
    // and completion is what writes the manifest/membership records.
    while (true) {
      await Future.delayed(pollInterval);
      if (pollInterval < maxPollInterval) {
        pollInterval = Duration(
          milliseconds: (pollInterval.inMilliseconds * 1.5)
              .toInt()
              .clamp(0, maxPollInterval.inMilliseconds),
        );
      }

      final http.Response statusResponse;
      try {
        statusResponse = await http.get(
          Uri.parse('$aiEndpoint/api/v1/status/$jobId'),
          headers: {'Authorization': 'Bearer $jwt'},
        ).timeout(const Duration(seconds: 20));
      } catch (_) {
        // Transport failure (offline, DNS, CORS, hung connection). A tab
        // reopened on mobile frequently polls before the network is back —
        // never let that discard the job.
        consecutiveErrors++;
        switch (classifyPollTransportFailure(
            consecutiveErrors: consecutiveErrors)) {
          case PollFailure.retry:
            continue;
          case PollFailure.pause:
          case PollFailure.fail:
            throw const _WebsitePollPaused(
                'Could not reach the server — reopen this page to retry');
        }
      }

      if (statusResponse.statusCode != 200) {
        consecutiveErrors++;
        switch (classifyPollStatusCode(statusResponse.statusCode,
            consecutiveErrors: consecutiveErrors)) {
          case PollFailure.retry:
            continue;
          case PollFailure.pause:
            throw _WebsitePollPaused(statusResponse.statusCode == 401 ||
                    statusResponse.statusCode == 403
                ? 'Session expired — sign in again to check status'
                : 'Could not reach the server — reopen this page to retry');
          case PollFailure.fail:
            throw Exception('Generation job not found.');
        }
      }
      consecutiveErrors = 0;

      final status = jsonDecode(statusResponse.body) as Map<String, dynamic>;
      final serverStatus = status['status'] as String?;
      final statusMsg = status['statusMessage'] as String?;
      // The server has always sent its own phase here; it used to be
      // read only to detect 'completed'/'error'. Keeping it is what lets
      // the card tick "Generate site" → "Publish to IPFS" for real
      // instead of guessing.
      final phaseAdvanced =
          advanceServerPhase(_serverPhase[generation.id], serverStatus) !=
              _serverPhase[generation.id];
      _recordServerPhase(generation.id, serverStatus);
      // The three generation passes are reported through statusMessage,
      // so the sub-step is folded in from the same value.
      final nextSub = advanceSubStep(_subStep[generation.id], statusMsg);
      if (nextSub != null) _subStep[generation.id] = nextSub;

      if (statusMsg != null) {
        generation.statusMessage = statusMsg;
        generation.updatedAt = DateTime.now();
        _notify(generation);
      } else if (phaseAdvanced) {
        _notify(generation);
      }

      if (serverStatus == 'completed') {
        generation.resultCid = status['resultCid'] as String?;
        generation.resultGatewayUrl = status['gatewayUrl'] as String?;

        generation.status = WebsiteGenStatus.completed;
        generation.statusMessage = 'Website generated successfully';
        generation.updatedAt = DateTime.now();
        // Read BEFORE _forgetPhase, which clears it: needed further down
        // to decide whether to hand the directory the stable link.
        final wasListed = _listInDirectory[generation.id] ?? false;
        // A completed generation renders every step done regardless of
        // phase, so the transient detail is dead weight from here on.
        // NOT done on the error path — a failed card keeps rendering the
        // step that actually broke.
        _forgetPhase(generation.id);
        _notify(generation);

        await _appendToCloudManifest(generation);
        await _backfillGroupMembership(generation);
        // Result is durable in the manifest now — drop the pending handle.
        await _clearPendingJob(generation.id);

        // Stable link: best-effort, non-blocking like native.
        final cid = generation.resultCid;
        if (cid != null && cid.isNotEmpty) {
          unawaited(WebIpnsService.instance
              .publishLatest(generation.tagId, cid)
              .then((_) async {
            _notify(generation);
            // The front door only exists once the pointer is minted and
            // published, which is AFTER the job completes — so a listed
            // site is created with the raw gateway URL and upgraded to
            // the stable link here. Best-effort: a failure leaves the
            // entry listed with the gateway URL rather than unlisted.
            if (wasListed) {
              try {
                await setDirectoryListing(generation, listed: true);
              } catch (e) {
                debugPrint('Directory link update failed (non-fatal): $e');
              }
            }
          }).catchError((Object e) {
            debugPrint('Stable-link IPNS publish failed (non-fatal): $e');
          }));
        }
        return;
      }
      if (serverStatus == 'error') {
        throw Exception(
            (status['errorMessage'] as String?) ?? 'Generation failed');
      }
      // Still pending/generating/publishing — give up only on a FRESH
      // "still running" answer past the deadline (the server's own 15-min
      // job timeout flips genuinely stuck jobs to 'error' before this).
      if (DateTime.now().isAfter(deadline)) {
        throw Exception('Generation timed out after 20 minutes');
      }
    }
  }

  /// Record every uploaded asset of a completed generation as a group
  /// member in the tag manifest (idempotent — pre-filtered against the
  /// current rows, and tagFile dedupes by remoteKey). This is what makes
  /// assets survive a reload for groups whose files predate the eager
  /// import-time membership rows: they self-heal on their next
  /// generation. Best-effort — a failure never fails the generation.
  Future<void> _backfillGroupMembership(WebsiteGeneration generation) async {
    try {
      final existing = WebTagService.instance
          .filesWithTag(generation.tagId)
          .map((tf) => tf.fileName)
          .toSet();
      for (final a in generation.assets) {
        if (!a.uploaded || existing.contains(a.fileName)) continue;
        await WebTagService.instance.tagFile(
          tagId: generation.tagId,
          remoteKey:
              websiteAssetRemoteKey(generation.tagName, a.fileName),
          fileName: a.fileName,
        );
      }
    } catch (e) {
      debugPrint(
          'WebWebsiteService: membership backfill failed (non-fatal): $e');
    }
  }

  // ── Pending-job persistence (survives a closed tab) ──────────────────
  //
  // Generations live in `liveGenerations` (memory) and only reach the
  // cloud manifest once COMPLETE, so a tab closed mid-generation used to
  // lose the job outright: the server finished and pinned the site, but
  // nothing client-side ever recorded it. This sidecar holds the handful
  // of in-flight jobs — full generation snapshot + jobId — and is cleared
  // the moment the job reaches a terminal state.

  Future<String> _pendingJobsKey() async {
    final pub = await FulaApiService.instance.getPublicKey();
    final uid = sha256
        .convert(utf8.encode(base64Encode(pub)))
        .toString()
        .substring(0, 16);
    return '.fula/website_jobs/$uid.json';
  }

  /// Serialized read-modify-write, same reasoning as the pointer backup:
  /// overlapping writes would download the same base blob and the loser's
  /// upload would erase the winner's entry.
  Future<void> _mutatePendingJobs(
      void Function(Map<String, Map<String, dynamic>> byId) mutate) {
    final next = _pendingChain.then((_) => _doMutatePendingJobs(mutate));
    _pendingChain = next.catchError((_) {});
    return next;
  }

  Future<void> _doMutatePendingJobs(
      void Function(Map<String, Map<String, dynamic>> byId) mutate) async {
    try {
      final kekB64 = await SecureStorageService.instance
          .read(SecureStorageKeys.encryptionKey);
      if (kekB64 == null || kekB64.isEmpty) return;
      final kek = Uint8List.fromList(base64Decode(kekB64));
      final key = await _pendingJobsKey();

      final blobEntries = <List<dynamic>>[];
      for (final blob in await FulaApiService.instance
          .downloadMetadataMerged(_websiteMetadataBucket, key, kek)) {
        try {
          final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
          blobEntries.add(j['jobs'] as List<dynamic>? ?? const []);
        } catch (_) {}
      }
      final byId = mergePendingJobs(blobEntries);
      mutate(byId);

      final writeBucket =
          BucketVersionResolver.writeBucket(_websiteMetadataBucket);
      try {
        await FulaApiService.instance.createBucket(writeBucket);
      } catch (_) {}
      final data = Uint8List.fromList(utf8.encode(jsonEncode({
        'jobs': byId.values.toList(),
        'updatedAt': DateTime.now().toIso8601String(),
      })));
      await FulaApiService.instance.encryptAndUpload(
        writeBucket,
        key,
        data,
        kek,
        contentType: 'application/json',
      );
      await WebListingCache.instance.writeManifest(writeBucket, key, data);
      WebCacheSync.instance.sendInvalidateManifest(writeBucket, key);
    } catch (e) {
      debugPrint('WebWebsiteService: pending-job write failed (non-fatal): $e');
    }
  }

  Future<void> _writePendingJob(WebsiteGeneration generation, String jobId) =>
      _mutatePendingJobs((byId) {
        byId[generation.id] = {
          'generationId': generation.id,
          'jobId': jobId,
          'updatedAt': DateTime.now().toIso8601String(),
          // Snapshot WITHOUT parsedContent (≤30×100KB per generation):
          // resume only needs the job handle + light metadata. A resumed
          // generation's manifest entry then lacks parsedContent for its
          // assets — the recreate flow falls back to the ranged-GET
          // re-parse, never fails.
          'generation': stripAssetParsedContent(generation.toJson()),
        };
      });

  Future<void> _clearPendingJob(String generationId) =>
      _mutatePendingJobs((byId) => byId.remove(generationId));

  /// Re-attach to generations that were still running when this tab was
  /// last closed. Safe to call on every screen load: jobs already being
  /// polled in this tab are skipped, and a job that finished while the tab
  /// was gone resolves on the first poll (poll-first — the deadline is
  /// only consulted after a fresh "still running" answer).
  Future<void> resumePendingJobs() async {
    try {
      final kekB64 = await SecureStorageService.instance
          .read(SecureStorageKeys.encryptionKey);
      if (kekB64 == null || kekB64.isEmpty) return;
      final kek = Uint8List.fromList(base64Decode(kekB64));
      final key = await _pendingJobsKey();

      // SWR read, NOT the direct network path: every pending-jobs
      // mutation write-throughs the cache (_doMutatePendingJobs), so
      // after _clearPendingJob the cached `{jobs:[]}` blob answers
      // "nothing pending" with ZERO network — the common case on every
      // screen open. Cache miss → live fetch (existing 30s timeout).
      // recordUsage:false keeps this background task out of the
      // frecency log and the foreground-activity window. Trade-off:
      // another DEVICE's just-written pending job may wait out the
      // fresh window before this tab sees it — acceptable, resume is a
      // same-device tab-eviction recovery and polls are poll-first.
      final blobEntries = <List<dynamic>>[];
      for (final blob in await WebListingSwr.instance
          .downloadMetadataMergedSwr(_websiteMetadataBucket, key, kek,
              recordUsage: false)) {
        try {
          final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
          blobEntries.add(j['jobs'] as List<dynamic>? ?? const []);
        } catch (_) {}
      }

      for (final entry in mergePendingJobs(blobEntries).values) {
        // Each entry decodes a FULL generation snapshot — yield so this
        // background loop can't monopolize the frame budget.
        await Future<void>.delayed(Duration.zero);
        final jobId = entry['jobId'];
        final genJson = entry['generation'];
        if (jobId is! String || jobId.isEmpty) continue;
        if (genJson is! Map) continue;
        if (_activeJobIds.contains(jobId)) continue;

        final WebsiteGeneration generation;
        try {
          generation = WebsiteGeneration.fromJson(
              genJson.cast<String, dynamic>());
        } catch (_) {
          continue;
        }

        // Adopt into the live list so the card renders while we re-poll.
        final existing =
            liveGenerations.indexWhere((g) => g.id == generation.id);
        if (existing >= 0) {
          if (liveGenerations[existing].status == WebsiteGenStatus.completed) {
            // Already finished in this tab — stale pending entry.
            unawaited(_clearPendingJob(generation.id));
            continue;
          }
          liveGenerations[existing] = generation;
        } else {
          liveGenerations.insert(0, generation);
        }
        generation.status = WebsiteGenStatus.generating;
        generation.statusMessage = 'Reconnecting to your generation...';
        _notify(generation);

        final jwt = await _jwt();
        final aiEndpoint = await SecureStorageService.instance
                .read(SecureStorageKeys.aiEndpointUrl) ??
            _defaultAiEndpoint;

        unawaited(_pollGenerationJob(
          generation,
          jobId,
          jwt,
          aiEndpoint,
          // Anchored to when the job was created, not to now — the server
          // caps generation at 15 min, so a job older than this window is
          // already terminal and the first poll will say so.
          deadline: generation.createdAt.add(kWebsiteGenerationTimeout),
        ).catchError((Object e) {
          generation.status = WebsiteGenStatus.error;
          generation.errorMessage = e.toString();
          generation.updatedAt = DateTime.now();
          _notify(generation);
        }));
      }
    } catch (e) {
      debugPrint('WebWebsiteService: resume pending failed (non-fatal): $e');
    }
  }

  /// Append the completed generation to the same encrypted cloud
  /// manifest the native app syncs/restores ({generations, updatedAt}
  /// at `.fula/websites/{userId}.json`), merge-preserving existing ids.
  Future<void> _appendToCloudManifest(WebsiteGeneration generation) async {
    try {
      final kekB64 = await SecureStorageService.instance
          .read(SecureStorageKeys.encryptionKey);
      if (kekB64 == null || kekB64.isEmpty) return;
      final kek = Uint8List.fromList(base64Decode(kekB64));
      final pub = await FulaApiService.instance.getPublicKey();
      final uid = sha256
          .convert(utf8.encode(base64Encode(pub)))
          .toString()
          .substring(0, 16);
      final key = '.fula/websites/$uid.json';

      final byId = <String, Map<String, dynamic>>{};
      for (final blob in await FulaApiService.instance
          .downloadMetadataMerged(_websiteMetadataBucket, key, kek)) {
        try {
          final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
          for (final g in (j['generations'] as List<dynamic>? ?? const [])) {
            final m = g as Map<String, dynamic>;
            final id = m['id'] as String?;
            if (id != null) byId.putIfAbsent(id, () => m);
          }
        } catch (_) {}
      }
      byId[generation.id] = generation.toJson();

      final writeBucket =
          BucketVersionResolver.writeBucket(_websiteMetadataBucket);
      try {
        await FulaApiService.instance.createBucket(writeBucket);
      } catch (_) {}
      // Keep-freshest strip (website_manifest_logic.dart): applied to
      // the MERGED set, so bloated historical entries shrink on the
      // first append after deploy — not just the new generation. The
      // native writer (WebsiteService.syncToCloud) applies the same
      // strip, or the two writers would oscillate.
      final data = Uint8List.fromList(utf8.encode(jsonEncode({
        'generations': stripParsedContentKeepFreshest(byId.values.toList()),
        'updatedAt': DateTime.now().toIso8601String(),
      })));
      await FulaApiService.instance.encryptAndUpload(
        writeBucket,
        key,
        data,
        kek,
        contentType: 'application/json',
      );
      // Write-through to the SWR cache (read by WebFeatures.loadWebsites).
      await WebListingCache.instance.writeManifest(writeBucket, key, data);
      WebCacheSync.instance.sendInvalidateManifest(writeBucket, key);
      debugPrint('WebWebsiteService: manifest synced (${byId.length} gens)');
    } catch (e) {
      debugPrint('WebWebsiteService: manifest sync failed (non-fatal): $e');
    }
  }
}
