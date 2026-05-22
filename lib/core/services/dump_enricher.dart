import 'dart:async';
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

    final ogTitle = await _fetchOgTitle(uri);
    return DumpEnrichmentResult(
      title: ogTitle?.isNotEmpty == true ? ogTitle : uri.host,
      description: raw,
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
      addresses = await InternetAddress.lookup(uri.host).timeout(
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

  Future<String?> _fetchOgTitle(Uri uri) async {
    final client = linkHttpClientOverride ?? http.Client();
    final ownsClient = linkHttpClientOverride == null;
    try {
      // Manual redirect handling to enforce the 3-redirect cap.
      var current = uri;
      for (var i = 0; i <= _kLinkMaxRedirects; i++) {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..headers['User-Agent'] = _kLinkUserAgent
          ..headers['Accept'] = 'text/html,application/xhtml+xml';
        final streamed =
            await client.send(request).timeout(_kLinkTimeout);
        if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
          final loc = streamed.headers['location'];
          if (loc == null || loc.isEmpty || i == _kLinkMaxRedirects) {
            return null;
          }
          current = current.resolve(loc);
          if (!await _isPublicHttpsTarget(current)) {
            return null; // redirect to a private target — bail.
          }
          continue;
        }
        if (streamed.statusCode != 200) return null;
        final ct = streamed.headers['content-type'] ?? '';
        if (!ct.contains('html') && !ct.contains('xml')) return null;
        final body = await _readCapped(streamed, _kLinkMaxBodyBytes)
            .timeout(_kLinkTimeout);
        return _extractOgTitle(body);
      }
      return null;
    } on TimeoutException {
      return null;
    } catch (e) {
      debugPrint('DumpEnricher: OG fetch failed for $uri: $e');
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
    // HTML is usually UTF-8 / Latin-1. Try UTF-8 then fall back to
    // a tolerant Latin-1 decode.
    try {
      return String.fromCharCodes(clipped);
    } catch (_) {
      return '';
    }
  }

  static final RegExp _ogTitleRe = RegExp(
    r'''<meta\s+[^>]*?property=["']og:title["'][^>]*?content=["']([^"']+)["']''',
    caseSensitive: false,
  );
  static final RegExp _titleTagRe =
      RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true);

  String? _extractOgTitle(String html) {
    final og = _ogTitleRe.firstMatch(html);
    if (og != null) {
      final raw = og.group(1);
      if (raw != null && raw.trim().isNotEmpty) {
        return _decodeEntities(raw).trim();
      }
    }
    final tt = _titleTagRe.firstMatch(html);
    if (tt != null) {
      final raw = tt.group(1);
      if (raw != null && raw.trim().isNotEmpty) {
        return _decodeEntities(raw).trim();
      }
    }
    return null;
  }

  String _decodeEntities(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
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
        // Cap text-payload reads at 1 MB to bound memory.
        final raf = await file.open();
        try {
          final bytes = await raf.read(1024 * 1024);
          return String.fromCharCodes(bytes);
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
    thumbsDirOverride = null;
  }
}
