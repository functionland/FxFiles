import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_classifier.dart';

/// Pure, VM-testable transforms behind the web shelf WRITE path. No
/// `package:web` / FulaApiService imports so this — and its unit tests —
/// run under the VM; the IO glue (upload + bucket ensure + cache
/// write-through) lives in `web_shelf_service.dart`.
///
/// CRITICAL: the manifest shape must stay byte-compatible with what
/// native `ShelfStorageService` writes and `WebFeatures.loadShelf` reads
/// (`{v, updatedAt, items[], order[], userId}`, items via
/// `ShelfItem.toJson`), so web-added items round-trip to the phone.

/// Object-key prefix for the per-user shelf manifest (native
/// ShelfStorageService key shape).
const String kShelfDumpsPrefix = '.fula/dumps/';

/// Cloud manifest payload version — must match
/// ShelfStorageService._manifestVersion (v2 = items + order).
const int kShelfManifestVersion = 2;

/// Cloud key for a user's shelf manifest.
String shelfManifestKey(String userId) => '$kShelfDumpsPrefix$userId.json';

/// Replace anything outside [A-Za-z0-9._-] with '_' (S3-safe keys).
/// Mirrors ShelfService._sanitizeName.
String sanitizeShelfName(String name) {
  final sanitized = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return sanitized.isEmpty ? 'file' : sanitized;
}

/// Body blob key — mirrors ShelfService._remoteKeyFor:
/// `<yyyy>/<mm>/<id>-<sanitized name>`.
String shelfBodyKey(String id, DateTime receivedAt, String name) {
  final now = receivedAt.toUtc();
  final year = now.year.toString().padLeft(4, '0');
  final month = now.month.toString().padLeft(2, '0');
  return '$year/$month/$id-${sanitizeShelfName(name)}';
}

/// Note title — first non-empty line (≤60 chars), else a stamped
/// default. Mirrors ShelfAddNoteScreen._deriveOriginalName.
String deriveNoteName(String text, DateTime now) {
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    return trimmed.length > 60 ? '${trimmed.substring(0, 59)}…' : trimmed;
  }
  final stamp = now.toIso8601String().substring(0, 16).replaceFirst('T', ' ');
  return 'Note $stamp';
}

/// Provided mime, else inferred from the filename (so the web viewer
/// previews images/video/audio inline instead of downloading raw bytes).
String? effectiveShelfMime(String? mime, String name) =>
    (mime != null && mime.isNotEmpty) ? mime : lookupMimeType(name);

/// A Link item: manifest-only (`textPayload` = the URL, `remoteKey`
/// null). Native opens links straight from `textPayload`.
ShelfItem buildLinkItem({
  required String id,
  required String url,
  required DateTime now,
}) {
  final clean = url.trim();
  return ShelfItem(
    id: id,
    receivedAt: now,
    originalName: clean,
    mimeType: null,
    sizeBytes: utf8.encode(clean).length,
    localCachePath: '',
    category: ShelfCategory.link,
    uploadStatus: ShelfUploadStatus.uploaded,
    textPayload: clean,
    contentSha: sha256.convert(utf8.encode(clean)).toString(),
    enrichmentStatus: ShelfEnrichmentStatus.done,
  );
}

/// A Note item: manifest-only (`textPayload` = the text). A bare URL
/// classifies as a Link (matches the native classifier).
ShelfItem buildNoteItem({
  required String id,
  required String text,
  required DateTime now,
}) {
  final category = ShelfClassifier.classify(
    mimeType: 'text/plain',
    filename: 'note.txt',
    textPayload: text,
  );
  return ShelfItem(
    id: id,
    receivedAt: now,
    originalName: deriveNoteName(text, now),
    mimeType: 'text/plain',
    sizeBytes: utf8.encode(text).length,
    localCachePath: '',
    category: category,
    uploadStatus: ShelfUploadStatus.uploaded,
    textPayload: text,
    contentSha: sha256.convert(utf8.encode(text)).toString(),
    enrichmentStatus: ShelfEnrichmentStatus.done,
  );
}

/// A body-backed item (file / photo / recording). The body blob is
/// uploaded by the IO layer; this records its `remoteKey`/`sourceBucket`
/// and the inferred category.
ShelfItem buildBytesItem({
  required String id,
  required String name,
  required String? mime,
  required int sizeBytes,
  required String contentSha,
  required String remoteKey,
  required String sourceBucket,
  required DateTime now,
}) {
  final eff = effectiveShelfMime(mime, name);
  return ShelfItem(
    id: id,
    receivedAt: now,
    originalName: name,
    mimeType: eff,
    sizeBytes: sizeBytes,
    localCachePath: '',
    remoteKey: remoteKey,
    category: ShelfClassifier.classify(mimeType: eff, filename: name),
    uploadStatus: ShelfUploadStatus.uploaded,
    contentSha: contentSha,
    sourceBucket: sourceBucket,
    enrichmentStatus: ShelfEnrichmentStatus.done,
  );
}

/// sha256 hex of [bytes] — the body item's contentSha.
String shelfContentSha(Uint8List bytes) => sha256.convert(bytes).toString();

/// Prepend [item] to [current] (dropping any same-id duplicate) so new
/// arrivals land at the top, matching native `add()`. Returns the new
/// item list and its id order.
({List<ShelfItem> items, List<String> order}) prependShelfItem(
    List<ShelfItem> current, ShelfItem item) {
  final items = <ShelfItem>[
    item,
    ...current.where((i) => i.id != item.id),
  ];
  final order = items.map((i) => i.id).toList(growable: false);
  return (items: items, order: order);
}

/// The full manifest payload native restore reads verbatim.
Map<String, dynamic> buildShelfManifest({
  required List<ShelfItem> items,
  required List<String> order,
  required String userId,
  required DateTime now,
}) =>
    <String, dynamic>{
      'v': kShelfManifestVersion,
      'updatedAt': now.toUtc().toIso8601String(),
      'items': items.map((i) => i.toJson()).toList(growable: false),
      'order': order,
      'userId': userId,
    };

/// UTF-8 JSON bytes of a manifest payload (what gets uploaded).
Uint8List shelfManifestBytes(Map<String, dynamic> payload) =>
    Uint8List.fromList(utf8.encode(jsonEncode(payload)));

/// Merge decrypted manifest blobs (v8 first, then legacy) into the
/// ordered item list, mirroring `WebFeatures.loadShelf`: the first blob
/// to carry an id wins it and owns the `order`; items missing from the
/// order fall to the end (newest-first). Malformed item entries are
/// skipped. Blobs that fail to JSON-decode are skipped too — the IO
/// layer is responsible for refusing to overwrite the v8 bucket when its
/// CURRENT manifest can't be read (see WebShelfService), so a corrupt v8
/// blob never reaches here.
({List<ShelfItem> items, List<String>? order}) mergeShelfManifestBlobs(
    List<Uint8List?> blobsV8First) {
  final byId = <String, ShelfItem>{};
  List<String>? order;
  for (final blob in blobsV8First) {
    if (blob == null || blob.isEmpty) continue;
    try {
      final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
      for (final raw in (j['items'] as List<dynamic>? ?? const [])) {
        try {
          final item = ShelfItem.fromJson(raw as Map<String, dynamic>);
          byId.putIfAbsent(item.id, () => item);
        } catch (_) {/* skip malformed entry */}
      }
      order ??= (j['order'] as List<dynamic>?)?.cast<String>();
    } catch (_) {/* skip unparseable blob */}
  }

  final items = byId.values.toList();
  if (order != null && order.isNotEmpty) {
    final pos = <String, int>{
      for (var i = 0; i < order.length; i++) order[i]: i,
    };
    items.sort(
        (a, b) => (pos[a.id] ?? 1 << 30).compareTo(pos[b.id] ?? 1 << 30));
  } else {
    items.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
  }
  return (items: items, order: order);
}
