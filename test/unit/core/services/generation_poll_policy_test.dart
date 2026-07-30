import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/services/generation_poll_policy.dart';

void main() {
  group('classifyPollStatusCode', () {
    test('404 is the only fatal status — the job record is gone', () {
      expect(
        classifyPollStatusCode(404, consecutiveErrors: 1),
        PollFailure.fail,
      );
      // Even at the retry ceiling, nothing else becomes fatal.
      for (final code in [401, 403, 500, 502, 503, 504, 429, 400]) {
        expect(
          classifyPollStatusCode(code, consecutiveErrors: 99),
          isNot(PollFailure.fail),
          reason: 'HTTP $code must never discard a running job',
        );
      }
    });

    test('401/403 pause immediately — session expired, job unaffected', () {
      expect(
        classifyPollStatusCode(401, consecutiveErrors: 0),
        PollFailure.pause,
      );
      expect(
        classifyPollStatusCode(403, consecutiveErrors: 0),
        PollFailure.pause,
      );
    });

    test('5xx retries until the ceiling, then pauses', () {
      expect(
        classifyPollStatusCode(503, consecutiveErrors: 0),
        PollFailure.retry,
      );
      expect(
        classifyPollStatusCode(503, consecutiveErrors: 4),
        PollFailure.retry,
      );
      expect(
        classifyPollStatusCode(503, consecutiveErrors: 5),
        PollFailure.pause,
      );
    });

    test('honours a custom ceiling', () {
      expect(
        classifyPollStatusCode(500,
            consecutiveErrors: 2, maxConsecutiveErrors: 2),
        PollFailure.pause,
      );
    });
  });

  group('classifyPollTransportFailure', () {
    test('retries below the ceiling, pauses at it — never fails', () {
      expect(
        classifyPollTransportFailure(consecutiveErrors: 0),
        PollFailure.retry,
      );
      expect(
        classifyPollTransportFailure(consecutiveErrors: 4),
        PollFailure.retry,
      );
      expect(
        classifyPollTransportFailure(consecutiveErrors: 5),
        PollFailure.pause,
      );
      // A tab that is offline for a long time still must not discard a job.
      expect(
        classifyPollTransportFailure(consecutiveErrors: 1000),
        PollFailure.pause,
      );
    });
  });
}
