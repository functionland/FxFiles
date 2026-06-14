import 'package:flutter/foundation.dart' show immutable;

/// Cap on the device-local Recent list.
const int kWebRecentCap = 30;

/// One recently-opened cloud file (device-local, per-user). Keyed by
/// (bucket, objectKey); [base] is the category route segment so a tap can
/// reopen via `/b/<base>?open=<key>`.
///
/// Pure data + merge logic only (NO `package:web` / `dart:ui`) so it — and
/// [mergeRecentEntries] — are unit-testable under the Dart VM. The
/// encrypted IndexedDB store that uses these lives in
/// `web_recent_files_service.dart` (browser-only).
@immutable
class WebRecentEntry {
  const WebRecentEntry({
    required this.bucket,
    required this.base,
    required this.key,
    required this.name,
    required this.mime,
    required this.size,
    required this.accessedAtMs,
    required this.hasThumb,
  });

  final String bucket;
  final String base;
  final String key;
  final String name;
  final String mime;
  final int size;
  final int accessedAtMs;
  final bool hasThumb;

  /// Identity for dedup (one entry per object).
  String get id => '$bucket|$key';

  bool get isImage => mime.startsWith('image/');
  bool get isVideo => mime.startsWith('video/');
  bool get isAudio => mime.startsWith('audio/');

  Map<String, dynamic> toJson() => {
        'bucket': bucket,
        'base': base,
        'key': key,
        'name': name,
        'mime': mime,
        'size': size,
        'at': accessedAtMs,
        'thumb': hasThumb,
      };

  static WebRecentEntry? fromJson(Map<String, dynamic> j) {
    final bucket = j['bucket'];
    final key = j['key'];
    if (bucket is! String || key is! String) return null;
    return WebRecentEntry(
      bucket: bucket,
      base: (j['base'] as String?) ?? bucket,
      key: key,
      name: (j['name'] as String?) ?? key,
      mime: (j['mime'] as String?) ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
      accessedAtMs: (j['at'] as num?)?.toInt() ?? 0,
      hasThumb: j['thumb'] == true,
    );
  }
}

/// Dedup by [WebRecentEntry.id] (move-to-top), sort by accessedAt desc,
/// cap at [cap]. Returns (kept, dropped) — dropped entries' thumbnails are
/// deleted by the caller. Pure / VM-testable.
(List<WebRecentEntry>, List<WebRecentEntry>) mergeRecentEntries(
  List<WebRecentEntry> existing,
  WebRecentEntry opened, {
  int cap = kWebRecentCap,
}) {
  final merged = <WebRecentEntry>[
    opened,
    ...existing.where((e) => e.id != opened.id),
  ]..sort((a, b) => b.accessedAtMs.compareTo(a.accessedAtMs));
  if (merged.length <= cap) return (merged, const []);
  return (merged.sublist(0, cap), merged.sublist(cap));
}
