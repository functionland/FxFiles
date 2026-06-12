import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/models/website_group_pointer.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/ipfs_gateway_helper.dart';
import 'package:fula_files/core/services/ipns_name.dart';
import 'package:fula_files/core/services/ipns_record.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/website_prompt_builder.dart';
import 'package:fula_files/core/utils/file_type_utils.dart' as file_utils;
import 'package:fula_files/web/services/web_cache_sync.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';
import 'package:fula_files/web/services/web_tag_service.dart';

/// One asset for a website generation: either picked in-browser
/// (bytes in memory) or carried over from a previous generation
/// (CID-backed — bytes are fetched from the IPFS gateway at upload
/// time, so Recreate / re-generate reuses the group's existing assets
/// exactly like the app).
class WebPickedAsset {
  final String fileName;

  /// Picked-file content; for CID-backed assets this starts null and is
  /// filled by the upload phase after the gateway fetch (so the parse
  /// phase can read text content either way).
  Uint8List? bytes;
  final String? cid;
  final String? gatewayUrl;
  String note;

  WebPickedAsset({
    required this.fileName,
    this.bytes,
    this.cid,
    this.gatewayUrl,
    this.note = '',
  }) : assert(bytes != null || cid != null);

  bool get isCidBacked => bytes == null;

  /// Size when known up front (picked files); CID-backed assets report
  /// null until fetched.
  int? get knownSize => bytes?.length;

  String get type => file_utils.classifyFileType(fileName);

  /// Public gateway URL for CID-backed assets (recorded URL when
  /// present, else rebuilt from the CID via the configured template).
  /// Null for picked-only assets.
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
  /// concurrent callers await the same download.
  Future<void> load({bool force = false}) {
    if (_loaded && !force) return Future.value();
    final inFlight = _loadFuture;
    if (inFlight != null) return inFlight;
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
    for (final blob in await FulaApiService.instance
        .downloadMetadataMerged(_metadataBucket, _pointerObjectKey(uid), kek)) {
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
  static const String _defaultApiGateway = 'https://s3.cloud.fx.land';
  static const String _websiteMetadataBucket = 'website-metadata';

  static const _uuid = Uuid();

  /// In-flight generations for this browser session (completed ones
  /// also land in the cloud manifest). Screens listen to this service
  /// (ChangeNotifier) for live status updates.
  final List<WebsiteGeneration> liveGenerations = [];

  void _notify(WebsiteGeneration g) => notifyListeners();

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
    liveGenerations.insert(0, generation);
    _notify(generation);

    // Run asynchronously, native-style.
    unawaited(_runPipeline(generation, websiteName, picked));
    return generation;
  }

  Future<void> _runPipeline(WebsiteGeneration generation, String websiteName,
      List<WebPickedAsset> picked) async {
    try {
      await _uploadPhase(generation, websiteName, picked);
      _parsePhase(generation, picked);
      await _generatePhase(generation);
    } catch (e) {
      generation.status = WebsiteGenStatus.error;
      generation.errorMessage = e.toString();
      generation.updatedAt = DateTime.now();
      _notify(generation);
      debugPrint('Web website generation failed: $e');
    }
  }

  Future<void> _uploadPhase(WebsiteGeneration generation, String websiteName,
      List<WebPickedAsset> picked) async {
    final jwt = await _jwt();
    final apiGateway = await SecureStorageService.instance
            .read(SecureStorageKeys.apiGatewayUrl) ??
        _defaultApiGateway;

    // Ensure bucket (idempotent PUT, native pattern).
    try {
      await http.put(
        Uri.parse('$apiGateway/$kWebsiteAssetBucket'),
        headers: {'Authorization': 'Bearer $jwt'},
      );
    } catch (e) {
      debugPrint('Bucket creation note: $e');
    }

    int failedCount = 0;
    int uploadedCount = 0;
    int totalUploadedBytes = 0;
    final skipReasons = <String>[];

    for (var i = 0; i < generation.assets.length; i++) {
      final asset = generation.assets[i];
      final dot = asset.fileName.lastIndexOf('.');
      final ext = dot >= 0 ? asset.fileName.substring(dot) : '';
      final perTypeCap = websiteMaxFileSizeBytesForExt(ext);

      if (perTypeCap == 0) {
        asset.uploaded = false;
        failedCount++;
        skipReasons.add('${asset.fileName}: unsupported type');
        continue;
      }
      if (uploadedCount >= kWebsiteMaxFilesPerJob) {
        asset.uploaded = false;
        failedCount++;
        skipReasons.add('${asset.fileName}: 10-file cap reached');
        continue;
      }

      // CID-backed assets (carried over from a previous generation)
      // fetch their plaintext from the IPFS gateway first — website
      // assets are public, so this needs no keys.
      var bytes = picked[i].bytes;
      if (bytes == null) {
        generation.statusMessage =
            'Fetching asset ${i + 1}/${generation.totalAssets}...';
        generation.updatedAt = DateTime.now();
        _notify(generation);
        try {
          final url = (picked[i].gatewayUrl?.isNotEmpty ?? false)
              ? picked[i].gatewayUrl!
              : IpfsGatewayHelper.buildUrlForCid(picked[i].cid!);
          final resp = await http
              .get(Uri.parse(url))
              .timeout(const Duration(minutes: 2));
          if (resp.statusCode != 200) {
            throw Exception('HTTP ${resp.statusCode}');
          }
          bytes = resp.bodyBytes;
          picked[i].bytes = bytes; // parse phase reads text from here
        } catch (e) {
          debugPrint('Asset fetch failed for ${asset.fileName}: $e');
          asset.uploaded = false;
          failedCount++;
          skipReasons.add('${asset.fileName}: fetch failed');
          continue;
        }
      }
      if (bytes.length > perTypeCap) {
        final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
        final capMb = (perTypeCap / (1024 * 1024)).toStringAsFixed(0);
        asset.uploaded = false;
        failedCount++;
        skipReasons
            .add('${asset.fileName}: ${mb}MB exceeds ${capMb}MB cap for $ext');
        continue;
      }
      if (totalUploadedBytes + bytes.length > kWebsiteMaxTotalUploadBytes) {
        asset.uploaded = false;
        failedCount++;
        skipReasons.add('${asset.fileName}: 50MB total cap reached');
        continue;
      }

      generation.statusMessage =
          'Uploading asset ${i + 1}/${generation.totalAssets}...';
      generation.updatedAt = DateTime.now();
      _notify(generation);

      try {
        final key = '$websiteName/${asset.fileName}';
        final contentType =
            lookupMimeType(asset.fileName) ?? 'application/octet-stream';
        final response = await http.put(
          Uri.parse('$apiGateway/$kWebsiteAssetBucket/$key'),
          headers: {
            'Authorization': 'Bearer $jwt',
            'Content-Type': contentType,
          },
          body: bytes,
        );
        if (response.statusCode != 200 && response.statusCode != 201) {
          throw Exception(
              'Upload failed (${response.statusCode}): ${response.body}');
        }
        final etag = response.headers['etag'];
        if (etag == null || etag.isEmpty) {
          throw Exception('Upload succeeded but no CID returned in etag');
        }
        final cid = etag.replaceAll('"', '');
        asset.cid = cid;
        asset.gatewayUrl = IpfsGatewayHelper.buildUrlForCid(cid);
        asset.uploaded = true;
        uploadedCount++;
        totalUploadedBytes += bytes.length;
        generation.uploadedAssets = uploadedCount;
        _notify(generation);
      } catch (e) {
        debugPrint('Failed to upload asset ${asset.fileName}: $e');
        asset.uploaded = false;
        failedCount++;
        skipReasons.add('${asset.fileName}: upload failed');
      }
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

  /// Browser-side content extraction. Text files decode directly (same
  /// as native's direct read); everything else gets the same
  /// placeholder the DESKTOP app produces (no ML Kit there either).
  void _parsePhase(WebsiteGeneration generation, List<WebPickedAsset> picked) {
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
            final raw = picked[i].bytes;
            if (raw != null && textExts.contains(ext)) {
              final text = utf8.decode(raw, allowMalformed: true);
              content =
                  text.length > 2000 ? '${text.substring(0, 2000)}...' : text;
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

    Duration pollInterval = const Duration(seconds: 2);
    const maxPollInterval = Duration(seconds: 10);
    const timeout = Duration(minutes: 5);
    final deadline = DateTime.now().add(timeout);
    int consecutiveErrors = 0;

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollInterval);
      if (pollInterval < maxPollInterval) {
        pollInterval = Duration(
          milliseconds: (pollInterval.inMilliseconds * 1.5)
              .toInt()
              .clamp(0, maxPollInterval.inMilliseconds),
        );
      }

      final statusResponse = await http.get(
        Uri.parse('$aiEndpoint/api/v1/status/$jobId'),
        headers: {'Authorization': 'Bearer $jwt'},
      );

      if (statusResponse.statusCode != 200) {
        consecutiveErrors++;
        if (statusResponse.statusCode == 401 ||
            statusResponse.statusCode == 403) {
          throw Exception('Authentication expired. Please log in again.');
        }
        if (statusResponse.statusCode == 404) {
          throw Exception('Generation job not found.');
        }
        if (consecutiveErrors >= 5) {
          throw Exception(
              'Status check failed after $consecutiveErrors consecutive errors');
        }
        continue;
      }
      consecutiveErrors = 0;

      final status = jsonDecode(statusResponse.body) as Map<String, dynamic>;
      final serverStatus = status['status'] as String?;
      final statusMsg = status['statusMessage'] as String?;
      if (statusMsg != null) {
        generation.statusMessage = statusMsg;
        generation.updatedAt = DateTime.now();
        _notify(generation);
      }

      if (serverStatus == 'completed') {
        generation.resultCid = status['resultCid'] as String?;
        generation.resultGatewayUrl = status['gatewayUrl'] as String?;

        generation.status = WebsiteGenStatus.completed;
        generation.statusMessage = 'Website generated successfully';
        generation.updatedAt = DateTime.now();
        _notify(generation);

        await _appendToCloudManifest(generation);

        // Stable link: best-effort, non-blocking like native.
        final cid = generation.resultCid;
        if (cid != null && cid.isNotEmpty) {
          unawaited(WebIpnsService.instance
              .publishLatest(generation.tagId, cid)
              .then((_) => _notify(generation))
              .catchError((Object e) {
            debugPrint('Stable-link IPNS publish failed (non-fatal): $e');
          }));
        }
        return;
      }
      if (serverStatus == 'error') {
        throw Exception(
            (status['errorMessage'] as String?) ?? 'Generation failed');
      }
    }
    throw Exception('Generation timed out after 5 minutes');
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
      final data = Uint8List.fromList(utf8.encode(jsonEncode({
        'generations': byId.values.toList(),
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
