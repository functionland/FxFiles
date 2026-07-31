// Pure helpers that shape the website-generations cloud manifest
// (`.fula/websites/{userId}.json`) at WRITE time. Shared by BOTH
// writers — native WebsiteService.syncToCloud and web
// WebWebsiteService._appendToCloudManifest — because a strip applied by
// only one of them would oscillate: the other writer re-uploads the
// unstripped copy on its next sync.
//
// Why strip: each generation embeds assets[].parsedContent (≤100KB per
// asset, ≤30 assets) and the manifest accumulates EVERY generation
// forever, so it grows into a multi-MB blob the web list screen must
// download + decrypt + jsonDecode on the browser main thread (the
// mobile freeze). The ONLY consumer of RESTORED parsedContent is the
// web recreate flow's parse-skip, and it reads the freshest occurrence
// per fileName across completed generations (websiteCidAssetsByName,
// web_website_assets_logic.dart) — so keeping exactly those winners and
// nulling every other copy is behavior-preserving while dropping the
// N-way duplicates that dominate the bloat. parsedContent is a nullable
// field on both platforms' fromJson, so a stripped manifest round-trips
// safely everywhere (native re-parses from local bytes when missing).

import 'package:fula_files/core/models/website_generation.dart';

/// Deep-copied [generationJson] with every asset's `parsedContent`
/// nulled. Used for the pending-jobs sidecar snapshots (resume only
/// needs the job handle + light metadata) and as the building block of
/// [stripParsedContentKeepFreshest]. Never mutates the input.
Map<String, dynamic> stripAssetParsedContent(
    Map<String, dynamic> generationJson) {
  final copy = Map<String, dynamic>.from(generationJson);
  final assets = generationJson['assets'];
  if (assets is List) {
    copy['assets'] = [
      for (final a in assets)
        if (a is Map)
          (Map<String, dynamic>.from(a.cast<String, dynamic>())
            ..['parsedContent'] = null)
        else
          a,
    ];
  }
  return copy;
}

DateTime _stamp(Object? v) => v is String
    ? (DateTime.tryParse(v) ?? DateTime.fromMillisecondsSinceEpoch(0))
    : DateTime.fromMillisecondsSinceEpoch(0);

/// Strip `parsedContent` from [generations] (raw manifest maps), keeping
/// it ONLY where it is the value websiteCidAssetsByName would resolve —
/// the first qualifying occurrence per fileName over completed
/// generations ordered newest-first. Mirrors that consumer over raw
/// maps, using the same field coercions as WebsiteGeneration.fromJson /
/// WebsiteAsset.fromJson:
///
///  - generation qualifies iff status (default: completed — fromJson's
///    `?? 3`) == completed;
///  - asset qualifies iff `uploaded == true` and non-empty `cid`;
///  - fileName coerces `as String? ?? ''` (empty names dedupe together);
///  - within one generation, list order; across generations,
///    updatedAt-desc (tiebreak createdAt-desc, then input index — the
///    consumer's unstable sort already leaves ties unspecified).
///
/// A winner keeps its existing value INCLUDING null — resurrecting an
/// older non-null copy would change what the consumer resolves. Output
/// preserves input order; inputs are never mutated; no field access
/// throws (id-less / assets-less / malformed entries pass through
/// stripped).
List<Map<String, dynamic>> stripParsedContentKeepFreshest(
    List<Map<String, dynamic>> generations) {
  // Winner slots: fileName -> (generation input index, asset list index).
  final winners = <String, ({int genIndex, int assetIndex})>{};

  final order = List<int>.generate(generations.length, (i) => i)
    ..sort((ia, ib) {
      final a = generations[ia], b = generations[ib];
      var c = _stamp(b['updatedAt']).compareTo(_stamp(a['updatedAt']));
      if (c != 0) return c;
      c = _stamp(b['createdAt']).compareTo(_stamp(a['createdAt']));
      if (c != 0) return c;
      return ia.compareTo(ib);
    });

  for (final gi in order) {
    final g = generations[gi];
    final status = g['status'] is int
        ? g['status'] as int
        : WebsiteGenStatus.completed.index; // fromJson default
    if (status != WebsiteGenStatus.completed.index) continue;
    final assets = g['assets'];
    if (assets is! List) continue;
    for (var ai = 0; ai < assets.length; ai++) {
      final a = assets[ai];
      if (a is! Map) continue;
      final uploaded = a['uploaded'] == true;
      final cid = a['cid'];
      if (!uploaded || cid is! String || cid.isEmpty) continue;
      final fileName = a['fileName'] is String ? a['fileName'] as String : '';
      winners.putIfAbsent(fileName, () => (genIndex: gi, assetIndex: ai));
    }
  }

  return [
    for (var gi = 0; gi < generations.length; gi++)
      _stripExceptWinners(generations[gi], gi, winners),
  ];
}

Map<String, dynamic> _stripExceptWinners(
  Map<String, dynamic> g,
  int genIndex,
  Map<String, ({int genIndex, int assetIndex})> winners,
) {
  final assets = g['assets'];
  if (assets is! List) return Map<String, dynamic>.from(g);
  final copy = Map<String, dynamic>.from(g);
  copy['assets'] = [
    for (var ai = 0; ai < assets.length; ai++)
      _stripUnlessWinner(assets[ai], genIndex, ai, winners),
  ];
  return copy;
}

Object? _stripUnlessWinner(
  Object? asset,
  int genIndex,
  int assetIndex,
  Map<String, ({int genIndex, int assetIndex})> winners,
) {
  if (asset is! Map) return asset;
  final a = Map<String, dynamic>.from(asset.cast<String, dynamic>());
  final fileName = a['fileName'] is String ? a['fileName'] as String : '';
  final w = winners[fileName];
  final isWinner =
      w != null && w.genIndex == genIndex && w.assetIndex == assetIndex;
  if (!isWinner) a['parsedContent'] = null;
  return a;
}
