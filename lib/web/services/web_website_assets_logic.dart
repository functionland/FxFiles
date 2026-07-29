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

import 'package:xml/xml.dart';

import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/services/website_prompt_builder.dart'
    show kWebsiteAssetBucket;

/// A CID-backed (public-on-IPFS) website asset, reusable across platforms.
/// [taggedFileId] is the tag-manifest association row (null when the asset
/// came from a generation manifest without a current tag row); a non-null
/// [parsedContent] lets recreate skip re-parsing the source bytes.
typedef ResolvedWebsiteAsset = ({
  String fileName,
  String? cid,
  String? gatewayUrl,
  String note,
  String? taggedFileId,
  String? parsedContent,
});

/// One current group file: the tag-manifest association row [id], its name,
/// and its raw remoteKey (null/empty = device-local mobile row).
typedef GroupTaggedFile = ({String id, String fileName, String? remoteKey});

/// A current group file whose remoteKey points into the public
/// `website-assets` bucket but for which no CID was found (bucket LIST
/// failed/lagged) — resolvable via a HEAD of [objectKey] instead of being
/// silently dropped.
typedef PendingCidWebsiteAsset = ({
  String fileName,
  String objectKey,
  String taggedFileId,
});

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
          taggedFileId: null,
          parsedContent: a.parsedContent,
        ),
      );
    }
  }
  return byName;
}

/// Resolve a website group's CURRENT files ([taggedFiles]) into:
///   - `reusable`:  CID-backed (public on IPFS) — usable on every platform;
///   - `pendingCid`: remoteKey points into `website-assets` but no CID was
///     found (LIST failed/lagged) — the caller resolves these via HEAD
///     instead of dropping them;
///   - `appOnly`:   device-local — no public CID in ANY generation AND no
///     cloud copy, so the web can't include them ("on a device");
///   - `cloudOnly`: a private cloud copy elsewhere (non-website-assets
///     remoteKey) with no public CID — the app can include it, the web has
///     no public URL (previously these were silently dropped).
///
/// Files are deduped by name, preserving group order. Reusable entries carry
/// the tag row id when a current tag row exists (enables real removal).
({
  List<ResolvedWebsiteAsset> reusable,
  List<PendingCidWebsiteAsset> pendingCid,
  List<String> appOnly,
  List<String> cloudOnly,
}) resolveWebsiteGroupAssets({
  required List<GroupTaggedFile> taggedFiles,
  required Map<String, ResolvedWebsiteAsset> cidByName,
}) {
  const websiteAssetsPrefix = '$kWebsiteAssetBucket/';
  final reusable = <ResolvedWebsiteAsset>[];
  final pendingCid = <PendingCidWebsiteAsset>[];
  final appOnly = <String>[];
  final cloudOnly = <String>[];
  final seen = <String>{};
  for (final tf in taggedFiles) {
    if (!seen.add(tf.fileName)) continue; // dedupe by name, keep group order
    final hit = cidByName[tf.fileName];
    final remoteKey = tf.remoteKey;
    if (hit != null) {
      reusable.add((
        fileName: hit.fileName,
        cid: hit.cid,
        gatewayUrl: hit.gatewayUrl,
        note: hit.note,
        taggedFileId: tf.id,
        parsedContent: hit.parsedContent,
      ));
    } else if (remoteKey == null || remoteKey.isEmpty) {
      appOnly.add(tf.fileName);
    } else if (remoteKey.startsWith(websiteAssetsPrefix)) {
      final objectKey = remoteKey.substring(websiteAssetsPrefix.length);
      if (objectKey.isEmpty) {
        cloudOnly.add(tf.fileName); // malformed key — surface, don't drop
      } else {
        pendingCid.add((
          fileName: tf.fileName,
          objectKey: objectKey,
          taggedFileId: tf.id,
        ));
      }
    } else {
      cloudOnly.add(tf.fileName);
    }
  }
  return (
    reusable: reusable,
    pendingCid: pendingCid,
    appOnly: appOnly,
    cloudOnly: cloudOnly,
  );
}

/// Sanitize a website display name into its `website-assets` key prefix —
/// byte-for-byte the transform native applies before uploading
/// (WebsiteService: `tagName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')`),
/// e.g. "Real Estate" → "Real_Estate".
String sanitizeWebsiteName(String displayName) =>
    displayName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

/// Parse an S3 `ListBucketResult` body into {fileName: cid}. Each
/// `<Contents>` carries a `<Key>` of `<prefix>/<fileName>` and an `<ETag>`
/// whose (de-quoted) value IS the public IPFS CID. The folder marker (Key
/// == prefix) and entries missing a key/etag are skipped. Throws on
/// malformed XML — the IO caller swallows that to fall back to the manifest.
Map<String, String> parseWebsiteAssetCids(String xmlBody, String prefix) {
  final out = <String, String>{};
  final doc = XmlDocument.parse(xmlBody);
  // Match by LOCAL name — the S3 body declares a default xmlns, so
  // qualified-name lookups (getElement/findAllElements) are namespace-
  // sensitive and would silently miss everything.
  String childText(XmlElement e, String local) {
    for (final c in e.children.whereType<XmlElement>()) {
      if (c.name.local == local) return c.innerText;
    }
    return '';
  }

  for (final c in doc.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'Contents')) {
    final key = childText(c, 'Key');
    final etag = childText(c, 'ETag').replaceAll('"', '');
    if (etag.isEmpty || !key.startsWith(prefix)) continue;
    final fileName = key.substring(prefix.length);
    if (fileName.isEmpty) continue; // folder marker, not a file
    out[fileName] = etag;
  }
  return out;
}

/// Merge the `website-assets` CIDs (authoritative — they ARE on IPFS) over
/// the generation-manifest map. The manifest can record `uploaded=false` /
/// no-CID even when the asset succeeded (issue #44), so `website-assets`
/// wins the CID; the manifest's note (if any) is preserved.
Map<String, ResolvedWebsiteAsset> mergeAuthoritativeCids(
  Map<String, ResolvedWebsiteAsset> manifestCids,
  Map<String, String> websiteAssetCids,
) {
  final out = Map<String, ResolvedWebsiteAsset>.from(manifestCids);
  for (final e in websiteAssetCids.entries) {
    out[e.key] = (
      fileName: e.key,
      cid: e.value,
      gatewayUrl: null, // built from the CID on demand
      note: out[e.key]?.note ?? '',
      taggedFileId: out[e.key]?.taggedFileId,
      parsedContent: out[e.key]?.parsedContent,
    );
  }
  return out;
}
