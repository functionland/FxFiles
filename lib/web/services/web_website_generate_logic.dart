// Pure request/response decisions for POST /api/v1/generate, extracted
// from WebWebsiteService for VM unit tests (repo convention: services
// keep the I/O, logic files keep the decisions).

/// Build the `/api/v1/generate` request body.
///
/// [baseCid] is what turns a submission from "design a new site" into
/// "edit this one": the server resolves it to that build's stored source
/// and revises it in place, so anything [revisionRequest] does not
/// mention comes back untouched. Both fields are OMITTED entirely for a
/// first-time build, so the body a fresh generation sends is unchanged.
Map<String, dynamic> buildGenerateRequestBody({
  required String prompt,
  required List<Map<String, dynamic>> assets,
  required bool enableTracking,
  required bool listed,
  required String listingName,
  required String listingGroup,
  String? baseCid,
  String revisionRequest = '',
}) {
  final isRevision = baseCid != null && baseCid.isNotEmpty;
  return {
    'prompt': prompt,
    'assets': assets,
    'enable_tracking': enableTracking,
    // Capability: opt into the backend's multi-pass pipeline.
    'pipeline_version': 2,
    // Public directory. Sent explicitly — the server column defaults to
    // false, so an older client (or a resumed job) can never publish a
    // user into the directory by omission.
    'listed': listed,
    'listing_name': listingName,
    // Per-WEBSITE key so the directory shows one entry per website
    // instead of one per regeneration.
    'listing_group': listingGroup,
    if (isRevision) 'base_cid': baseCid,
    if (isRevision) 'revision_request': revisionRequest,
  };
}

/// How a `/generate` response should be treated.
enum GenerateOutcome {
  /// 202 — a job was created; poll it.
  accepted,

  /// 200 `mode: unchanged` — the edit asked for nothing, so the site the
  /// user already has IS the answer. No job, nothing charged.
  unchanged,

  /// 409 — the site being edited can't be revised. [generateFailureMessage]
  /// says why.
  baseUnusable,

  /// Anything else — a real failure.
  failed,
}

GenerateOutcome classifyGenerateResponse(
  int statusCode,
  Map<String, dynamic> body,
) {
  if (statusCode == 200) {
    return body['mode'] == 'unchanged'
        ? GenerateOutcome.unchanged
        : GenerateOutcome.failed;
  }
  if (statusCode == 202) return GenerateOutcome.accepted;
  if (statusCode == 409) return GenerateOutcome.baseUnusable;
  return GenerateOutcome.failed;
}

/// User-facing explanation for a 409. Both cases end the same way — build
/// a new website — but a site that predates the feature is not the user
/// doing anything wrong, so it does not read like an error.
String generateFailureMessage(Map<String, dynamic> body) {
  if (body['code'] == 'BASE_SOURCE_UNAVAILABLE') {
    return 'This website was created before editing was supported, so there '
        'is no source to change. Use "Create Website" to build a new one.';
  }
  return 'The website you are editing could not be found. Use "Create '
      'Website" to build a new one.';
}
