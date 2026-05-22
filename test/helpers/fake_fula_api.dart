// In-memory fake of the FulaApi surface for unit + widget tests.
//
// Designed so each test wires up just the canned responses it
// needs:
//
// ```dart
// final fake = FakeFulaApi();
// fake.bucketsResponse = const ['images', 'videos'];
// fake.objectsResponseFor['images'] = [smallImageObject];
// fake.downloadResponseFor['images:foo.jpg'] = Uint8List.fromList([1, 2, 3]);
// final container = makeTestContainer(fulaApi: fake);
// ```
//
// Use cases NOT covered: anything that requires a real EncryptedClient
// handle (the FRB type from fula_client). Tests that need a live SDK
// belong in integration_test/, not unit/widget tests.

import 'dart:typed_data';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/fula_api.dart';
import 'package:fula_files/core/services/fula_api_types.dart';

/// In-memory implementation. Defaults to "configured, no buckets, no
/// objects" so a fresh `FakeFulaApi()` returns sensible empties for
/// any unset field.
class FakeFulaApi implements FulaApi {
  // ---- Wire-once config ----
  @override
  bool isConfigured = true;

  @override
  String? defaultBucket;

  // ---- Per-method canned responses ----

  /// Fed to [listBuckets]. Set to throw to simulate master-down.
  List<String> bucketsResponse = const <String>[];

  /// Optional override for the entire [listBucketsCached] result.
  /// When null, [listBucketsCached] derives from [bucketsResponse]
  /// (success path) or [bucketsCachedFallback] (failure path).
  ({List<String> buckets, bool stale, DateTime? fetchedAt})?
      bucketsCachedResponse;

  /// Fallback served by [listBucketsCached] when the live attempt
  /// throws. Set to non-null to simulate "master down + cache
  /// available". Set to null to simulate "master down + no cache".
  ({List<String> buckets, bool stale, DateTime? fetchedAt})?
      bucketsCachedFallback;

  /// Per-bucket object lists. Missing buckets return an empty list.
  Map<String, List<FulaObject>> objectsResponseFor =
      <String, List<FulaObject>>{};

  /// Per-`(bucket, key)` byte payloads for downloads. Missing entries
  /// throw `FulaApiException`. Key format: `"$bucket:$key"`.
  Map<String, Uint8List> downloadResponseFor = <String, Uint8List>{};

  /// Same key format as [downloadResponseFor]; LAN-first variant.
  /// Falls back to [downloadResponseFor] when missing.
  Map<String, Uint8List> localDownloadResponseFor = <String, Uint8List>{};

  /// Per-`(bucket, key)` upload returns. Missing entries return a
  /// deterministic synthetic etag + cid pair so tests don't need to
  /// stub for every PUT.
  Map<String, UploadResult> uploadResponseFor = <String, UploadResult>{};

  // ---- Inducible failure modes ----

  /// When non-null, [listBuckets] throws this on every call.
  Object? listBucketsError;

  /// When set, [listBucketsCached]'s live call throws on first try
  /// AND on the retry (i.e., master is truly unreachable).
  bool listBucketsCachedThrowsOnLive = false;

  /// When non-null, [listObjects] throws this when invoked for the
  /// listed bucket.
  Map<String, Object> listObjectsErrorFor = <String, Object>{};

  /// When non-null, [downloadObject] throws this for the matching
  /// `"$bucket:$key"` key.
  Map<String, Object> downloadErrorFor = <String, Object>{};

  /// When non-null, [uploadObject] throws this.
  Object? uploadObjectError;

  // ---- Call counters (for verifying call shapes) ----

  int listBucketsCalls = 0;
  int listBucketsCachedCalls = 0;
  final Map<String, int> listObjectsCalls = <String, int>{};
  final Map<String, int> downloadCalls = <String, int>{};
  final Map<String, int> uploadCalls = <String, int>{};
  final List<String> deletedKeys = <String>[];

  // ---- Interface implementations ----

  @override
  Future<List<String>> listBuckets() async {
    listBucketsCalls++;
    final err = listBucketsError;
    if (err != null) throw err;
    return List<String>.from(bucketsResponse);
  }

  @override
  Future<({List<String> buckets, bool stale, DateTime? fetchedAt})>
      listBucketsCached() async {
    listBucketsCachedCalls++;
    if (bucketsCachedResponse != null) return bucketsCachedResponse!;
    if (listBucketsCachedThrowsOnLive) {
      if (bucketsCachedFallback != null) return bucketsCachedFallback!;
      throw FulaApiException('FakeFulaApi: master down + no cache');
    }
    return (
      buckets: List<String>.from(bucketsResponse),
      stale: false,
      fetchedAt: DateTime.now(),
    );
  }

  @override
  Future<List<FulaObject>> listObjects(
    String bucket, {
    String prefix = '',
    bool recursive = false,
  }) async {
    listObjectsCalls[bucket] = (listObjectsCalls[bucket] ?? 0) + 1;
    final err = listObjectsErrorFor[bucket];
    if (err != null) throw err;
    final all = objectsResponseFor[bucket] ?? const <FulaObject>[];
    if (prefix.isEmpty) return List<FulaObject>.from(all);
    return all.where((f) => f.key.startsWith(prefix)).toList();
  }

  /// Optional override for the entire [listObjectsCached] result, keyed
  /// by bucket. Bypasses the default "wrap listObjects in a stale-aware
  /// record" behaviour. Use to simulate "live failed, stale served".
  Map<String, ({List<FulaObject> objects, bool stale, DateTime? fetchedAt})>
      objectsCachedResponseFor =
      <String, ({List<FulaObject> objects, bool stale, DateTime? fetchedAt})>{};

  @override
  Future<({List<FulaObject> objects, bool stale, DateTime? fetchedAt})>
      listObjectsCached(
    String bucket, {
    String prefix = '',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final override = objectsCachedResponseFor[bucket];
    if (override != null) return override;
    final objects = await listObjects(bucket, prefix: prefix);
    return (objects: objects, stale: false, fetchedAt: DateTime.now());
  }

  @override
  Future<Uint8List> downloadObject(
    String bucket,
    String key, {
    String? contentCid,
  }) async {
    final composite = '$bucket:$key';
    downloadCalls[composite] = (downloadCalls[composite] ?? 0) + 1;
    final err = downloadErrorFor[composite];
    if (err != null) throw err;
    final bytes = downloadResponseFor[composite];
    if (bytes == null) {
      throw FulaApiException(
        'FakeFulaApi.downloadObject: no stub for "$composite"',
      );
    }
    return bytes;
  }

  @override
  Future<Uint8List> downloadWithLocalFallback(String bucket, String key) async {
    final composite = '$bucket:$key';
    final local = localDownloadResponseFor[composite];
    if (local != null) return local;
    return downloadObject(bucket, key);
  }

  @override
  Future<UploadResult> uploadObject(
    String bucket,
    String key,
    Uint8List data, {
    String? contentType,
    Map<String, String>? metadata,
  }) async {
    final composite = '$bucket:$key';
    uploadCalls[composite] = (uploadCalls[composite] ?? 0) + 1;
    final err = uploadObjectError;
    if (err != null) throw err;
    final canned = uploadResponseFor[composite];
    if (canned != null) return canned;
    // Synthesize a deterministic result so callers without a stub
    // still get a sensible response.
    final synthetic = 'bafkr4ifakeetagfor${composite.hashCode.toUnsigned(32).toRadixString(16)}';
    return UploadResult(etag: synthetic, contentCid: synthetic);
  }

  @override
  Future<String> uploadLargeFile(
    String bucket,
    String key,
    Uint8List data, {
    int chunkSize = 5 * 1024 * 1024,
    void Function(UploadProgress)? onProgress,
    Map<String, String>? metadata,
  }) async {
    // Fire a final progress event so widget code that listens for it
    // sees a "completed" state.
    if (onProgress != null) {
      onProgress(UploadProgress(
        bytesUploaded: data.length,
        totalBytes: data.length,
      ));
    }
    final result = await uploadObject(bucket, key, data, metadata: metadata);
    return result.etag;
  }

  @override
  Future<String> uploadLargeFileFromPath(
    String bucket,
    String key,
    String filePath, {
    void Function(UploadProgress)? onProgress,
  }) async {
    // Tests use the in-memory variants; the path variant is here for
    // interface completeness. Synthesize as if zero-byte upload.
    if (onProgress != null) {
      onProgress(UploadProgress(bytesUploaded: 0, totalBytes: 0));
    }
    final result = await uploadObject(bucket, key, Uint8List(0));
    return result.etag;
  }

  @override
  Future<void> deleteObject(String bucket, String key) async {
    deletedKeys.add('$bucket:$key');
    objectsResponseFor[bucket] =
        (objectsResponseFor[bucket] ?? const <FulaObject>[])
            .where((f) => f.key != key)
            .toList();
  }
}
