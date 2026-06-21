// Abstract surface for FulaApiService so tests can swap in a fake.
//
// This is the minimal interface needed by the screens / services
// covered in the current test scenarios. See test/README.md for the
// broader plan and which scenarios are covered vs. skeleton.
//
// The concrete `FulaApiService` (in `fula_api_service.dart`)
// implements this. Tests inject `FakeFulaApi` (`test/helpers/
// fake_fula_api.dart`) via the Riverpod provider in
// `lib/core/providers/fula_api_provider.dart`.
//
// **Why a separate file?** The fula_client package surface is a set
// of top-level functions (e.g. `fula.encListBuckets(client: ...)`).
// Dart can't mock top-level functions, so we introduce an instance-
// method seam here and mock at THIS layer. Tests don't reach down
// into fula_client; they live entirely at the FulaApi boundary.

import 'dart:typed_data';

import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/fula_api_types.dart';

// Re-export so callers of `FulaApi` can pick up the shared types
// without a second import. Production code that already imports
// `fula_api_service.dart` gets the same types through that file.
export 'package:fula_files/core/services/fula_api_types.dart';

/// Public-facing surface of the cloud client.
///
/// **Subset.** This deliberately does NOT mirror every method on
/// `FulaApiService` — only the surface that's currently covered by
/// automated tests. As coverage expands, additional methods can be
/// added here and to the concrete class together.
///
/// **Lifecycle.** Implementations are long-lived (typically a
/// singleton). `isConfigured` returns `false` until `initialize` is
/// called (production) or until a fake's constructor wires it
/// (tests).
abstract class FulaApi {
  /// Whether the client is ready to serve requests. Production
  /// callers should check this and defer reads until true; tests
  /// can override the fake to be `false` to exercise error paths.
  bool get isConfigured;

  /// Optional default bucket name set at `initialize` time, used by
  /// FxFiles to scope per-feature uploads when no explicit bucket is
  /// passed.
  String? get defaultBucket;

  /// List bucket names the user has access to.
  ///
  /// Throws `FulaApiException` on any failure. Callers that want
  /// offline behavior should use [listBucketsCached] instead.
  Future<List<String>> listBuckets();

  /// Same as [listBuckets] but with retry + on-disk cache fallback.
  ///
  /// Returns `(buckets, stale, fetchedAt)` so the UI can surface
  /// staleness when the cached value is being served (master
  /// unreachable). `stale=true` ⇔ result came from cache, not from
  /// a live master call this session.
  ///
  /// Throws only when both the live attempt and the cache lookup
  /// fail.
  Future<({List<String> buckets, bool stale, DateTime? fetchedAt})>
      listBucketsCached();

  /// List objects in a bucket via the encrypted forest index.
  ///
  /// `prefix` is a Dart-side filter applied after the forest read;
  /// passing an empty string returns every file in the bucket. The
  /// forest read happens once and is in-memory cached by the SDK
  /// for the lifetime of the EncryptedClient.
  Future<List<FulaObject>> listObjects(
    String bucket, {
    String prefix = '',
    bool recursive = false,
  });

  /// Timeout-bounded, cache-backed variant of [listObjects].
  ///
  /// Used by browser screens so an in-flight upload that holds the
  /// SDK's outer write lock (and any IPNS chain-RPC outage along the
  /// forest-load path) cannot pin the UI in "loading" indefinitely.
  /// `stale=true` ⇔ result came from the on-disk cache, not from a
  /// live master call this session.
  ///
  /// Throws only when both the live attempt (retried once) and the
  /// cache lookup fail.
  Future<({List<FulaObject> objects, bool stale, DateTime? fetchedAt})>
      listObjectsCached(
    String bucket, {
    String prefix = '',
    Duration timeout = const Duration(seconds: 10),
  });

  /// Download an object's bytes.
  ///
  /// When [contentCid] is supplied, the SDK can short-circuit via
  /// the cid-hint warm path (issue #8 fix #3) — important for
  /// freshly-uploaded files served offline. When `null`, the SDK
  /// looks up the CID from its warm-cache `(bucket, key) → cid`
  /// table, falling through to master only when the cache misses.
  ///
  /// Throws `FulaApiException` on failure.
  Future<Uint8List> downloadObject(
    String bucket,
    String key, {
    String? contentCid,
  });

  /// LAN-first variant — tries the local Blox endpoint first when
  /// configured, falls back to the cloud client. The two endpoints
  /// share the same encryption material so either side decrypts
  /// correctly.
  Future<Uint8List> downloadWithLocalFallback(String bucket, String key);

  /// Canonical name of the AI/MCP workspace bucket. Declared here (the
  /// shared surface) so the routing helpers below — and the test fake,
  /// which does NOT import `fula_api_service.dart` — can reference it.
  /// `FulaApiService.aiWorkspaceBucket` aliases this so existing call
  /// sites keep working with a single source of truth.
  static const String aiWorkspaceBucket = 'fula-ai-workspace';

  /// Route a download to the right client by the object's [sourceBucket].
  ///
  /// AI-workspace files (`sourceBucket == aiWorkspaceBucket`) decrypt only
  /// via the workspace client, so they MUST go through
  /// [downloadWorkspaceObject] (which fetches from [aiWorkspaceBucket]
  /// regardless of [bucket]); everything else is the user's own content and
  /// routes to [downloadObject].
  ///
  /// **`implements`, not `extends`:** this concrete body is NOT inherited by
  /// `FulaApiService` / `FakeFulaApi` (both `implements FulaApi`); each
  /// provides its own copy. It lives here only to document the contract.
  Future<Uint8List> downloadBySourceBucket(
          String bucket, String key, String? sourceBucket) =>
      sourceBucket == aiWorkspaceBucket
          ? downloadWorkspaceObject(bucket, key)
          : downloadObject(bucket, key);

  /// LAN-first sibling of [downloadBySourceBucket]. The AI branch skips the
  /// LAN fallback by design — the AI workspace is cloud-only, so there is no
  /// local blox copy to race against.
  Future<Uint8List> downloadBySourceBucketWithLocalFallback(
          String bucket, String key, String? sourceBucket) =>
      sourceBucket == aiWorkspaceBucket
          ? downloadWorkspaceObject(bucket, key)
          : downloadWithLocalFallback(bucket, key);

  /// Upload a small file (single block, <=768 KB).
  ///
  /// Returns `(etag, contentCid)`. `contentCid` is non-null when the
  /// master is v0.4.4+ (returns BLAKE3 raw-codec etag) and walkable-
  /// v8 self-verify accepts it; null when the master is legacy or
  /// the etag doesn't parse as a CID.
  Future<UploadResult> uploadObject(
    String bucket,
    String key,
    Uint8List data, {
    String? contentType,
    Map<String, String>? metadata,
  });

  /// Upload a large file via the chunked path (multi-chunk + index
  /// object). Maps to `fula.putFlat` on the SDK side, which
  /// auto-dispatches at the 768 KB threshold.
  Future<String> uploadLargeFile(
    String bucket,
    String key,
    Uint8List data, {
    int chunkSize,
    void Function(UploadProgress)? onProgress,
    Map<String, String>? metadata,
  });

  /// Streaming upload from a file path (avoids loading the entire
  /// file into Dart memory). Same chunked path as [uploadLargeFile]
  /// but the file is read on the Rust side.
  Future<String> uploadLargeFileFromPath(
    String bucket,
    String key,
    String filePath, {
    void Function(UploadProgress)? onProgress,
  });

  /// Resumable variant — writes a chunked-upload manifest at
  /// [manifestPath]. On failure the manifest stays on disk; call
  /// [resumeLargeFileUpload] to pick up where this attempt left off.
  /// Optional [cancelHandle] (created via [createCancelHandle]) lets
  /// callers abort cooperatively.
  ///
  /// Wraps `put_flat_resumable_from_path_cancellable` from
  /// fula-api#17 + #18.
  Future<String> uploadLargeFileResumable(
    String bucket,
    String key,
    String filePath,
    String manifestPath, {
    fula.CancelHandle? cancelHandle,
    void Function(UploadProgress)? onProgress,
  });

  /// Resume a previously-failed resumable upload from its manifest.
  /// [filePath] MUST point at bytes identical to the original upload
  /// (the SDK's BAO check enforces this).
  ///
  /// Wraps `resume_flat_upload_from_path_cancellable`.
  Future<String> resumeLargeFileUpload(
    String manifestPath,
    String filePath, {
    fula.CancelHandle? cancelHandle,
    void Function(UploadProgress)? onProgress,
  });

  /// Create a fresh cancel handle for use with the resumable upload
  /// methods. Implementations wrap fula-api#18's `CancelHandle` opaque
  /// type.
  ///
  /// Async because the FRB-generated `fula.createCancelHandle()`
  /// returns `Future<CancelHandle>` — the call dispatches into the
  /// native lib via the Rust bridge.
  Future<fula.CancelHandle> createCancelHandle();

  /// Trigger cancellation on a previously-created handle. Idempotent.
  /// Fire-and-forget — the underlying FRB call is async but the
  /// cancel-flag flip semantics don't need the caller to await it; the
  /// in-flight upload polls the flag at chunk boundaries and short-
  /// circuits as soon as it observes the new value.
  void triggerCancel(fula.CancelHandle handle);

  /// Check whether a handle has been triggered.
  ///
  /// Async for the same reason as [createCancelHandle] — the
  /// FRB-generated call returns `Future<bool>`.
  Future<bool> isCancelTriggered(fula.CancelHandle handle);

  /// Discard a resumable upload's local state and best-effort delete its
  /// already-uploaded chunks on the storage backend (fula-api#20).
  ///
  /// Use when the user decides to give up on a cancelled or failed
  /// upload rather than resume it later. Idempotent — calling on a
  /// manifest that doesn't exist (already aborted, or SDK auto-deleted
  /// it on a prior clean completion) succeeds as a no-op.
  ///
  /// **Not a graceful stop.** This is POST-cancel cleanup. For
  /// mid-flight abort use [triggerCancel] on a [createCancelHandle]
  /// passed to [uploadLargeFileResumable] / [resumeLargeFileUpload].
  ///
  /// Wraps `abort_resumable_upload`.
  Future<void> abortResumableUpload(String manifestPath);

  /// Delete an object from the master + the user's forest.
  Future<void> deleteObject(String bucket, String key);

  // ── AI workspace (P14) ─────────────────────────────────────────────────────
  // Surface the AI/MCP's own encrypted `fula-ai-workspace` forest in native
  // category views + adopt its tags. All three are GATED behind
  // [hasAiConnection] so they are a no-op for non-AI users.

  /// True if the user has at least one AI-connection record (P13). The gate for
  /// every workspace read: when false, [listWorkspaceObjects] /
  /// [downloadWorkspaceObject] do nothing, so non-AI users pay zero cost.
  Future<bool> hasAiConnection();

  /// List objects from the AI-workspace forest under [prefix] (e.g.
  /// `ai/images/`), each tagged `sourceBucket = 'fula-ai-workspace'`. Returns
  /// `[]` (never throws) when there is no AI connection or the workspace can't
  /// be read, so it can never hide the user's own content in a merged view.
  Future<List<FulaObject>> listWorkspaceObjects(
    String bucket, {
    String prefix,
  });

  /// Download + decrypt a single object from the AI-workspace forest (e.g. the
  /// AI tag doc `ai/tag-metadata/ai-workspace.json`). Throws on a genuine read
  /// error; the tag-adoption caller catches it so a failure never blocks restore.
  Future<Uint8List> downloadWorkspaceObject(String bucket, String key);

  // share/collab APIs deliberately not in this interface yet — those
  // scenarios are skeleton-only in this round. Adding them later is
  // an additive change to this surface + the concrete service +
  // FakeFulaApi.
}
