import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/fula_api.dart';
import 'package:fula_files/core/services/fula_api_service.dart' show FulaApiService;

/// P16 — "AI activity": read the shared AI workspace the AI/MCP clients write to.
///
/// COLLECTIVE, NOT per-connection. Every AI connection derives the SAME
/// workspace secret (`blake3('fula:ai-workspace-secret:v1', KEK)` — there is no
/// connection identity in that derivation), so a file in the workspace is
/// "AI-created" but CANNOT be attributed to one specific connection. The UI
/// states this plainly; this layer just lists the bytes.
///
/// Standalone over the [FulaApi] surface (mirrors `category_listing.dart`) so it
/// behaves identically with the real [FulaApiService] and the test fake, and is
/// unit-testable with `FakeFulaApi` — no Riverpod container, no FFI.
///
/// Safety invariants (both load-bearing, both already enforced by
/// [FulaApi.listWorkspaceObjects], restated here so callers can rely on them):
///  - GATED: returns `[]` when there is no AI connection, so non-AI users pay
///    nothing and see nothing. (The real impl short-circuits on
///    [FulaApi.hasAiConnection]; the fake honors the same gate.)
///  - TOLERANT: returns `[]` (never throws) on any AI-side read error
///    (auth/missing/decode), so an activity-screen read can never hard-fail.

/// The prefix under which the AI/MCP writes everything in the workspace bucket
/// (`ai/<category>/<name>`). Listing with this prefix yields the whole workspace.
const String aiActivityPrefix = 'ai/';

/// List the shared AI-workspace contents (every `ai/...` object), newest first.
///
/// Returns the workspace objects (each tagged `sourceBucket='fula-ai-workspace'`
/// by the listing layer) sorted by [FulaObject.lastModified] descending, with
/// unknown-modified items last. Gated + tolerant by contract (see above): an
/// empty list means either "no AI connection" or "connected but nothing stored".
Future<List<FulaObject>> listAiActivity(FulaApi api) async {
  final items = await api.listWorkspaceObjects(
    FulaApiService.aiWorkspaceBucket,
    prefix: aiActivityPrefix,
  );
  // Newest first; items with no modified time sort to the end (stable-ish).
  final sorted = [...items]..sort((a, b) {
      final am = a.lastModified;
      final bm = b.lastModified;
      if (am == null && bm == null) return 0;
      if (am == null) return 1; // a after b
      if (bm == null) return -1; // a before b
      return bm.compareTo(am); // descending
    });
  return sorted;
}
