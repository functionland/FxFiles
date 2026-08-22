// Central resolver for the "v8 fresh-bucket" migration.
//
// An `ipfs repo gc` on the gateway damaged some buckets' encrypted forest
// index, so those legacy buckets accept *reads* but block *writes* (upload /
// delete / rename all do a forest read-modify-write that throws on a gc'd
// node). The fix: route NEW writes to a fresh `<base>-v8` sibling bucket — a
// fresh bucket has an empty forest, so writes succeed, and the just-deployed
// server fix keeps its nodes pinned so it can't re-rot.
//
// See docs/v8-bucket-migration-plan.md for the full design. This class is the
// single source of truth for which buckets are version-managed and how a base
// name maps to its write target + read set.
//
// PHASE 1 covers the content categories only (images / videos / audio /
// documents). The shelf (dump) and the metadata buckets are migrated in later
// phases with different patterns (manifest-controller / copy-forward), so they
// are intentionally NOT in [managedBaseBuckets] yet.
library;

class BucketVersionResolver {
  BucketVersionResolver._();

  /// Suffix for fresh buckets. `images` → `images-v8`. (Coincides with the
  /// SDK's walkable-v8 forest format, which fresh buckets are born in.)
  static const String versionSuffix = 'v8';

  /// Master switch for v8 write-routing. While **false** the app behaves
  /// exactly as before the migration: writes and reads both target the legacy
  /// buckets, and the legacy-write guard is inert.
  ///
  /// Currently **true** on the `feat/v8-bucket-migration` branch: content
  /// (P1/P2), the P6 metadata buckets, and the P7 shelf-content buckets are all
  /// routed and live-verified (device + server). The pre-flip gates in
  /// `docs/v8-bucket-migration-premortem.md` (§10/§11) still gate merging this
  /// branch to a production release; flag-off stays an exact no-op for a fast
  /// rollback. Tests reset it around each case.
  static bool enabled = true;

  /// Base buckets whose writes route to a `-v8` sibling and whose reads
  /// (Phase 2) merge `[base, base-v8]`. Phase 1 = content categories only.
  static const Set<String> managedBaseBuckets = <String>{
    'images',
    'videos',
    'audio',
    'documents',
    // Added 2026-08-22. `archives` was the one content category still
    // unmanaged, so it had no `-v8` sibling to fall back to — and its
    // legacy forest root is gc-damaged: two phone net-export captures show
    // `GET /archives/Qmae36f95…` returning 500 after 30.2s, every time,
    // with no alternative to read. Joining the managed set gives it what
    // the other categories already have: new uploads land in a healthy
    // `archives-v8`, and `listCategoryCached` merges legacy + v8 while
    // treating a legacy failure as EMPTY instead of an error, so the
    // category opens instead of hanging.
    //
    // Write paths audited before flipping (all route via [writeBucket], so
    // none trip the legacy-write guard): SyncService.queueUpload — the
    // documented single chokepoint for every native content upload;
    // web_bucket_screen's per-category picker; web_recent_files_section's
    // cross-category "+" tile. The raw Cloud Files manager writes to the
    // bucket being browsed, but it already gates on
    // [isForbiddenWriteTarget], so `archives` simply becomes read-only
    // there — exactly how `images` and friends already behave.
    //
    // HARD INVARIANT (v8 migration): the legacy `archives` bucket is never
    // deleted. Its objects stay readable and keep existing share links
    // working.
    'archives',
  };

  /// Metadata buckets migrated to v8 INCREMENTALLY (P6). A bucket here routes
  /// its WRITES to a `-v8` sibling and is a forbidden legacy write target, but
  /// it does NOT get the content LIST-merge — each metadata service does its own
  /// MERGE of the legacy + v8 manifests on restore (read both, combine, v8
  /// wins). Add a bucket here ONLY once ALL of its writers are routed, or the
  /// flag flip strands them at the guard.
  static const Set<String> managedMetadataBuckets = <String>{
    'dump-metadata', // shelf (P6)
    'tag-metadata', // tags (P6)
    'nft-metadata', // nft (P6)
    'website-metadata', // website + ipns-pointer (P6 — BOTH writers routed)
    'app-metadata', // app store (P6)
    // SHARED by 5 services — sync-mapping + shares + collaborations +
    // folder-watch + per-group collab manifests. Added LAST, only once ALL
    // five writers (and the collab manifest write-unit + link `'b'`) route via
    // writeBucket; this single entry flips them all live at once. The portal
    // (pinning-service) is migrated separately (Part B).
    'fula-metadata',
    // Type-B (many-objects-per-bucket) — each service does its OWN merge:
    // face-metadata reads per-key (downloadMetadataMerged.first); playlists
    // does a LIST-merge of [legacy, v8] + a per-id delete tombstone. Both
    // writers are routed via writeBucket before this entry flips them live.
    'face-metadata',
    'playlists',
  };

  /// Shelf CONTENT buckets migrated to v8 (P7). Like [managedMetadataBuckets]
  /// these route writes to a `-v8` sibling and are forbidden legacy write
  /// targets — but they get NO list-merge: the shelf addresses each blob by the
  /// explicit `remoteKey` recorded in its manifest (it never *lists* these
  /// buckets), so a read targets one known bucket (carried per-item on
  /// `ShelfItem.sourceBucket`), not a merged listing. Add a bucket here ONLY
  /// once ALL of its writers are routed, or the flag flip strands them at the
  /// write guard.
  static const Set<String> managedContentKeyedBuckets = <String>{
    'dump', // shelf item bodies (P7)
    'dump-thumbs', // shelf thumbnails (P7)
  };

  /// A bucket whose writes route to a `-v8` sibling: a content category, a
  /// migrated metadata bucket, or a migrated shelf-content bucket.
  static bool _routesToV8(String b) =>
      managedBaseBuckets.contains(b) ||
      managedMetadataBuckets.contains(b) ||
      managedContentKeyedBuckets.contains(b);

  /// True if [bucket] is a managed *base* (legacy) bucket — i.e. one whose
  /// writes should be redirected to its `-v8` sibling.
  static bool isManagedBase(String bucket) =>
      managedBaseBuckets.contains(bucket);

  /// True if [bucket] is a `-v8` sibling (e.g. `images-v8`).
  static bool isV8(String bucket) => bucket.endsWith('-$versionSuffix');

  /// The base (legacy) bucket name for [bucket]: strips a trailing `-v8`
  /// suffix if present, else returns [bucket] unchanged. So `baseOf('images-v8')
  /// == 'images'` and `baseOf('images') == 'images'`. Inverse-ish of
  /// [writeBucket]; used to map a v8 bucket back to its category/base.
  static String baseOf(String bucket) => isV8(bucket)
      ? bucket.substring(0, bucket.length - versionSuffix.length - 1)
      : bucket;

  /// True if [a] and [b] belong to the same bucket family — the same base
  /// after stripping a `-v8` suffix (`sameFamily('images', 'images-v8')`). A
  /// null [a] never matches. Used by sync-state / mapping lookups so a file
  /// recorded under either the legacy base or its `-v8` sibling resolves when
  /// queried for either.
  static bool sameFamily(String? a, String b) =>
      a != null && baseOf(a) == baseOf(b);

  /// The bucket a new upload for [base] should be written to.
  ///
  /// When [enabled], a managed base routes to its `-v8` sibling. Everything
  /// else passes through unchanged: already-`-v8` names, the shelf/metadata
  /// buckets (migrated later), custom folder-sync targets, and the test
  /// bucket. Idempotent — `writeBucket('images-v8') == 'images-v8'`.
  static String writeBucket(String base) =>
      (enabled && _routesToV8(base)) ? '$base-$versionSuffix' : base;

  /// The buckets a read of [base] should cover — legacy first, then v8 — so a
  /// merged view shows old + new content. Consumed by the Phase 2 read-merge;
  /// shipped here (unused) so the seam exists. Unmanaged/disabled → `[base]`.
  static List<String> readBuckets(String base) =>
      (enabled && isManagedBase(base))
          ? <String>[base, '$base-$versionSuffix']
          : <String>[base];

  /// Read-only-legacy guard: while [enabled], writing (upload / create) to a
  /// managed *legacy* bucket is a bug — new data must never land in a
  /// gc-damaged bucket. Callers on the write path check this and throw.
  static bool isForbiddenWriteTarget(String bucket) =>
      enabled && _routesToV8(bucket);
}
