// Pure helpers behind the web website-detail screen's asset resolution.
//
// The website manifest records each generation's assets with a public IPFS
// `cid` once uploaded (unencrypted). The web reuses CID-backed assets across
// platforms and flags a group file as "on a device — include it from the app"
// ONLY when it has no public CID AND no cloud copy. Resolving from a SINGLE
// (latest) generation under-counts the CID-backed set — per-run upload caps
// (10-file / size / 50 MB total) and transient failures mean the freshest run
// can be missing assets an earlier run uploaded successfully. So this resolves
// a group's CURRENT files against the UNION of ALL completed generations.
//
// Scoping to current membership (rather than a raw union of every generation's
// assets) avoids surfacing files the user later REMOVED from the group but
// that still live in an old generation's manifest.

import 'package:fula_files/core/models/website_generation.dart';

/// A CID-backed (public-on-IPFS) website asset, reusable across platforms.
typedef ResolvedWebsiteAsset = ({
  String fileName,
  String? cid,
  String? gatewayUrl,
  String note,
});

/// One current group file: its name + whether it has a private cloud copy
/// (a non-empty `remoteKey` in the tag manifest).
typedef GroupTaggedFile = ({String fileName, bool hasRemoteKey});

/// The freshest CID-backed asset per `fileName` across ALL completed
/// generations. [generationsNewestFirst] MUST be newest-first; the first
/// occurrence of a name wins, i.e. the most recent CID/URL for that file.
Map<String, ResolvedWebsiteAsset> websiteCidAssetsByName(
    List<WebsiteGeneration> generationsNewestFirst) {
  final byName = <String, ResolvedWebsiteAsset>{};
  for (final g in generationsNewestFirst) {
    if (g.status != WebsiteGenStatus.completed) continue;
    for (final a in g.assets) {
      if (!a.uploaded || a.cid == null || a.cid!.isEmpty) continue;
      byName.putIfAbsent(
        a.fileName,
        () => (
          fileName: a.fileName,
          cid: a.cid,
          gatewayUrl: a.gatewayUrl,
          note: a.comment ?? '',
        ),
      );
    }
  }
  return byName;
}

/// Resolve a website group's CURRENT files ([taggedFiles]) into:
///   - `reusable`: CID-backed (public on IPFS) — usable on every platform;
///   - `appOnly`:  device-local — no public CID in ANY generation AND no
///     cloud copy, so the web can't include them ("on a device").
///
/// A file with a private cloud copy (`hasRemoteKey`) but no public CID is
/// neither reusable-on-web nor app-only — it's omitted (the app can reuse it,
/// but the web has no public URL to hand the generator). Files are deduped by
/// name, preserving group order.
({List<ResolvedWebsiteAsset> reusable, List<String> appOnly})
    resolveWebsiteGroupAssets({
  required List<GroupTaggedFile> taggedFiles,
  required Map<String, ResolvedWebsiteAsset> cidByName,
}) {
  final reusable = <ResolvedWebsiteAsset>[];
  final appOnly = <String>[];
  final seen = <String>{};
  for (final tf in taggedFiles) {
    if (!seen.add(tf.fileName)) continue; // dedupe by name, keep group order
    final hit = cidByName[tf.fileName];
    if (hit != null) {
      reusable.add(hit);
    } else if (!tf.hasRemoteKey) {
      appOnly.add(tf.fileName);
    }
  }
  return (reusable: reusable, appOnly: appOnly);
}
