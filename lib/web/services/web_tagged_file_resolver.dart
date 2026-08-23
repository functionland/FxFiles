// Resolve tagged files to the cloud objects they actually point at.
//
// WHY THIS EXISTS
// ---------------
// `TaggedFile` stores a `remoteKey` and a `fileName` and NOTHING ELSE —
// no bucket, no size, no content type. Every web thumbnail (`WebThumb`)
// and every web viewer needs `(bucket, key)`. That single missing lookup
// is why the Tags screen could only show a generic icon and a SnackBar
// saying "find it in its category".
//
// The bucket is recovered with the canonical
// `resolveRemoteObjectCandidates`, NOT by splitting the key on '/'.
// See the header of `remote_object_resolver.dart`: a shelf key like
// `2026/07/report.pdf` resolves to a bucket literally named `2026` under
// the naive reading, and that defect still lives in
// `WebTagService.resolveTagShareScope` (`RegExp(r'^[a-z0-9-]+$')`), which
// is deliberately not reused here. That method also collapses a tag to a
// single MAJORITY bucket and silently drops every file from any other
// one — fine for "share a tag as one scope", wrong for browsing, where a
// dropped file is an invisible bug.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/remote_object_resolver.dart';
import 'package:fula_files/web/services/web_listing_swr.dart';

/// One tagged file plus the cloud object it resolved to (if any).
class ResolvedTaggedFile {
  final TaggedFile taggedFile;

  /// The bucket the object was found in. Null when unresolved.
  final String? bucket;

  /// The listed object. Null when the file has no cloud copy we can find
  /// — a local-only tag from the mobile app, or a deleted object.
  final FulaObject? object;

  const ResolvedTaggedFile({
    required this.taggedFile,
    this.bucket,
    this.object,
  });

  bool get inCloud => bucket != null && object != null;

  String get displayName => taggedFile.fileName;

  ResolvedTaggedFile _found(String bucket, FulaObject object) =>
      ResolvedTaggedFile(
          taggedFile: taggedFile, bucket: bucket, object: object);
}

/// Per-bucket listing budget. One damaged legacy bucket must never hold
/// the whole Tags screen hostage — the same lesson as the websites
/// screen's bounded reads.
const Duration _kListingBudget = Duration(seconds: 8);

class WebTaggedFileResolver {
  WebTaggedFileResolver._();
  static final WebTaggedFileResolver instance = WebTaggedFileResolver._();

  /// Listings already fetched during this screen's lifetime, keyed by
  /// bucket. Cleared by [reset] so a pull-to-refresh re-reads.
  final Map<String, Map<String, FulaObject>> _byBucket = {};

  void reset() => _byBucket.clear();

  /// Resolve [files] to cloud objects.
  ///
  /// Returns one entry per input file, in the same order, so the caller
  /// can render unresolved files rather than silently dropping them.
  Future<List<ResolvedTaggedFile>> resolveAll(List<TaggedFile> files) async {
    final candidates = <int, List<RemoteObjectRef>>{};
    for (var i = 0; i < files.length; i++) {
      final rk = files[i].remoteKey;
      if (rk == null || rk.isEmpty) continue;
      candidates[i] = resolveRemoteObjectCandidates(
        remoteKey: rk,
        fileName: files[i].fileName,
      );
    }

    // Two passes so the common case stays cheap. The resolver already
    // orders candidates best-first, and for a managed category that
    // means the `-v8` bucket precedes the legacy one. Legacy buckets are
    // exactly the gc-damaged ones that time out, so they are only listed
    // when a file genuinely did not resolve without them.
    final preferred = <String>{
      for (final refs in candidates.values)
        if (refs.isNotEmpty) refs.first.bucket,
    };
    await _loadBuckets(preferred);

    final out = List<ResolvedTaggedFile>.generate(
      files.length,
      (i) => ResolvedTaggedFile(taggedFile: files[i]),
    );
    final unresolved = <int>[];
    for (final entry in candidates.entries) {
      final hit = _lookup(entry.value);
      if (hit != null) {
        out[entry.key] = out[entry.key]._found(hit.$1, hit.$2);
      } else {
        unresolved.add(entry.key);
      }
    }

    if (unresolved.isNotEmpty) {
      final remaining = <String>{
        for (final i in unresolved)
          for (final ref in candidates[i]!)
            if (!_byBucket.containsKey(ref.bucket)) ref.bucket,
      };
      if (remaining.isNotEmpty) {
        await _loadBuckets(remaining);
        for (final i in unresolved) {
          final hit = _lookup(candidates[i]!);
          if (hit != null) out[i] = out[i]._found(hit.$1, hit.$2);
        }
      }
    }

    return out;
  }

  /// First candidate that exists in a listing we have.
  (String, FulaObject)? _lookup(List<RemoteObjectRef> refs) {
    for (final ref in refs) {
      final listing = _byBucket[ref.bucket];
      if (listing == null) continue;
      final o = listing[ref.key] ?? listing[normalizeTaggedObjectKey(ref.key)];
      if (o != null) return (ref.bucket, o);
    }
    return null;
  }

  Future<void> _loadBuckets(Set<String> buckets) async {
    final todo = buckets.where((b) => !_byBucket.containsKey(b)).toList();
    if (todo.isEmpty) return;
    // Concurrent, but each independently bounded and independently
    // failing: a dead bucket contributes an empty map, never an
    // exception that loses every other bucket's results.
    await Future.wait(todo.map(_loadBucket));
  }

  Future<void> _loadBucket(String bucket) async {
    try {
      final listing = await WebListingSwr.instance
          .getListing(bucket)
          .timeout(_kListingBudget);
      _byBucket[bucket] = {
        for (final o in listing.objects) ...{
          o.key: o,
          normalizeTaggedObjectKey(o.key): o,
        },
      };
    } catch (e) {
      // Record the miss so the second pass does not retry it.
      _byBucket[bucket] = const {};
      debugPrint('WebTaggedFileResolver: listing $bucket failed: $e');
    }
  }

  /// Strip a leading segment ONLY when it is a real bucket name, so
  /// `images-v8/photo.jpg` and `photo.jpg` match while the shelf key
  /// `2026/07/x.pdf` keeps all of its segments.
  ///
  /// Public for unit tests: this is the exact rule whose naive version
  /// (`RegExp(r'^[a-z0-9-]+$')`) turns `2026` into a bucket name.
  static String normalizeTaggedObjectKey(String key) {
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
}
