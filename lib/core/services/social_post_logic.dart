// Pure decision logic for the social-posts feature — IO-free and
// VM-testable (house rule: the service/XHR layer stays logic-free).

import 'package:fula_files/core/services/website_prompt_builder.dart';

/// Raster image extensions eligible as Gemini reference material (no SVG).
const Set<String> kSocialImageExtensions = {
  'png', 'jpg', 'jpeg', 'webp', 'gif',
};

/// Backend cap on reference assets per request.
const int kSocialMaxAssets = 14;

/// Sanitized bucket prefix for a website group — byte-identical to the
/// transform native + web use for `website-assets` keys
/// (`replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')`), clamped to the
/// backend's 100-char assetPrefix bound.
String socialAssetPrefix(String displayName) {
  final sanitized = displayName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
  final clamped =
      sanitized.length > 100 ? sanitized.substring(0, 100) : sanitized;
  return clamped.isEmpty ? '_' : clamped;
}

bool _isImageFileName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return false;
  return kSocialImageExtensions.contains(
      fileName.substring(dot + 1).toLowerCase());
}

/// Request body for POST /api/v1/social/generate. Filters the generation's
/// assets to URL-backed raster images and caps at [kSocialMaxAssets].
Map<String, dynamic> buildSocialGeneratePayload({
  required String generationId,
  required String websiteUrl,
  required String userPrompt,
  required List<({String fileName, String type, String url})> assets,
  required String displayName,
}) {
  final images = assets
      .where((a) => a.url.isNotEmpty && _isImageFileName(a.fileName))
      .take(kSocialMaxAssets)
      .map((a) => {'fileName': a.fileName, 'type': a.type, 'url': a.url})
      .toList();
  return {
    'generationId': generationId,
    'websiteUrl': websiteUrl,
    'prompt': userPrompt,
    'assets': images,
    'assetPrefix': socialAssetPrefix(displayName),
  };
}

/// Website URL to embed in captions: the stable front door when the group
/// has one, else the generation's own gateway URL.
String? resolveSocialWebsiteUrl(
    String? frontDoorUrl, String? generationGatewayUrl) {
  if (frontDoorUrl != null && frontDoorUrl.isNotEmpty) return frontDoorUrl;
  if (generationGatewayUrl != null && generationGatewayUrl.isNotEmpty) {
    return generationGatewayUrl;
  }
  return null;
}

/// Human prompt for the caption/image brief: the user's own words,
/// stripped of the enriched Website Name/Category/Styles/… envelope.
String socialUserPrompt(String storedPrompt) {
  final parsed = parseStoredWebsitePrompt(storedPrompt);
  return parsed.userBody.isNotEmpty ? parsed.userBody : storedPrompt.trim();
}

/// Merge sidecar entries from any number of blobs (+ the local map),
/// keyed by generationId, LATEST-updatedAt-wins. Differs deliberately
/// from the first-wins generations/pointers merges: social entries mutate
/// (pending → completed) and re-runs replace results, so the newest write
/// must win. Raw maps in/out — unknown keys survive rewrites by old
/// clients. Malformed entries are skipped without dropping siblings.
Map<String, Map<String, dynamic>> mergeSocialPosts(
    Iterable<Iterable<dynamic>> entryLists) {
  final byId = <String, Map<String, dynamic>>{};
  DateTime updatedAtOf(Map<String, dynamic> m) {
    final v = m['updatedAt'];
    return v is String
        ? (DateTime.tryParse(v) ?? DateTime.fromMillisecondsSinceEpoch(0))
        : DateTime.fromMillisecondsSinceEpoch(0);
  }

  for (final list in entryLists) {
    for (final raw in list) {
      if (raw is! Map) continue;
      final m = raw.cast<String, dynamic>();
      final id = m['generationId'];
      if (id is! String || id.isEmpty) continue;
      final existing = byId[id];
      if (existing == null ||
          updatedAtOf(m).isAfter(updatedAtOf(existing))) {
        byId[id] = m;
      }
    }
  }
  return byId;
}

/// Caption choice per Buffer channel: short for X/Twitter-like services,
/// long everywhere else.
String captionForBufferService(String service,
    {required String long, required String short}) {
  final s = service.toLowerCase();
  final isX = s.contains('twitter') || s == 'x' || s.startsWith('x_');
  return isX ? short : long;
}

/// What load() should do with a sidecar record found at startup.
enum SocialResumeAction { none, resumePoll, markInterrupted }

/// Resume decision for a record. Running + jobId → resume REGARDLESS of
/// age (poll-first: the server may have finished while every tab was
/// closed; a genuinely dead job answers 404/error on the first poll).
/// A pending record with no jobId means the owning tab died between click
/// and 202 — stale after [interruptedAfter].
SocialResumeAction socialResumeAction({
  required String status,
  required String? jobId,
  required DateTime createdAt,
  required DateTime now,
  Duration interruptedAfter = const Duration(minutes: 5),
}) {
  final running =
      status == 'pending' || status == 'generating' || status == 'publishing';
  if (!running) return SocialResumeAction.none;
  if (jobId != null && jobId.isNotEmpty) return SocialResumeAction.resumePoll;
  return now.difference(createdAt) > interruptedAfter
      ? SocialResumeAction.markInterrupted
      : SocialResumeAction.none;
}

/// Poll backoff: ×1.5 capped at 10s (website-gen parity).
Duration nextSocialPollInterval(Duration current) {
  const max = Duration(seconds: 10);
  if (current >= max) return max;
  final next = Duration(milliseconds: (current.inMilliseconds * 1.5).toInt());
  return next > max ? max : next;
}

/// One-line summary + all-ok flag for a Buffer post run.
({String summary, bool allOk}) summarizeBufferResults(
    List<({String channelId, bool ok, String? error})> results) {
  final okCount = results.where((r) => r.ok).length;
  final total = results.length;
  if (total == 0) return (summary: 'No channels selected', allOk: false);
  if (okCount == total) {
    return (
      summary: total == 1
          ? 'Posted to your Buffer queue'
          : 'Posted to all $total channels',
      allOk: true,
    );
  }
  return (summary: 'Posted to $okCount of $total channels', allOk: false);
}
