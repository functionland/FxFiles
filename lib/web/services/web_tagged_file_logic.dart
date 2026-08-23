// Pure key/candidate logic for joining a tagged file to a cloud object.
//
// Deliberately SEPARATE from `web_tagged_file_resolver.dart`: that file
// reaches the network through `web_listing_swr.dart`, which pulls in
// `package:web` -> `dart:js_interop` and therefore cannot even be LOADED
// by the VM test runner. Keeping the decisions here is what makes them
// unit-testable, and matches the repo convention that `*_logic` files
// hold the decisions while services hold the I/O.

import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/remote_object_resolver.dart';

/// Strip a leading segment ONLY when it is a real bucket name, so
/// `images-v8/photo.jpg` and `photo.jpg` match while the shelf key
/// `2026/07/report.pdf` keeps all of its segments.
///
/// This is the exact rule whose naive version (`RegExp(r'^[a-z0-9-]+$')`,
/// still live in `WebTagService.resolveTagShareScope`) turns `2026` into
/// a bucket name.
String normalizeTaggedObjectKey(String key) {
  var k = key;
  while (k.startsWith('/')) {
    k = k.substring(1);
  }
  final firstSlash = k.indexOf('/');
  if (firstSlash > 0) {
    final head = k.substring(0, firstSlash);
    if (isKnownBucketName(head) ||
        kKnownBucketBases.contains(BucketVersionResolver.baseOf(head))) {
      k = k.substring(firstSlash + 1);
    }
  }
  while (k.startsWith('/')) {
    k = k.substring(1);
  }
  return k;
}

/// Index one bucket's listing by every key form a candidate might use.
Map<String, T> indexListingByKey<T>(
  Iterable<T> objects,
  String Function(T) keyOf,
) {
  final out = <String, T>{};
  for (final o in objects) {
    final k = keyOf(o);
    out[k] = o;
    out[normalizeTaggedObjectKey(k)] = o;
  }
  return out;
}

/// First candidate present in [listings], or null when none resolve.
///
/// Candidates arrive best-first from `resolveRemoteObjectCandidates`, so
/// order is meaningful: for a managed category the healthy `-v8` bucket
/// precedes the gc-damaged legacy one.
(String, T)? firstResolvedCandidate<T>(
  List<RemoteObjectRef> refs,
  Map<String, Map<String, T>> listings,
) {
  for (final ref in refs) {
    final listing = listings[ref.bucket];
    if (listing == null) continue;
    final hit = listing[ref.key] ?? listing[normalizeTaggedObjectKey(ref.key)];
    if (hit != null) return (ref.bucket, hit);
  }
  return null;
}

/// The buckets to list FIRST: each file's best candidate only.
///
/// Legacy buckets are the gc-damaged ones that time out, so they are
/// only worth listing for files that did not resolve without them.
Set<String> preferredBuckets(Iterable<List<RemoteObjectRef>> candidates) => {
      for (final refs in candidates)
        if (refs.isNotEmpty) refs.first.bucket,
    };
