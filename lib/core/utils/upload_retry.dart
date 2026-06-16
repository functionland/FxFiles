import 'dart:async';

/// Retry helper for web uploads.
///
/// The fula-client Rust SDK retries transient blob-backend PUT failures 4×
/// with backoff — but that retry loop is compiled OUT on wasm32
/// (`BLOB_BACKEND_MAX_ATTEMPTS` and friends are `#[cfg(not(target_arch =
/// "wasm32"))]`). A large file is chunked into many concurrent <1 MB PUTs
/// (`MAX_CONCURRENT_CHUNK_UPLOADS = 16`); on web a SINGLE sporadic chunk
/// drop (`ERR_CONNECTION_CLOSED` / "error sending request") fails the whole
/// upload with no retry, while small files (1 chunk) almost never hit it.
/// The gateway allows the burst (s3 host: `limit_conn 100`, `600 r/s`, 5 G
/// body), so this is a transient drop, not a rate/size rejection. This util
/// restores the missing retry at the Dart layer for web.

/// Default backoff between attempts. Mirrors the native blob backend's
/// ~300 ms base (chosen so a recycled upstream connection / leaky-bucket
/// recovers before the next try); grows mildly per attempt with a small
/// fixed offset for de-synchronisation (no RNG dependency).
Duration defaultUploadBackoff(int attempt) =>
    Duration(milliseconds: 300 * attempt + 100);

Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

/// Run [action], retrying while [retryIf] returns true for the thrown error,
/// up to [maxAttempts] TOTAL attempts, sleeping [delayFor(attempt)] between
/// tries (attempt is 1-based: the wait AFTER the n-th failed try).
///
/// Rethrows the LAST error once attempts are exhausted, and rethrows
/// IMMEDIATELY when [retryIf] returns false (non-transient — e.g. an auth
/// 4xx). [sleep] is injectable so unit tests run without real delays.
Future<T> retryAsync<T>(
  Future<T> Function() action, {
  required bool Function(Object error) retryIf,
  int maxAttempts = 4,
  Duration Function(int attempt) delayFor = defaultUploadBackoff,
  Future<void> Function(Duration) sleep = _realSleep,
}) async {
  assert(maxAttempts >= 1);
  var attempt = 0;
  while (true) {
    attempt++;
    try {
      return await action();
    } catch (e) {
      if (attempt >= maxAttempts || !retryIf(e)) rethrow;
      await sleep(delayFor(attempt));
    }
  }
}

/// Whether an upload error is a transient network/gateway failure worth
/// retrying on web.
///
/// Retries connection drops, reqwest's "error sending request", generic
/// fetch failures, and 5xx gateway errors. Deliberately does NOT retry:
///   - 4xx client errors (400/401/403/404) — re-trying won't help; and
///   - 409 Conflict — the benign "bucket already exists" PUT that even
///     SUCCESSFUL uploads log; treating it as transient would spin on a
///     non-failure (advisor-flagged against Gemini's draft).
bool isTransientUploadError(Object error) {
  final s = error.toString().toLowerCase();

  // Non-retryable client errors take precedence over any transient match.
  if (s.contains('400') ||
      s.contains('401') ||
      s.contains('403') ||
      s.contains('404') ||
      s.contains('409') ||
      s.contains('unauthorized') ||
      s.contains('forbidden') ||
      s.contains('not found')) {
    return false;
  }

  return s.contains('err_connection_closed') ||
      s.contains('connection closed') ||
      s.contains('connection reset') ||
      s.contains('error sending request') ||
      s.contains('failed to fetch') ||
      s.contains('networkerror') ||
      s.contains('network error') ||
      s.contains('502') ||
      s.contains('503') ||
      s.contains('504') ||
      s.contains('gateway') ||
      s.contains('timed out') ||
      s.contains('timeout');
}
