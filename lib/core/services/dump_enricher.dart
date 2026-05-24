import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'package:fula_files/core/models/dump_item.dart';

/// Result emitted by [DumpEnricher.enrich]. Any field may be null; the
/// UI falls back to `originalName` / a category icon / `size · category`
/// as appropriate.
class DumpEnrichmentResult {
  final String? title;
  final String? description;
  final String? thumbnailPath;
  final List<String> mlLabels;
  final DumpEnrichmentStatus status;

  const DumpEnrichmentResult({
    this.title,
    this.description,
    this.thumbnailPath,
    this.mlLabels = const <String>[],
    required this.status,
  });

  static const DumpEnrichmentResult failed =
      DumpEnrichmentResult(status: DumpEnrichmentStatus.failed);
}

/// Generates auto-title / auto-description / thumbnail for a
/// [DumpItem] using on-device tools only (per the plan's "no large
/// LLM" constraint).
///
/// Runs on the **main isolate** (revision R2): WM background isolates
/// lack a full `WidgetsFlutterBinding` and platform-channel availability
/// for ML Kit / `video_thumbnail` / canvas. The DumpService schedules
/// each enrichment via `unawaited` after the item is ingested and after
/// each successful upload — failures are non-fatal and leave the item
/// in `enrichmentStatus = failed` with the UI falling back to filename
/// + size.
class DumpEnricher {
  DumpEnricher._();
  static final DumpEnricher instance = DumpEnricher._();

  // Subdirectory of `<documents>/` where downscaled thumbnails live.
  static const String _kThumbsDir = 'dump_thumbs';
  static const int _kThumbMaxLongEdge = 256;
  static const int _kThumbJpegQuality = 80;

  // Link enrichment — R14 SSRF + privacy guards.
  static const Duration _kLinkTimeout = Duration(seconds: 5);
  static const int _kLinkMaxBodyBytes = 1024 * 1024;
  static const int _kLinkImageMaxBytes = 5 * 1024 * 1024;
  static const int _kLinkMaxRedirects = 3;
  static const String _kLinkUserAgent = 'FxFiles-Dump/1.0';

  /// Note title length cap (first non-empty line, trimmed to this).
  static const int _kNoteTitleMaxChars = 60;
  static const int _kNoteDescMaxChars = 200;

  // Test seam — assignable image labeler stub for unit tests so we
  // don't spin up the on-device ML Kit pipeline in `flutter test`.
  @visibleForTesting
  Future<List<ImageLabel>> Function(String filePath)? imageLabelOverride;

  // Test seam — assignable http client so the SSRF guard path is
  // testable without network access.
  @visibleForTesting
  http.Client? linkHttpClientOverride;

  // Test seam — overrides DNS lookups inside `_isPublicHttpsTarget`,
  // so SSRF-guard behaviour can be exercised in environments where
  // real DNS is unavailable or unreliable (CI sandboxes, offline dev
  // boxes). Production code leaves this null and uses the real
  // `InternetAddress.lookup`.
  @visibleForTesting
  Future<List<InternetAddress>> Function(String host)? dnsLookupOverride;

  // Test seam — override the destination dir for thumbnails so tests
  // can isolate filesystem effects under tmp.
  @visibleForTesting
  Future<Directory> Function()? thumbsDirOverride;

  /// Enrich a single item. Returns the new title/description/thumb +
  /// final [DumpEnrichmentStatus].
  Future<DumpEnrichmentResult> enrich(DumpItem item) async {
    try {
      switch (item.category) {
        case DumpCategory.link:
          return await _enrichLink(item);
        case DumpCategory.note:
          return await _enrichNote(item);
        case DumpCategory.screenshot:
        case DumpCategory.image:
          return await _enrichImage(item);
        case DumpCategory.video:
          return await _enrichVideo(item);
        case DumpCategory.audio:
          return _enrichAudio(item);
        case DumpCategory.document:
          return _enrichDocument(item);
        case DumpCategory.file:
        case DumpCategory.other:
          return _enrichFile(item);
      }
    } catch (e, st) {
      debugPrint('DumpEnricher.enrich(${item.id}) failed: $e\n$st');
      return DumpEnrichmentResult.failed;
    }
  }

  // ----------------------------------------------------------------
  // Per-category strategies
  // ----------------------------------------------------------------

  Future<DumpEnrichmentResult> _enrichLink(DumpItem item) async {
    final raw = item.textPayload?.trim();
    if (raw == null || raw.isEmpty) {
      return DumpEnrichmentResult(
        title: item.originalName,
        description: 'Link',
        status: DumpEnrichmentStatus.done,
      );
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      return DumpEnrichmentResult(
        title: raw,
        description: 'Link',
        status: DumpEnrichmentStatus.done,
      );
    }

    // R14: scheme allowlist + private-IP block + redirect cap + timeout
    // + body cap + generic User-Agent.
    final safe = await _isPublicHttpsTarget(uri);
    if (!safe) {
      return DumpEnrichmentResult(
        title: uri.host.isNotEmpty ? uri.host : raw,
        description: raw,
        status: DumpEnrichmentStatus.done,
      );
    }

    _LinkMetadata metadata;
    // Host-specific anti-scraper bypass:
    //  * X (Twitter): try the syndication API first, fall back to
    //    Twitterbot UA — anonymous FxFiles-Dump UA gets blank HTML.
    //  * Facebook: directly use facebookexternalhit/1.1 — same UA
    //    Meta's own preview crawler uses, which is what Facebook
    //    serves OG metadata to. Without this we get the FB login
    //    wall HTML, which has no useful OG.
    //  * Everything else: default FxFiles-Dump/1.0.
    final tweetId = _extractTweetId(uri);
    if (tweetId != null) {
      metadata = await _fetchTweetSyndication(tweetId);
      if (metadata.title == null &&
          metadata.description == null &&
          metadata.imageUrl == null) {
        metadata = await _fetchLinkMetadata(
          uri,
          userAgent: 'Twitterbot/1.0',
        );
      }
    } else if (_isFacebookHost(uri.host)) {
      metadata = await _fetchLinkMetadata(
        uri,
        userAgent: 'facebookexternalhit/1.1',
      );
    } else {
      metadata = await _fetchLinkMetadata(uri);
    }

    String? thumbnailPath;
    if (metadata.imageUrl != null) {
      thumbnailPath =
          await _fetchAndCacheLinkImage(metadata.imageUrl!, item.id);
    }

    return DumpEnrichmentResult(
      title: (metadata.title != null && metadata.title!.isNotEmpty)
          ? metadata.title
          : uri.host,
      description: (metadata.description != null &&
              metadata.description!.isNotEmpty)
          ? metadata.description
          : raw,
      thumbnailPath: thumbnailPath,
      status: DumpEnrichmentStatus.done,
    );
  }

  Future<DumpEnrichmentResult> _enrichNote(DumpItem item) async {
    final payload = item.textPayload ?? await _readTextFile(item.localCachePath);
    if (payload == null || payload.trim().isEmpty) {
      return DumpEnrichmentResult(
        title: item.originalName,
        description: '0 bytes · Note',
        status: DumpEnrichmentStatus.done,
      );
    }
    final lines = payload.split(RegExp(r'\r?\n'));
    String firstLine = '';
    for (final line in lines) {
      final t = line.trim();
      if (t.isNotEmpty) {
        firstLine = t;
        break;
      }
    }
    if (firstLine.isEmpty) {
      firstLine = 'Note';
    }
    if (firstLine.length > _kNoteTitleMaxChars) {
      firstLine = '${firstLine.substring(0, _kNoteTitleMaxChars - 1)}…';
    }
    final desc = payload.length <= _kNoteDescMaxChars
        ? payload.trim()
        : '${payload.trim().substring(0, _kNoteDescMaxChars - 1)}…';
    return DumpEnrichmentResult(
      title: firstLine,
      description: desc,
      status: DumpEnrichmentStatus.done,
    );
  }

  Future<DumpEnrichmentResult> _enrichImage(DumpItem item) async {
    final file = File(item.localCachePath);
    if (!await file.exists()) {
      return DumpEnrichmentResult.failed;
    }

    // ML Kit labels — opt-out via test seam, opt-out on failure.
    List<ImageLabel> labels = const <ImageLabel>[];
    try {
      if (imageLabelOverride != null) {
        labels = await imageLabelOverride!(item.localCachePath);
      } else {
        final labeler = ImageLabeler(
          options: ImageLabelerOptions(confidenceThreshold: 0.6),
        );
        try {
          labels = await labeler.processImage(
            InputImage.fromFilePath(item.localCachePath),
          );
        } finally {
          await labeler.close();
        }
      }
    } catch (e) {
      debugPrint('DumpEnricher: ML Kit labeling failed: $e');
      labels = const <ImageLabel>[];
    }

    final topLabels =
        labels.take(3).map((l) => l.label).toList(growable: false);

    String? thumbnailPath;
    try {
      thumbnailPath = await _writeDownscaledImageThumb(file, item.id);
    } catch (e) {
      debugPrint('DumpEnricher: image thumb failed: $e');
    }

    String title;
    if (item.category == DumpCategory.screenshot) {
      title = 'Screenshot';
    } else if (topLabels.isNotEmpty) {
      title = _titleCase(topLabels.first);
    } else {
      title = p.basenameWithoutExtension(item.originalName);
    }

    final description = topLabels.isNotEmpty
        ? topLabels.join(', ')
        : '${_formatBytes(item.sizeBytes)} · ${_categoryLabel(item.category)}';

    return DumpEnrichmentResult(
      title: title,
      description: description,
      thumbnailPath: thumbnailPath,
      mlLabels: topLabels,
      status: DumpEnrichmentStatus.done,
    );
  }

  Future<DumpEnrichmentResult> _enrichVideo(DumpItem item) async {
    final file = File(item.localCachePath);
    if (!await file.exists()) return DumpEnrichmentResult.failed;

    String? thumbnailPath;
    try {
      final thumbBytes = await VideoThumbnail.thumbnailData(
        video: item.localCachePath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: _kThumbMaxLongEdge,
        quality: _kThumbJpegQuality,
        timeMs: 1000,
      );
      if (thumbBytes != null && thumbBytes.isNotEmpty) {
        thumbnailPath = await _writeBytesToThumbs(
          thumbBytes,
          '${item.id}.jpg',
        );
      }
    } catch (e) {
      debugPrint('DumpEnricher: video thumb failed: $e');
    }

    return DumpEnrichmentResult(
      title: p.basenameWithoutExtension(item.originalName),
      description:
          '${_formatBytes(item.sizeBytes)} · ${_categoryLabel(item.category)}',
      thumbnailPath: thumbnailPath,
      status: DumpEnrichmentStatus.done,
    );
  }

  DumpEnrichmentResult _enrichAudio(DumpItem item) {
    return DumpEnrichmentResult(
      title: p.basenameWithoutExtension(item.originalName),
      description:
          '${_formatBytes(item.sizeBytes)} · ${_categoryLabel(item.category)}',
      status: DumpEnrichmentStatus.done,
    );
  }

  DumpEnrichmentResult _enrichDocument(DumpItem item) {
    return DumpEnrichmentResult(
      title: p.basenameWithoutExtension(item.originalName),
      description:
          '${_formatBytes(item.sizeBytes)} · PDF',
      status: DumpEnrichmentStatus.done,
    );
  }

  DumpEnrichmentResult _enrichFile(DumpItem item) {
    final mime = item.mimeType ?? 'unknown';
    return DumpEnrichmentResult(
      title: p.basenameWithoutExtension(item.originalName),
      description: '${_formatBytes(item.sizeBytes)} · $mime',
      status: DumpEnrichmentStatus.done,
    );
  }

  // ----------------------------------------------------------------
  // Link helpers — R14 SSRF guards
  // ----------------------------------------------------------------

  /// Returns true only if [uri] is `http`/`https`, has a non-empty
  /// host, and (when resolvable) every resolved address is a public
  /// unicast routable address — no RFC1918, no loopback, no link-local,
  /// no `0.0.0.0`, no IPv6 ULA/link-local.
  Future<bool> _isPublicHttpsTarget(Uri uri) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty) return false;

    List<InternetAddress> addresses;
    try {
      final lookup = dnsLookupOverride ?? InternetAddress.lookup;
      addresses = await lookup(uri.host).timeout(
        const Duration(seconds: 3),
      );
    } on TimeoutException {
      // No DNS — assume hostile.
      return false;
    } catch (e) {
      debugPrint('DumpEnricher: DNS lookup failed for ${uri.host}: $e');
      return false;
    }

    for (final addr in addresses) {
      if (_isPrivateAddress(addr)) return false;
    }
    return true;
  }

  bool _isPrivateAddress(InternetAddress addr) {
    if (addr.isLoopback || addr.isLinkLocal || addr.isMulticast) return true;
    final raw = addr.rawAddress;
    if (addr.type == InternetAddressType.IPv4 && raw.length == 4) {
      final a = raw[0];
      final b = raw[1];
      // 0.0.0.0/8 — wildcard
      if (a == 0) return true;
      // 10.0.0.0/8
      if (a == 10) return true;
      // 172.16.0.0/12
      if (a == 172 && b >= 16 && b <= 31) return true;
      // 192.168.0.0/16
      if (a == 192 && b == 168) return true;
      // 169.254.0.0/16 (link-local — caught by isLinkLocal but double-belt)
      if (a == 169 && b == 254) return true;
      // 127.0.0.0/8 — caught by isLoopback
      // 100.64.0.0/10 — CGNAT
      if (a == 100 && b >= 64 && b <= 127) return true;
      return false;
    }
    if (addr.type == InternetAddressType.IPv6 && raw.length == 16) {
      // fc00::/7 — Unique Local Address
      if ((raw[0] & 0xfe) == 0xfc) return true;
      // fe80::/10 — link-local (also isLinkLocal)
      if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) return true;
      // ::1 (loopback — caught by isLoopback)
      // ::ffff:0:0/96 — IPv4-mapped — re-check the embedded IPv4
      if (raw[0] == 0 && raw[1] == 0 && raw[2] == 0 && raw[3] == 0 &&
          raw[4] == 0 && raw[5] == 0 && raw[6] == 0 && raw[7] == 0 &&
          raw[8] == 0 && raw[9] == 0 && raw[10] == 0xff && raw[11] == 0xff) {
        final v4 = InternetAddress.fromRawAddress(
          Uint8List.fromList(raw.sublist(12)),
        );
        return _isPrivateAddress(v4);
      }
      return false;
    }
    return true; // Unknown family — be conservative.
  }

  /// Fetches HTML + extracts og:title / og:description / og:image.
  /// Optional [userAgent] overrides the default `FxFiles-Dump/1.0` —
  /// used by the X fallback path which retries with `Twitterbot/1.0`
  /// so Twitter serves us OG metadata (their card-validator crawler
  /// UA is one of the few accepted by post-2023 X).
  Future<_LinkMetadata> _fetchLinkMetadata(
    Uri uri, {
    String? userAgent,
  }) async {
    final ua = userAgent ?? _kLinkUserAgent;
    final client = linkHttpClientOverride ?? http.Client();
    final ownsClient = linkHttpClientOverride == null;
    try {
      // Manual redirect handling to enforce the 3-redirect cap.
      var current = uri;
      for (var i = 0; i <= _kLinkMaxRedirects; i++) {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..headers['User-Agent'] = ua
          ..headers['Accept'] = 'text/html,application/xhtml+xml';
        final streamed =
            await client.send(request).timeout(_kLinkTimeout);
        if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
          final loc = streamed.headers['location'];
          if (loc == null || loc.isEmpty || i == _kLinkMaxRedirects) {
            return const _LinkMetadata();
          }
          current = current.resolve(loc);
          if (!await _isPublicHttpsTarget(current)) {
            return const _LinkMetadata();
          }
          continue;
        }
        if (streamed.statusCode != 200) return const _LinkMetadata();
        final ct = streamed.headers['content-type'] ?? '';
        if (!ct.contains('html') && !ct.contains('xml')) {
          return const _LinkMetadata();
        }
        final body = await _readCapped(streamed, _kLinkMaxBodyBytes)
            .timeout(_kLinkTimeout);
        return _extractLinkMetadata(body, current);
      }
      return const _LinkMetadata();
    } on TimeoutException {
      return const _LinkMetadata();
    } catch (e) {
      debugPrint('DumpEnricher: link metadata fetch failed for $uri: $e');
      return const _LinkMetadata();
    } finally {
      if (ownsClient) client.close();
    }
  }

  /// Downloads `imageUrl`, downscales it to the standard thumbnail
  /// envelope (≤ 256 px long edge, JPEG q80), and writes it to
  /// `dump_thumbs/<dumpItemId>.jpg`. Returns the saved path or null on
  /// any failure (private target, non-image content type, decode fail,
  /// size cap exceeded, network timeout). Applies the same R14 SSRF
  /// guards as the HTML fetch path plus a 5 MB body cap and an
  /// `image/*` content-type check.
  Future<String?> _fetchAndCacheLinkImage(
      Uri imageUrl, String dumpItemId) async {
    if (imageUrl.scheme != 'http' && imageUrl.scheme != 'https') {
      return null;
    }
    if (!await _isPublicHttpsTarget(imageUrl)) return null;

    final client = linkHttpClientOverride ?? http.Client();
    final ownsClient = linkHttpClientOverride == null;
    try {
      var current = imageUrl;
      for (var i = 0; i <= _kLinkMaxRedirects; i++) {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..headers['User-Agent'] = _kLinkUserAgent
          ..headers['Accept'] = 'image/*';
        final streamed =
            await client.send(request).timeout(_kLinkTimeout);

        if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
          final loc = streamed.headers['location'];
          if (loc == null || loc.isEmpty || i == _kLinkMaxRedirects) {
            return null;
          }
          current = current.resolve(loc);
          if (!await _isPublicHttpsTarget(current)) return null;
          continue;
        }

        if (streamed.statusCode != 200) return null;
        final ct = (streamed.headers['content-type'] ?? '').toLowerCase();
        if (!ct.startsWith('image/')) return null;

        final builder = BytesBuilder(copy: false);
        await for (final chunk in streamed.stream) {
          builder.add(chunk);
          if (builder.length >= _kLinkImageMaxBytes) break;
        }
        final raw = builder.takeBytes();
        final bytes = raw.length > _kLinkImageMaxBytes
            ? raw.sublist(0, _kLinkImageMaxBytes)
            : raw;

        final decoded = img.decodeImage(bytes);
        if (decoded == null) return null;

        final longEdge = decoded.width >= decoded.height
            ? decoded.width
            : decoded.height;
        final scale = longEdge > _kThumbMaxLongEdge
            ? _kThumbMaxLongEdge / longEdge
            : 1.0;
        final targetW =
            (decoded.width * scale).round().clamp(1, _kThumbMaxLongEdge);
        final targetH =
            (decoded.height * scale).round().clamp(1, _kThumbMaxLongEdge);
        final resized = (scale < 1.0)
            ? img.copyResize(decoded, width: targetW, height: targetH)
            : decoded;
        final jpegBytes =
            img.encodeJpg(resized, quality: _kThumbJpegQuality);
        return await _writeBytesToThumbs(
          Uint8List.fromList(jpegBytes),
          '$dumpItemId.jpg',
        );
      }
      return null;
    } on TimeoutException {
      return null;
    } catch (e) {
      debugPrint('DumpEnricher: image fetch failed for $imageUrl: $e');
      return null;
    } finally {
      if (ownsClient) client.close();
    }
  }

  Future<String> _readCapped(http.StreamedResponse r, int cap) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in r.stream) {
      builder.add(chunk);
      if (builder.length >= cap) break;
    }
    final bytes = builder.takeBytes();
    final clipped = bytes.length > cap ? bytes.sublist(0, cap) : bytes;
    // Modern web pages (and Twitter's syndication JSON) are UTF-8.
    // `String.fromCharCodes` would treat each byte as Latin-1, which
    // corrupts every multi-byte UTF-8 character — Farsi, CJK, emoji,
    // and most non-English content turns into mojibake. `allowMalformed`
    // replaces any actual non-UTF-8 bytes with U+FFFD instead of
    // throwing, so legacy Latin-1 / Windows-1252 pages still decode
    // (lossily but without crashing).
    return utf8.decode(clipped, allowMalformed: true);
  }

  static final RegExp _ogTitleRe = RegExp(
    r'''<meta\s+[^>]*?property=["']og:title["'][^>]*?content=["']([^"']+)["']''',
    caseSensitive: false,
  );
  static final RegExp _ogDescRe = RegExp(
    r'''<meta\s+[^>]*?property=["']og:description["'][^>]*?content=["']([^"']+)["']''',
    caseSensitive: false,
  );
  static final RegExp _ogImageRe = RegExp(
    r'''<meta\s+[^>]*?property=["']og:image(?::secure_url)?["'][^>]*?content=["']([^"']+)["']''',
    caseSensitive: false,
  );
  static final RegExp _metaDescRe = RegExp(
    r'''<meta\s+[^>]*?name=["']description["'][^>]*?content=["']([^"']+)["']''',
    caseSensitive: false,
  );
  static final RegExp _titleTagRe =
      RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true);

  _LinkMetadata _extractLinkMetadata(String html, Uri baseUrl) {
    String? extract(RegExp re) {
      final m = re.firstMatch(html);
      if (m == null) return null;
      final raw = m.group(1);
      if (raw == null || raw.trim().isEmpty) return null;
      return _decodeEntities(raw).trim();
    }

    String? title = extract(_ogTitleRe) ?? extract(_titleTagRe);
    String? description = extract(_ogDescRe) ?? extract(_metaDescRe);
    if (description != null && description.length > _kNoteDescMaxChars) {
      description = '${description.substring(0, _kNoteDescMaxChars - 1)}…';
    }

    Uri? imageUrl;
    final imgRaw = extract(_ogImageRe);
    if (imgRaw != null) {
      try {
        imageUrl = baseUrl.resolve(imgRaw);
      } catch (_) {
        imageUrl = null;
      }
    }

    return _LinkMetadata(
      title: title,
      description: description,
      imageUrl: imageUrl,
    );
  }

  static final RegExp _numericEntityRe =
      RegExp(r'&#([xX]?)([0-9a-fA-F]+);');

  /// Decodes HTML entities found inside OG meta `content="..."`. Covers:
  ///   * Five common named entities (`&amp;` → `&`, etc.).
  ///   * Decimal numeric references like `&#1606;` (Farsi noon).
  ///   * Hex numeric references like `&#x646;`.
  /// Without numeric-reference support, sites that emit non-ASCII as
  /// `&#nnnn;` (Wikipedia, some CMS-rendered pages, defensive
  /// templating) leak the literal `&#nnnn;` onto the tile.
  String _decodeEntities(String s) {
    final named = s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return named.replaceAllMapped(_numericEntityRe, (m) {
      final isHex = m.group(1)!.isNotEmpty;
      final digits = m.group(2)!;
      final cp = int.tryParse(digits, radix: isHex ? 16 : 10);
      if (cp == null || cp < 0 || cp > 0x10FFFF) {
        return m.group(0)!; // malformed — pass through.
      }
      try {
        return String.fromCharCode(cp);
      } catch (_) {
        return m.group(0)!;
      }
    });
  }

  // ----------------------------------------------------------------
  // Twitter / X — syndication API path
  // ----------------------------------------------------------------
  //
  // X (formerly Twitter) actively blocks anonymous OG scraping post-
  // 2023 — the general `_fetchLinkMetadata` returns blank HTML for
  // x.com/twitter.com hosts. Instead, hit the same undocumented
  // endpoint that Twitter's own embed widget uses:
  //   https://cdn.syndication.twimg.com/tweet-result?id=<id>&token=<t>
  //
  // No auth needed, but the `token` query param is derived from the
  // tweet ID via a known JS formula (mirrored in
  // [computeTwitterSyndicationToken]). This endpoint is undocumented
  // and may change without warning — `_enrichLink` falls back to the
  // general OG fetch if syndication returns nothing.

  static final RegExp _twitterStatusRe = RegExp(
    r'^/[^/]+/status(?:es)?/(\d+)',
  );

  bool _isTwitterHost(String host) {
    final h = host.toLowerCase();
    return h == 'x.com' ||
        h == 'twitter.com' ||
        h == 'mobile.twitter.com' ||
        h.endsWith('.twitter.com') ||
        h.endsWith('.x.com');
  }

  /// Facebook URL detection — covers their canonical share targets:
  /// `www.facebook.com`, `m.facebook.com`, mobile variants, the
  /// `fb.com` shortener, and the `fb.watch` video share format.
  bool _isFacebookHost(String host) {
    final h = host.toLowerCase();
    return h == 'facebook.com' ||
        h == 'm.facebook.com' ||
        h == 'mbasic.facebook.com' ||
        h == 'web.facebook.com' ||
        h == 'fb.com' ||
        h == 'fb.watch' ||
        h.endsWith('.facebook.com');
  }

  String? _extractTweetId(Uri uri) {
    if (!_isTwitterHost(uri.host)) return null;
    final m = _twitterStatusRe.firstMatch(uri.path);
    return m?.group(1);
  }

  /// Computes the syndication API token using Twitter's own JS
  /// formula:
  ///   `((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '')`
  /// This matches what `react-tweet` and other open-source embed
  /// renderers compute, mirroring Twitter's own client-side widget.
  @visibleForTesting
  static String computeTwitterSyndicationToken(String tweetId) {
    final id = double.tryParse(tweetId);
    if (id == null || id.isNaN || id.isInfinite) return '';
    final n = (id / 1e15) * 3.141592653589793;
    return _doubleToBase36(n).replaceAll(RegExp(r'(0+|\.)'), '');
  }

  /// Port of JS `Number.prototype.toString(36)` for non-negative
  /// finite doubles. JS uses a shortest-round-trip algorithm
  /// (Grisu/Ryu): it produces the shortest sequence of digits such
  /// that re-parsing yields the same IEEE 754 double.
  ///
  /// We mirror that by generating ~23 base-36 digits of the
  /// fractional part (one more than the 22 needed to cover the
  /// 53-bit mantissa, so we have a digit available for rounding),
  /// then at each length trying both the truncated and the rounded-up
  /// variant. The shortest variant whose reverse parse equals the
  /// input wins. Without this, the Twitter syndication token has
  /// either too many digits (truncate-only) or wrong digits (no
  /// rounding) and the API rejects the request.
  static String _doubleToBase36(double n) {
    if (n.isNaN || n.isInfinite || n < 0) return '';
    final intPart = n.floor();
    final fracPart = n - intPart;
    if (fracPart == 0) return intPart.toRadixString(36);

    // Generate 23 fractional digits — 22 is enough for the 53-bit
    // mantissa, plus one extra to drive rounding decisions.
    const maxDigits = 23;
    final digits = <int>[];
    var f = fracPart;
    for (var i = 0; i < maxDigits && f > 0; i++) {
      f *= 36;
      final d = f.floor();
      f -= d;
      digits.add(d);
    }

    double parseBack(int ip, List<int> frac) {
      if (frac.isEmpty) return ip.toDouble();
      var fracVal = 0;
      for (final d in frac) {
        fracVal = fracVal * 36 + d;
      }
      var denom = 1.0;
      for (var i = 0; i < frac.length; i++) {
        denom *= 36;
      }
      return ip.toDouble() + fracVal.toDouble() / denom;
    }

    String build(int ip, List<int> frac) {
      final intS = ip.toRadixString(36);
      if (frac.isEmpty) return intS;
      final buf = StringBuffer(intS)..write('.');
      for (final d in frac) {
        buf.write(d < 10
            ? String.fromCharCode(48 + d)
            : String.fromCharCode(87 + d));
      }
      return buf.toString();
    }

    // Try each length from shortest to longest. At each length try
    // the truncated form first, then the rounded-up form (carry
    // propagated through fractional digits and into the integer part
    // if necessary).
    for (var len = 1; len <= digits.length; len++) {
      final truncated = digits.sublist(0, len);
      if (parseBack(intPart, truncated) == n) {
        return build(intPart, truncated);
      }

      // Rounded variant: increment the last fractional digit with
      // carry. Only meaningful when there's at least one more digit
      // we could have generated.
      final rounded = List<int>.from(truncated);
      var carry = 1;
      for (var i = rounded.length - 1; i >= 0 && carry > 0; i--) {
        rounded[i] += carry;
        if (rounded[i] >= 36) {
          rounded[i] = 0;
          carry = 1;
        } else {
          carry = 0;
        }
      }
      final roundedIntPart = intPart + carry;
      if (parseBack(roundedIntPart, rounded) == n) {
        return build(roundedIntPart, rounded);
      }
    }

    return build(intPart, digits);
  }

  Future<_LinkMetadata> _fetchTweetSyndication(String tweetId) async {
    final token = computeTwitterSyndicationToken(tweetId);
    if (token.isEmpty) return const _LinkMetadata();

    final url = Uri.https(
      'cdn.syndication.twimg.com',
      '/tweet-result',
      <String, String>{'id': tweetId, 'token': token, 'lang': 'en'},
    );

    if (!await _isPublicHttpsTarget(url)) return const _LinkMetadata();

    final client = linkHttpClientOverride ?? http.Client();
    final ownsClient = linkHttpClientOverride == null;
    try {
      final request = http.Request('GET', url)
        ..followRedirects = false
        ..headers['User-Agent'] = _kLinkUserAgent
        ..headers['Accept'] = 'application/json';
      final streamed =
          await client.send(request).timeout(_kLinkTimeout);
      if (streamed.statusCode != 200) {
        return const _LinkMetadata();
      }
      final body = await _readCapped(streamed, _kLinkMaxBodyBytes)
          .timeout(_kLinkTimeout);
      final dynamic decoded;
      try {
        decoded = jsonDecode(body);
      } catch (_) {
        return const _LinkMetadata();
      }
      if (decoded is! Map<String, dynamic>) return const _LinkMetadata();

      final text = decoded['text'] as String?;
      final user = decoded['user'] as Map<String, dynamic>?;
      final author = user?['screen_name'] as String?;
      final mediaDetails = decoded['mediaDetails'] as List<dynamic>?;

      String? imageUrlString;
      if (mediaDetails != null && mediaDetails.isNotEmpty) {
        final first = mediaDetails.first;
        if (first is Map<String, dynamic>) {
          imageUrlString = first['media_url_https'] as String?;
        }
      }
      imageUrlString ??= user?['profile_image_url_https'] as String?;

      Uri? imageUrl;
      if (imageUrlString != null && imageUrlString.isNotEmpty) {
        imageUrl = Uri.tryParse(imageUrlString);
      }

      final title = (author != null && author.isNotEmpty)
          ? 'Tweet by @$author'
          : null;
      String? desc;
      if (text != null && text.isNotEmpty) {
        desc = text.length > _kNoteDescMaxChars
            ? '${text.substring(0, _kNoteDescMaxChars - 1)}…'
            : text;
      }

      return _LinkMetadata(
        title: title,
        description: desc,
        imageUrl: imageUrl,
      );
    } on TimeoutException {
      return const _LinkMetadata();
    } catch (e) {
      debugPrint('DumpEnricher: tweet syndication failed: $e');
      return const _LinkMetadata();
    } finally {
      if (ownsClient) client.close();
    }
  }

  // ----------------------------------------------------------------
  // Thumbnail / image helpers
  // ----------------------------------------------------------------

  Future<String?> _writeDownscaledImageThumb(File source, String id) async {
    final bytes = await source.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    final longEdge =
        decoded.width >= decoded.height ? decoded.width : decoded.height;
    final scale = longEdge > _kThumbMaxLongEdge
        ? _kThumbMaxLongEdge / longEdge
        : 1.0;
    final targetW = (decoded.width * scale).round().clamp(1, _kThumbMaxLongEdge);
    final targetH =
        (decoded.height * scale).round().clamp(1, _kThumbMaxLongEdge);
    final resized = (scale < 1.0)
        ? img.copyResize(decoded, width: targetW, height: targetH)
        : decoded;
    final jpegBytes = img.encodeJpg(resized, quality: _kThumbJpegQuality);
    return _writeBytesToThumbs(
      Uint8List.fromList(jpegBytes),
      '$id.jpg',
    );
  }

  Future<String> _writeBytesToThumbs(Uint8List bytes, String filename) async {
    final dir = thumbsDirOverride != null
        ? await thumbsDirOverride!()
        : await _defaultThumbsDir();
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(p.join(dir.path, filename));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<Directory> _defaultThumbsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, _kThumbsDir));
  }

  // ----------------------------------------------------------------
  // Misc utilities
  // ----------------------------------------------------------------

  Future<String?> _readTextFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final size = await file.length();
      if (size > 1024 * 1024) {
        // Cap text-payload reads at 1 MB to bound memory. Decode as
        // UTF-8 (same reasoning as in _readCapped — Latin-1 mangles
        // non-English content). `allowMalformed` keeps us from
        // throwing if the cap split a multi-byte UTF-8 sequence.
        final raf = await file.open();
        try {
          final bytes = await raf.read(1024 * 1024);
          return utf8.decode(bytes, allowMalformed: true);
        } finally {
          await raf.close();
        }
      }
      return await file.readAsString();
    } catch (e) {
      debugPrint('DumpEnricher: text read failed for $path: $e');
      return null;
    }
  }

  String _categoryLabel(DumpCategory category) {
    switch (category) {
      case DumpCategory.link:
        return 'Link';
      case DumpCategory.note:
        return 'Note';
      case DumpCategory.screenshot:
        return 'Screenshot';
      case DumpCategory.image:
        return 'Image';
      case DumpCategory.video:
        return 'Video';
      case DumpCategory.audio:
        return 'Audio';
      case DumpCategory.document:
        return 'Document';
      case DumpCategory.file:
        return 'File';
      case DumpCategory.other:
        return 'Other';
    }
  }

  String _titleCase(String s) {
    if (s.isEmpty) return s;
    final lower = s.toLowerCase();
    return lower[0].toUpperCase() + lower.substring(1);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @visibleForTesting
  void resetForTesting() {
    imageLabelOverride = null;
    linkHttpClientOverride = null;
    dnsLookupOverride = null;
    thumbsDirOverride = null;
  }
}

/// Parsed link metadata bag passed between the fetchers and
/// `_enrichLink`. All fields may be null when the source page returns
/// no OG tags, no `<title>`, or no `<meta name="description">`. The
/// caller falls back to URL host / raw URL / no thumbnail when fields
/// are missing.
class _LinkMetadata {
  final String? title;
  final String? description;
  final Uri? imageUrl;
  const _LinkMetadata({this.title, this.description, this.imageUrl});
}
