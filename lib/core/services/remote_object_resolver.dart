// Canonical (bucket, key) resolution for a stored `remoteKey`.
//
// WHY THIS EXISTS
// ---------------
// `remoteKey` has genuinely MIXED semantics across the app's history:
//
//   * BARE object key — the dominant form. `SyncService.queueUpload` takes
//     `remoteBucket` and `remoteKey` as separate arguments, and the bucket is
//     recorded elsewhere (`SyncState.remoteBucket`, `ShelfItem.sourceBucket`).
//     Shelf bodies look like `2026/07/<id>-name.pdf`; file-browser uploads can
//     be a naked `photo.jpg` with no slash at all.
//   * COMPOSITE `bucket/key` — written only by the web cloud browser
//     (`web_bucket_screen.dart`, `web_cloud_files_screen.dart`) so tags
//     round-trip between platforms.
//
// Code that assumes ONE of those forms breaks on the other. AiAskService used
// to split on '/' and take the first segment as the bucket, which turned the
// shelf key `2026/07/x.pdf` into a request for a bucket literally named
// `2026` — a 404 that was swallowed, so Ask AI silently sent zero files.
//
// The rule here: never guess a bucket from "whatever is before the first
// slash". Only a name on the KNOWN-BUCKET allowlist may be read as a bucket,
// and when the reading is still ambiguous (a user folder that happens to be
// called `documents/`) BOTH interpretations are returned so the caller can try
// them in order rather than failing silently on the wrong one.
//
// WEB-SAFE: this library must not import `dart:io`. The `FileCategory` enum
// lives in the dart:io-tainted `file_service.dart`, so the extension mapping is
// copied below — the same precedent as `web_tag_service._guessBucketForFileName`.
library;

import 'package:fula_files/core/services/bucket_version_resolver.dart';

/// One concrete place to look for an object.
class RemoteObjectRef {
  final String bucket;
  final String key;

  const RemoteObjectRef(this.bucket, this.key);

  @override
  bool operator ==(Object other) =>
      other is RemoteObjectRef && other.bucket == bucket && other.key == key;

  @override
  int get hashCode => Object.hash(bucket, key);

  @override
  String toString() => '$bucket/$key';
}

/// Buckets that may legitimately appear as a `bucket/` prefix on a remoteKey.
///
/// Deliberately an allowlist, NOT a shape test: `web_tag_service` uses
/// `RegExp(r'^[a-z0-9-]+$')` for this and that pattern matches `2026`, which is
/// exactly the defect this resolver exists to avoid.
const Set<String> kKnownBucketBases = <String>{
  // Content categories (FileCategory.bucketName).
  'images',
  'videos',
  'audio',
  'documents',
  'downloads',
  'archives',
  'starred',
  'other',
  // Shelf content.
  'dump',
  'dump-thumbs',
  // Public website assets — legitimately attachable user content.
  'website-assets',
  // NOTE: the internal metadata buckets (tag-metadata, fula-metadata,
  // face-metadata, playlists, ...) are deliberately ABSENT. They hold the
  // user's manifests, never attachable content, and including them would let
  // an ambiguous key resolve an internal manifest into an AI upload.
};

/// True when [name] is a known bucket, either a base or its `-v8` sibling.
bool isKnownBucketName(String name) =>
    kKnownBucketBases.contains(name) ||
    kKnownBucketBases.contains(BucketVersionResolver.baseOf(name));

/// Category bucket base for [fileName], mirroring `FileCategory.fromExtension`.
///
/// Kept in sync by hand because the enum lives in a dart:io-tainted library
/// that cannot be imported from web-reachable code.
String guessBucketBaseForFileName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final ext = dot == -1 ? '' : fileName.substring(dot + 1).toLowerCase();

  const images = {
    'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif', 'svg', //
    'raw', 'cr2', 'nef', 'arw',
  };
  const videos = {
    'mp4', 'mov', 'avi', 'mkv', 'wmv', 'flv', 'webm', '3gp', 'm4v', //
    'mpeg', 'mpg',
  };
  const audio = {
    'mp3', 'wav', 'aac', 'flac', 'ogg', 'wma', 'm4a', 'opus', 'aiff',
  };
  const documents = {
    'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf', //
    'odt', 'ods', 'odp', 'csv', 'md', 'json', 'xml', 'html', 'log', //
    'ini', 'cfg', 'conf',
  };
  const archives = {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'iso'};

  if (images.contains(ext)) return 'images';
  if (videos.contains(ext)) return 'videos';
  if (audio.contains(ext)) return 'audio';
  if (documents.contains(ext)) return 'documents';
  if (archives.contains(ext)) return 'archives';
  return 'other';
}

/// The buckets in [bucket]'s family, most-likely first: [bucket] itself, then
/// its `-v8` sibling, then its legacy base. De-duplicated, so an unmanaged
/// bucket (or v8 routing being off) collapses to a single entry.
List<String> _family(String bucket) {
  final base = BucketVersionResolver.baseOf(bucket);
  final v8 = BucketVersionResolver.writeBucket(base);
  return <String>{bucket, v8, base}.toList();
}

/// Ordered places to look for the object described by [remoteKey].
///
/// [sourceBucket] is authoritative when recorded (`ShelfItem.sourceBucket`).
/// [fallbackBase] is the owning feature's default bucket base — pass `'dump'`
/// for shelf items so a pre-P7 row with no `sourceBucket` resolves against the
/// shelf family instead of being guessed from its file extension.
///
/// Callers should attempt each candidate in order and treat the object as
/// missing only once every candidate fails.
List<RemoteObjectRef> resolveRemoteObjectCandidates({
  required String remoteKey,
  required String fileName,
  String? sourceBucket,
  String? fallbackBase,
}) {
  var key = remoteKey.trim();
  while (key.startsWith('/')) {
    key = key.substring(1);
  }
  // Empty, or a folder marker rather than an object.
  if (key.isEmpty || key.endsWith('/')) return const <RemoteObjectRef>[];

  // A leading segment is only treated as a bucket when it IS one.
  String? prefixBucket;
  var strippedKey = key;
  final firstSlash = key.indexOf('/');
  if (firstSlash > 0) {
    final head = key.substring(0, firstSlash);
    if (isKnownBucketName(head)) {
      prefixBucket = head;
      strippedKey = key.substring(firstSlash + 1);
    }
  }

  final out = <RemoteObjectRef>[];
  void add(String bucket, String objectKey) {
    if (objectKey.isEmpty) return;
    final ref = RemoteObjectRef(bucket, objectKey);
    if (!out.contains(ref)) out.add(ref);
  }

  // 1. An explicitly recorded bucket wins; keys are stored bare beside it.
  final explicit = sourceBucket?.trim();
  if (explicit != null && explicit.isNotEmpty) {
    for (final b in _family(explicit)) {
      add(b, strippedKey);
    }
  }

  // 2. A composite `knownBucket/key` reading.
  if (prefixBucket != null) {
    for (final b in _family(prefixBucket)) {
      add(b, strippedKey);
    }
  }

  // 3. The whole thing as a bare key, in the feature's default family (or the
  //    category implied by the file name). This is also the recovery path when
  //    reading 2 was wrong — e.g. a user folder genuinely named `documents/`.
  final base = (fallbackBase != null && fallbackBase.trim().isNotEmpty)
      ? fallbackBase.trim()
      : guessBucketBaseForFileName(fileName);
  for (final b in _family(BucketVersionResolver.writeBucket(base))) {
    add(b, key);
  }

  return out;
}
