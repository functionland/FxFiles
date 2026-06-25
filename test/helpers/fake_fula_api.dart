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

import 'package:fula_client/fula_client.dart' as fula;
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

  /// Counters and overrides for the Phase C resumable / cancellable
  /// path. Default behaviour: same as `uploadLargeFileFromPath` —
  /// synthesize a zero-byte upload result.
  final Map<String, int> resumableUploadCalls = <String, int>{};
  final Map<String, int> resumeUploadCalls = <String, int>{};
  Object? resumableUploadError;
  Object? resumeUploadError;

  @override
  Future<String> uploadLargeFileResumable(
    String bucket,
    String key,
    String filePath,
    String manifestPath, {
    fula.CancelHandle? cancelHandle,
    void Function(UploadProgress)? onProgress,
  }) async {
    final composite = '$bucket:$key';
    resumableUploadCalls[composite] = (resumableUploadCalls[composite] ?? 0) + 1;
    if (resumableUploadError != null) throw resumableUploadError!;
    if (onProgress != null) {
      onProgress(UploadProgress(bytesUploaded: 0, totalBytes: 0));
    }
    final result = await uploadObject(bucket, key, Uint8List(0));
    return result.etag;
  }

  @override
  Future<String> resumeLargeFileUpload(
    String manifestPath,
    String filePath, {
    fula.CancelHandle? cancelHandle,
    void Function(UploadProgress)? onProgress,
  }) async {
    resumeUploadCalls[manifestPath] =
        (resumeUploadCalls[manifestPath] ?? 0) + 1;
    if (resumeUploadError != null) throw resumeUploadError!;
    if (onProgress != null) {
      onProgress(UploadProgress(bytesUploaded: 0, totalBytes: 0));
    }
    // Fakes don't have a manifest to consult; return a synthetic etag.
    return 'bafkr4ifakeresumed${manifestPath.hashCode.toUnsigned(32).toRadixString(16)}';
  }

  /// The FRB-generated `fula.CancelHandle` is an opaque native type
  /// that can only be constructed via a real `fula.createCancelHandle()`
  /// call (which needs the native lib initialised). Unit tests using
  /// [FakeFulaApi] cannot exercise the cancel path; integration tests
  /// at `integration_test/` cover it instead. These methods throw to
  /// surface accidental cancel-path use in unit tests as an explicit
  /// signal to move the test to integration.
  @override
  Future<fula.CancelHandle> createCancelHandle() async {
    throw UnsupportedError(
      'FakeFulaApi.createCancelHandle: cancel paths must be exercised via '
      'the integration test harness, not unit tests. The FRB opaque '
      'fula.CancelHandle type cannot be constructed without native init.',
    );
  }

  @override
  void triggerCancel(fula.CancelHandle handle) {
    throw UnsupportedError(
      'FakeFulaApi.triggerCancel: see createCancelHandle for details.',
    );
  }

  @override
  Future<bool> isCancelTriggered(fula.CancelHandle handle) async {
    throw UnsupportedError(
      'FakeFulaApi.isCancelTriggered: see createCancelHandle for details.',
    );
  }

  /// Tracks every manifestPath the unit-under-test asked to abort. The
  /// stub itself is a no-op (mirrors the SDK's idempotent missing-
  /// manifest contract from fula-api#20), but recording the calls lets
  /// tests assert that `SyncService.cancelTask` actually invokes the
  /// cleanup path after the cancel handle propagates.
  final List<String> abortedManifestPaths = [];

  @override
  Future<void> abortResumableUpload(String manifestPath) async {
    abortedManifestPaths.add(manifestPath);
  }

  @override
  Future<void> deleteObject(String bucket, String key) async {
    deletedKeys.add('$bucket:$key');
    objectsResponseFor[bucket] =
        (objectsResponseFor[bucket] ?? const <FulaObject>[])
            .where((f) => f.key != key)
            .toList();
  }

  // ---- AI workspace (P14) ----

  /// Gate flag: whether the user has an AI connection. Defaults to FALSE so the
  /// common (non-AI) test path exercises the no-op gate. Set true to simulate
  /// "an AI connection exists" and unlock the workspace list/download stubs.
  bool aiConnectionExists = false;

  /// Per-`(bucket, key)` byte payloads for [downloadWorkspaceObject]. Same key
  /// format as [downloadResponseFor]: `"$bucket:$key"`.
  Map<String, Uint8List> workspaceDownloadResponseFor = <String, Uint8List>{};

  int hasAiConnectionCalls = 0;
  final Map<String, int> listWorkspaceObjectsCalls = <String, int>{};
  final Map<String, int> downloadWorkspaceCalls = <String, int>{};

  @override
  Future<bool> hasAiConnection() async {
    hasAiConnectionCalls++;
    return aiConnectionExists;
  }

  @override
  Future<List<FulaObject>> listWorkspaceObjects(
    String bucket, {
    String prefix = '',
  }) async {
    // Honor the gate EXACTLY like the real FulaApiService: no connection → no
    // read, return empty. (Keeps real/fake gate semantics identical so a test
    // can't pass a path the real code never reaches.)
    if (!aiConnectionExists) return const <FulaObject>[];
    listWorkspaceObjectsCalls[bucket] =
        (listWorkspaceObjectsCalls[bucket] ?? 0) + 1;
    final all = objectsResponseFor[bucket] ?? const <FulaObject>[];
    final filtered =
        prefix.isEmpty ? all : all.where((f) => f.key.startsWith(prefix));
    // Tag with the workspace bucket, mirroring the real implementation.
    return filtered.map((o) => o.withSourceBucket(bucket)).toList();
  }

  @override
  Future<Uint8List> downloadWorkspaceObject(String bucket, String key) async {
    if (!aiConnectionExists) {
      throw FulaApiException('FakeFulaApi: no AI connection');
    }
    final composite = '$bucket:$key';
    downloadWorkspaceCalls[composite] =
        (downloadWorkspaceCalls[composite] ?? 0) + 1;
    final bytes = workspaceDownloadResponseFor[composite];
    if (bytes == null) {
      throw FulaApiException(
        'FakeFulaApi.downloadWorkspaceObject: no stub for "$composite"',
      );
    }
    return bytes;
  }

  // ---- AI-aware download routing (P14.1) ----
  // Mirror the real FulaApiService: route by sourceBucket to the workspace
  // stub vs the normal download stub. `implements FulaApi` does not inherit
  // the interface's default bodies, so these copies are the live ones.

  @override
  Future<Uint8List> downloadBySourceBucket(
          String bucket, String key, String? sourceBucket) =>
      sourceBucket == FulaApi.aiWorkspaceBucket
          ? downloadWorkspaceObject(FulaApi.aiWorkspaceBucket, key)
          : downloadObject(bucket, key);

  @override
  Future<Uint8List> downloadBySourceBucketWithLocalFallback(
          String bucket, String key, String? sourceBucket) =>
      sourceBucket == FulaApi.aiWorkspaceBucket
          ? downloadWorkspaceObject(FulaApi.aiWorkspaceBucket, key)
          : downloadWithLocalFallback(bucket, key);

  // ---- AI-aware WRITE / DELETE (move-as-access-control) ----
  /// Bytes written via [uploadWorkspaceObject], keyed `"$bucket:$key"`.
  final Map<String, Uint8List> workspaceUploadResponseFor = <String, Uint8List>{};
  final Map<String, int> workspaceUploadCalls = <String, int>{};
  final Map<String, int> workspaceDeleteCalls = <String, int>{};

  @override
  Future<void> uploadWorkspaceObject(
    String bucket,
    String key,
    Uint8List bytes, {
    String? contentType,
  }) async {
    if (!aiConnectionExists) {
      throw FulaApiException('FakeFulaApi: no AI connection (upload)');
    }
    final composite = '$bucket:$key';
    workspaceUploadCalls[composite] = (workspaceUploadCalls[composite] ?? 0) + 1;
    workspaceUploadResponseFor[composite] = bytes;
    // Mirror the real forest-tracked put: make it READABLE + ENUMERABLE.
    workspaceDownloadResponseFor[composite] = bytes;
    final list = objectsResponseFor[bucket] ?? const <FulaObject>[];
    if (!list.any((o) => o.key == key)) {
      objectsResponseFor[bucket] = [
        ...list,
        FulaObject(key: key, size: bytes.length),
      ];
    }
  }

  @override
  Future<void> deleteWorkspaceObject(String bucket, String key) async {
    if (!aiConnectionExists) {
      throw FulaApiException('FakeFulaApi: no AI connection (delete)');
    }
    final composite = '$bucket:$key';
    workspaceDeleteCalls[composite] = (workspaceDeleteCalls[composite] ?? 0) + 1;
    // Mirror delete_flat removing the forest entry + the blob: a post-delete
    // list / read no longer surfaces it (the revoke is real).
    workspaceDownloadResponseFor.remove(composite);
    final list = objectsResponseFor[bucket];
    if (list != null) {
      objectsResponseFor[bucket] = [for (final o in list) if (o.key != key) o];
    }
  }
}
