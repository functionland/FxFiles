// Shared failure policy for long-running generation polls (website
// generation and social posts). Pure and VM-testable — the services keep
// only the transport around it.
//
// The rule this encodes is load-bearing: a job the user PAID for is running
// on the server whether or not this browser tab can reach it. So only the
// server's own verdict may terminalize a record. "I couldn't ask" — offline,
// DNS, CORS, a hung socket, an expired session — must leave the job running
// and resumable, or a mobile tab that reopens without a network permanently
// discards a generation that actually succeeded.

/// What a failed status-poll attempt means for the job being polled.
enum PollFailure {
  /// Transient — try again on the next tick.
  retry,

  /// Give up polling in THIS tab, but keep the job running and resumable.
  /// Nothing is written to durable storage.
  pause,

  /// The job is genuinely gone. Terminalize it.
  fail,
}

/// Default number of back-to-back failures before a poll loop gives up.
const int kMaxConsecutivePollErrors = 5;

/// Classify a non-200 response from a status poll.
///
/// Only 404 is fatal — the job record no longer exists, so no amount of
/// retrying will surface a result. 401/403 mean this client can't ask right
/// now (session expired mid-job); the job is unaffected and resumes once the
/// user signs back in. Everything else (5xx, proxy errors) is transient.
PollFailure classifyPollStatusCode(
  int statusCode, {
  required int consecutiveErrors,
  int maxConsecutiveErrors = kMaxConsecutivePollErrors,
}) {
  if (statusCode == 404) return PollFailure.fail;
  if (statusCode == 401 || statusCode == 403) return PollFailure.pause;
  return consecutiveErrors >= maxConsecutiveErrors
      ? PollFailure.pause
      : PollFailure.retry;
}

/// Classify a transport-level failure — no HTTP response at all (offline,
/// DNS failure, CORS rejection, connection timeout). Never fatal: the
/// absence of an answer says nothing about the job.
PollFailure classifyPollTransportFailure({
  required int consecutiveErrors,
  int maxConsecutiveErrors = kMaxConsecutivePollErrors,
}) =>
    consecutiveErrors >= maxConsecutiveErrors
        ? PollFailure.pause
        : PollFailure.retry;
