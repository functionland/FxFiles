// Pure decode helpers behind WebFeatures.loadWebsites (VM-testable).
//
// Extracted so the websites manifest decode can YIELD to the event loop:
// Flutter web is single-threaded and `await` alone resumes in the
// MICROTASK queue — an unbroken decode chain never lets the engine
// paint (a Chrome trace of the websites open showed a 444ms
// RunMicrotasks monolith freezing the spinner on mobile). A
// `Future.delayed(Duration.zero)` is a macrotask (setTimeout(0)), so
// slicing the loops with it keeps frames flowing. `compute()` is NOT an
// option here: on the web it runs on the main thread.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/models/website_group_pointer.dart';

/// Decode the merged `[v8, legacy]` generations-manifest blobs into the
/// deduped, updatedAt-desc list the screens render. Exact semantics of
/// the previous inline loop: per-blob `jsonDecode`, first blob wins an
/// id (v8 over legacy), a malformed ENTRY aborts the rest of its blob
/// (per-blob try/catch) without dropping other blobs.
///
/// [yieldEvery] generations, control returns to the event loop so the
/// UI can paint (~0.5-2ms per generation at the 30-asset cap → 8 keeps
/// slices in the 4-8ms range).
///
/// [dropParsedContent] nulls every asset's `parsedContent` on the
/// decoded objects — the LIST screen never renders it, and a legacy
/// manifest can carry ≤30×100KB of it per generation. The detail
/// screen keeps the default (false): its recreate flow reuses recorded
/// parses via websiteCidAssetsByName.
/// [keepParsedForTagId] is the DETAIL screen's middle ground: it needs the
/// recorded parses for the ONE group it is showing (its recreate flow
/// reuses them), but retaining them for every other group is what froze
/// the screen. A vault with several groups holds tens of MB of
/// `parsedContent` strings, all decoded and kept on the main thread and
/// then immediately filtered away — the list screen avoids that with
/// `dropParsedContent: true`, which is exactly why the list loads and the
/// detail did not. Generations whose `tagId` differs are stripped like the
/// list's; the requested one keeps everything.
Future<List<WebsiteGeneration>> decodeGenerationsBlobs(
  List<Uint8List> blobs, {
  int yieldEvery = 8,
  bool dropParsedContent = false,
  String? keepParsedForTagId,
}) async {
  final byId = <String, WebsiteGeneration>{};
  var sinceYield = 0;
  for (final blob in blobs) {
    try {
      final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
      for (final raw in (j['generations'] as List<dynamic>? ?? const [])) {
        final g = WebsiteGeneration.fromJson(raw as Map<String, dynamic>);
        if (dropParsedContent ||
            (keepParsedForTagId != null && g.tagId != keepParsedForTagId)) {
          for (final a in g.assets) {
            a.parsedContent = null;
          }
        }
        byId.putIfAbsent(g.id, () => g);
        if (++sinceYield >= yieldEvery) {
          sinceYield = 0;
          await Future<void>.delayed(Duration.zero);
        }
      }
    } catch (e) {
      debugPrint('decodeGenerationsBlobs: parse skipped: $e');
    }
  }
  return byId.values.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
}

/// Decode the merged pointers-manifest blobs into {tagId: pointer},
/// first blob wins a tagId. Exact semantics of the previous inline
/// loop, including the legacy `{tagId: {...}}` map-shape fallback
/// (`j['pointers'] ?? j.values`) and the outer catch that keeps
/// whatever accumulated before a malformed BLOB (per-entry errors are
/// swallowed individually, as before).
Future<Map<String, WebsiteGroupPointer>> decodePointersBlobs(
  List<Uint8List> blobs, {
  int yieldEvery = 16,
}) async {
  final pointers = <String, WebsiteGroupPointer>{};
  var sinceYield = 0;
  try {
    for (final blob in blobs) {
      final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
      for (final raw
          in (j['pointers'] as List<dynamic>? ?? j.values.toList())) {
        if (raw is Map<String, dynamic>) {
          try {
            final p = WebsiteGroupPointer.fromJson(raw);
            pointers.putIfAbsent(p.tagId, () => p);
          } catch (_) {}
        }
        if (++sinceYield >= yieldEvery) {
          sinceYield = 0;
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
  } catch (e) {
    debugPrint('decodePointersBlobs: pointers skipped: $e');
  }
  return pointers;
}
