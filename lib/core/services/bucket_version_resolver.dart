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
  /// It stays false in production until the Phase 2 read-merge ships — routing
  /// uploads to `images-v8` while the gallery still lists `images` would hide
  /// new uploads from the user. Tests flip it to exercise the routing.
  static bool enabled = false;

  /// Base buckets whose writes route to a `-v8` sibling and whose reads
  /// (Phase 2) merge `[base, base-v8]`. Phase 1 = content categories only.
  static const Set<String> managedBaseBuckets = <String>{
    'images',
    'videos',
    'audio',
    'documents',
  };

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
      (enabled && isManagedBase(base)) ? '$base-$versionSuffix' : base;

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
      enabled && isManagedBase(bucket);
}
