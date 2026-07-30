import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/social_post_record.dart';
import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/social_post_logic.dart';
import 'package:fula_files/web/services/web_cache_sync.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';

/// Social-post generation for the web app: submits the job, polls it
/// (poll-first-deadline-after — a backgrounded tab recovers on resume),
/// and — unlike the website-gen flow — persists the job handle to an
/// encrypted cloud sidecar (`.fula/website_social/{userId16}.json`) at
/// 202-time, so a full tab reload RESUMES polling instead of losing the
/// job. Also fronts the backend's Buffer proxy.
class WebSocialPostService extends ChangeNotifier {
  WebSocialPostService._();
  static final WebSocialPostService instance = WebSocialPostService._();

  static const String _defaultAiEndpoint = 'https://ai.cloud.fx.land';
  static const String _metadataBucket = 'website-metadata';

  /// One record per website generation (re-runs overwrite).
  final Map<String, SocialPostRecord> _byGenerationId = {};

  /// Job ids with a live poll loop in THIS tab — prevents duplicate loops
  /// (a second tab polling the same job is harmless: idempotent GETs).
  final Set<String> _activeJobIds = {};

  /// Generations with a submit POST in flight — closes the double-click
  /// window before the 202 lands (the Idempotency-Key closes the rest).
  final Set<String> _submitting = {};

  /// Idempotency key per generation, kept across AMBIGUOUS failures
  /// (timeout / network) so a retry replays the same server job instead of
  /// charging a second one; cleared once the server gave a definitive
  /// answer (202 or an HTTP error status).
  final Map<String, String> _pendingIdemKeys = {};

  static const _uuid = Uuid();

  /// Serialized sidecar writes (same chain pattern as the IPNS backup):
  /// overlapping read-modify-write uploads would drop each other's entries.
  Future<void> _sidecarChain = Future.value();

  bool _loaded = false;
  Future<void>? _loading;

  SocialPostRecord? recordFor(String generationId) =>
      _byGenerationId[generationId];

  bool isGenerating(String generationId) =>
      _byGenerationId[generationId]?.status.isRunning ?? false;

  // ── Load + resume ────────────────────────────────────────────────────

  /// Read the sidecar and resume any interrupted poll loops. Single-flight;
  /// safe to call from every detail-screen load.
  Future<void> load({bool force = false}) {
    if (_loaded && !force) return Future.value();
    return _loading ??= _doLoad().whenComplete(() => _loading = null);
  }

  Future<void> _doLoad() async {
    try {
      final kek = await _kek();
      if (kek == null) return;
      final key = await _sidecarKey();
      final blobEntries = <List<dynamic>>[];
      for (final blob in await FulaApiService.instance
          .downloadMetadataMerged(_metadataBucket, key, kek)) {
        try {
          final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
          blobEntries.add(j['posts'] as List<dynamic>? ?? const []);
        } catch (_) {}
      }
      final merged = mergeSocialPosts([
        ...blobEntries,
        [for (final r in _byGenerationId.values) r.toJson()],
      ]);
      _byGenerationId.clear();
      for (final m in merged.values) {
        final record = SocialPostRecord.fromJson(m);
        if (record != null) _byGenerationId[record.generationId] = record;
      }
      _loaded = true;
      notifyListeners();
      _resumePending();
    } catch (e) {
      debugPrint('WebSocialPostService: load failed (non-fatal): $e');
    }
  }

  void _resumePending() {
    final now = DateTime.now();
    for (final record in List.of(_byGenerationId.values)) {
      final action = socialResumeAction(
        status: record.status.wire,
        jobId: record.jobId,
        createdAt: record.createdAt,
        now: now,
      );
      switch (action) {
        case SocialResumeAction.resumePoll:
          if (!_activeJobIds.contains(record.jobId)) {
            unawaited(_pollJob(record, immediateFirstPoll: true));
          }
        case SocialResumeAction.markInterrupted:
          _update(record.copyWith(
            status: SocialPostStatus.error,
            errorMessage: 'Interrupted before the job started',
            statusMessage: 'Social post generation failed',
          ));
          unawaited(_writeSidecar());
        case SocialResumeAction.none:
          break;
      }
    }
  }

  // ── Pricing ──────────────────────────────────────────────────────────

  /// Social price in FULA; null = unknown (fail-soft) or feature disabled
  /// server-side (the pricing endpoint returns null for disabled). Uses the
  /// CONFIGURED endpoint — the price the user consents to must come from
  /// the server that will charge it.
  Future<int?> fetchSocialPricing() async {
    try {
      final aiEndpoint = await _aiEndpoint();
      final response = await http
          .get(Uri.parse('$aiEndpoint/api/v1/pricing'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final price = body['socialPostPriceFula'];
        if (price is num && price >= 0) return price.toInt();
      }
    } catch (_) {}
    return null;
  }

  // ── Generation ───────────────────────────────────────────────────────

  /// Submit a social-post job for [generation]. Throws with a
  /// user-readable message on 402/429/503/network errors (mirrors the
  /// website-gen mappings). On 202 the pending record + jobId are written
  /// to the sidecar BEFORE polling starts, so a reload can resume.
  Future<void> startGeneration({
    required WebsiteGeneration generation,
    String? frontDoorUrl,
  }) async {
    if (isGenerating(generation.id) || _submitting.contains(generation.id)) {
      throw Exception('A social post is already being generated');
    }
    final websiteUrl =
        resolveSocialWebsiteUrl(frontDoorUrl, generation.gatewayUrl);
    if (websiteUrl == null) {
      throw Exception('This generation has no public website URL yet');
    }

    _submitting.add(generation.id);
    try {
      await _submitGeneration(generation, websiteUrl);
    } finally {
      _submitting.remove(generation.id);
    }
  }

  Future<void> _submitGeneration(
      WebsiteGeneration generation, String websiteUrl) async {
    final jwt = await _jwt();
    final aiEndpoint = await _aiEndpoint();
    final payload = buildSocialGeneratePayload(
      generationId: generation.id,
      websiteUrl: websiteUrl,
      userPrompt: socialUserPrompt(generation.prompt),
      assets: [
        for (final a in generation.assets)
          if (a.uploaded && (a.gatewayUrl ?? '').isNotEmpty)
            (fileName: a.fileName, type: a.type, url: a.gatewayUrl!),
      ],
      displayName: generation.tagName,
    );

    // A POST that succeeds server-side but times out client-side must not
    // create (and charge) a second job when retried — reuse the same key
    // until the server answers definitively.
    final idemKey = _pendingIdemKeys[generation.id] ??= _uuid.v4();

    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$aiEndpoint/api/v1/social/generate'),
            headers: {
              'Authorization': 'Bearer $jwt',
              'Content-Type': 'application/json',
              'Idempotency-Key': idemKey,
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw Exception('Request timed out. Please try again.');
    }
    // Any HTTP response is definitive — the next attempt is a NEW job.
    _pendingIdemKeys.remove(generation.id);

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
    if (response.statusCode == 503) {
      throw Exception(
          'Social posts are not available right now. Please try again later.');
    }
    if (response.statusCode != 202) {
      throw Exception(
          'Social post request failed (${response.statusCode}): ${response.body}');
    }

    final jobId =
        (jsonDecode(response.body) as Map<String, dynamic>)['jobId'] as String;
    final now = DateTime.now();
    final record = SocialPostRecord(
      generationId: generation.id,
      tagId: generation.tagId,
      jobId: jobId,
      status: SocialPostStatus.pending,
      statusMessage: 'Queued for social post generation',
      websiteUrl: websiteUrl,
      createdAt: now,
      updatedAt: now,
    );
    _update(record);
    await _writeSidecar(); // survives a reload from this point on
    unawaited(_pollJob(record));
  }

  /// Poll loop — website-gen shape verbatim: backoff 2s ×1.5 capped 10s,
  /// 5 consecutive non-200s abort, 401/403/404 terminal, and the deadline
  /// (createdAt + 10 min; server timeout is 5) is checked ONLY after a
  /// fresh "still running" answer, so a frozen background tab polls once
  /// more on resume instead of giving up.
  Future<void> _pollJob(SocialPostRecord record,
      {bool immediateFirstPoll = false}) async {
    final jobId = record.jobId;
    if (jobId == null || jobId.isEmpty) return;
    if (!_activeJobIds.add(jobId)) return;
    try {
      final jwt = await _jwt();
      final aiEndpoint = await _aiEndpoint();
      final deadline = record.createdAt.add(const Duration(minutes: 10));
      Duration pollInterval = immediateFirstPoll
          ? Duration.zero
          : const Duration(seconds: 2);
      int consecutiveErrors = 0;

      while (true) {
        await Future.delayed(pollInterval);
        pollInterval = nextSocialPollInterval(
            pollInterval == Duration.zero
                ? const Duration(seconds: 2)
                : pollInterval);

        // Per-request timeout: a single hung connection must not freeze the
        // loop forever (the deadline is only evaluated between polls).
        final http.Response statusResponse;
        try {
          statusResponse = await http.get(
            Uri.parse('$aiEndpoint/api/v1/social/status/$jobId'),
            headers: {'Authorization': 'Bearer $jwt'},
          ).timeout(const Duration(seconds: 20));
        } on TimeoutException {
          consecutiveErrors++;
          if (consecutiveErrors >= 5) {
            throw Exception(
                'Status check failed after $consecutiveErrors consecutive errors');
          }
          continue;
        }

        if (statusResponse.statusCode != 200) {
          consecutiveErrors++;
          if (statusResponse.statusCode == 401 ||
              statusResponse.statusCode == 403) {
            throw Exception('Authentication expired. Please log in again.');
          }
          if (statusResponse.statusCode == 404) {
            throw Exception('Social post job not found (it may have expired)');
          }
          if (consecutiveErrors >= 5) {
            throw Exception(
                'Status check failed after $consecutiveErrors consecutive errors');
          }
          continue;
        }
        consecutiveErrors = 0;

        final status =
            jsonDecode(statusResponse.body) as Map<String, dynamic>;
        final serverStatus = SocialPostStatus.fromWire(
            status['status'] as String?);
        final current = _byGenerationId[record.generationId] ?? record;

        if (serverStatus == SocialPostStatus.completed) {
          final image = status['image'] as Map<String, dynamic>?;
          _update(current.copyWith(
            status: SocialPostStatus.completed,
            statusMessage:
                status['statusMessage'] as String? ?? 'Social post ready',
            imageCid: image?['cid'] as String?,
            imageUrl: image?['url'] as String?,
            captions: SocialCaptions.fromJson(
                (status['captions'] as Map?)?.cast<String, dynamic>()),
          ));
          await _writeSidecar();
          return;
        }
        if (serverStatus == SocialPostStatus.error) {
          throw Exception(
              (status['errorMessage'] as String?) ?? 'Social post failed');
        }
        _update(current.copyWith(
          status: serverStatus,
          statusMessage: status['statusMessage'] as String?,
        ));
        if (DateTime.now().isAfter(deadline)) {
          throw Exception('Social post generation timed out');
        }
      }
    } catch (e) {
      final current = _byGenerationId[record.generationId] ?? record;
      _update(current.copyWith(
        status: SocialPostStatus.error,
        errorMessage: e is Exception
            ? e.toString().replaceFirst('Exception: ', '')
            : '$e',
        statusMessage: 'Social post generation failed',
      ));
      await _writeSidecar();
    } finally {
      _activeJobIds.remove(jobId);
    }
  }

  void _update(SocialPostRecord record) {
    _byGenerationId[record.generationId] = record;
    notifyListeners();
  }

  // ── Sidecar persistence ──────────────────────────────────────────────

  Future<void> _writeSidecar() {
    final next = _sidecarChain.then((_) => _doWriteSidecar());
    _sidecarChain = next.catchError((_) {});
    return next;
  }

  Future<void> _doWriteSidecar() async {
    try {
      final kek = await _kek();
      if (kek == null) return;
      final key = await _sidecarKey();

      final blobEntries = <List<dynamic>>[];
      for (final blob in await FulaApiService.instance
          .downloadMetadataMerged(_metadataBucket, key, kek)) {
        try {
          final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
          blobEntries.add(j['posts'] as List<dynamic>? ?? const []);
        } catch (_) {}
      }
      final merged = mergeSocialPosts([
        ...blobEntries,
        [for (final r in _byGenerationId.values) r.toJson()],
      ]);

      final writeBucket = BucketVersionResolver.writeBucket(_metadataBucket);
      try {
        await FulaApiService.instance.createBucket(writeBucket);
      } catch (_) {}
      final data = Uint8List.fromList(utf8.encode(jsonEncode({
        'posts': merged.values.toList(),
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
      debugPrint(
          'WebSocialPostService: sidecar synced (${merged.length} posts)');
    } catch (e) {
      debugPrint('WebSocialPostService: sidecar write failed (non-fatal): $e');
    }
  }

  Future<Uint8List?> _kek() async {
    final kekB64 = await SecureStorageService.instance
        .read(SecureStorageKeys.encryptionKey);
    if (kekB64 == null || kekB64.isEmpty) return null;
    return Uint8List.fromList(base64Decode(kekB64));
  }

  Future<String> _sidecarKey() async {
    final pub = await FulaApiService.instance.getPublicKey();
    final uid = sha256
        .convert(utf8.encode(base64Encode(pub)))
        .toString()
        .substring(0, 16);
    return '.fula/website_social/$uid.json';
  }

  Future<String> _jwt() async {
    final jwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    if (jwt == null || jwt.isEmpty) {
      throw Exception('No API key configured');
    }
    return jwt;
  }

  Future<String> _aiEndpoint() async =>
      await SecureStorageService.instance
          .read(SecureStorageKeys.aiEndpointUrl) ??
      _defaultAiEndpoint;

  // ── Buffer ───────────────────────────────────────────────────────────

  Future<bool> hasBufferKey() async {
    final key = await SecureStorageService.instance
        .read(SecureStorageKeys.bufferApiKey);
    return key != null && key.isNotEmpty;
  }

  Future<void> saveBufferKey(String key) => SecureStorageService.instance
      .write(SecureStorageKeys.bufferApiKey, key.trim());

  Future<void> deleteBufferKey() =>
      SecureStorageService.instance.delete(SecureStorageKeys.bufferApiKey);

  Future<String> _bufferKey() async {
    final key = await SecureStorageService.instance
        .read(SecureStorageKeys.bufferApiKey);
    if (key == null || key.isEmpty) {
      throw Exception('Buffer is not connected. Add your API key in Settings.');
    }
    return key;
  }

  /// List the user's Buffer channels through the backend proxy.
  /// [overrideKey] lets the settings screen test a key before saving it.
  Future<List<({String id, String name, String service})>> fetchBufferChannels(
      {String? overrideKey}) async {
    final bufferToken = overrideKey ?? await _bufferKey();
    final body = await _bufferProxy('channels', {'bufferToken': bufferToken});
    final channels = body['channels'] as List<dynamic>? ?? const [];
    return [
      for (final c in channels.whereType<Map>())
        (
          id: c['id'] as String? ?? '',
          name: c['name'] as String? ?? '',
          service: c['service'] as String? ?? 'unknown',
        )
    ];
  }

  /// Queue [text] + [imageUrl] to [channelIds]; per-channel outcomes.
  Future<List<({String channelId, bool ok, String? error})>> postToBuffer({
    required List<String> channelIds,
    required String text,
    required String imageUrl,
  }) async {
    final bufferToken = await _bufferKey();
    final body = await _bufferProxy('post', {
      'bufferToken': bufferToken,
      'channelIds': channelIds,
      'text': text,
      'imageUrl': imageUrl,
    });
    final results = body['results'] as List<dynamic>? ?? const [];
    return [
      for (final r in results.whereType<Map>())
        (
          channelId: r['channelId'] as String? ?? '',
          ok: r['ok'] == true,
          error: r['error'] as String?,
        )
    ];
  }

  Future<Map<String, dynamic>> _bufferProxy(
      String action, Map<String, dynamic> payload) async {
    final jwt = await _jwt();
    final aiEndpoint = await _aiEndpoint();
    // Posting runs sequentially per channel server-side (up to 10 × 15s),
    // so the post timeout must exceed the backend's worst case — a client
    // timeout mid-run would misreport channels Buffer already accepted.
    final timeout = action == 'post'
        ? const Duration(seconds: 240)
        : const Duration(seconds: 45);
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$aiEndpoint/api/v1/social/buffer/$action'),
            headers: {
              'Authorization': 'Bearer $jwt',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw Exception(action == 'post'
          ? 'Buffer request timed out — check your Buffer queue before retrying.'
          : 'Buffer request timed out. Please try again.');
    }
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    String message = 'Buffer request failed (${response.statusCode})';
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['error'] is String) message = body['error'] as String;
    } catch (_) {}
    throw Exception(message);
  }
}
