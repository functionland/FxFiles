import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/utils/upload_retry.dart';

void main() {
  group('isTransientUploadError', () {
    test('retries the observed web failure + connection/5xx errors', () {
      // The actual error from the report:
      expect(
        isTransientUploadError(
            'FulaApiException: Failed to upload large file: '
            'AnyhowException(HTTP error: error sending request)'),
        isTrue,
      );
      expect(isTransientUploadError('net::ERR_CONNECTION_CLOSED'), isTrue);
      expect(isTransientUploadError('connection reset by peer'), isTrue);
      expect(isTransientUploadError('Failed to fetch'), isTrue);
      expect(isTransientUploadError('503 Service Unavailable'), isTrue);
      expect(isTransientUploadError('502 Bad Gateway'), isTrue);
      expect(isTransientUploadError('request timed out'), isTrue);
    });

    test('does NOT retry 4xx or the benign 409 bucket-exists conflict', () {
      // 409 is logged even by SUCCESSFUL uploads (bucket already exists);
      // retrying it would spin on a non-failure (advisor-flagged).
      expect(isTransientUploadError('HTTP 409 Conflict'), isFalse);
      expect(isTransientUploadError('401 Unauthorized'), isFalse);
      expect(isTransientUploadError('403 Forbidden'), isFalse);
      expect(isTransientUploadError('404 Not Found'), isFalse);
      expect(isTransientUploadError('400 Bad Request'), isFalse);
    });

    test('a 409 that also looks network-y is still NOT retried (4xx wins)', () {
      expect(
        isTransientUploadError('409 Conflict: error sending request'),
        isFalse,
      );
    });
  });

  group('retryAsync', () {
    test('returns immediately on success — no retry, no sleep', () async {
      var calls = 0;
      final sleeps = <Duration>[];
      final r = await retryAsync(
        () async {
          calls++;
          return 'ok';
        },
        retryIf: (_) => true,
        sleep: (d) async => sleeps.add(d),
      );
      expect(r, 'ok');
      expect(calls, 1);
      expect(sleeps, isEmpty);
    });

    test('retries a transient failure then succeeds', () async {
      var calls = 0;
      final sleeps = <Duration>[];
      final r = await retryAsync(
        () async {
          calls++;
          if (calls < 3) throw 'error sending request';
          return 'ok';
        },
        retryIf: isTransientUploadError,
        delayFor: (a) => Duration(milliseconds: a),
        sleep: (d) async => sleeps.add(d),
      );
      expect(r, 'ok');
      expect(calls, 3); // failed twice, succeeded on the 3rd
      expect(sleeps.length, 2); // one sleep after each failed attempt
    });

    test('exhausts maxAttempts and rethrows the LAST error', () async {
      var calls = 0;
      final sleeps = <Duration>[];
      await expectLater(
        retryAsync(
          () async {
            calls++;
            throw 'error sending request #$calls';
          },
          retryIf: isTransientUploadError,
          maxAttempts: 4,
          sleep: (d) async => sleeps.add(d),
        ),
        throwsA('error sending request #4'),
      );
      expect(calls, 4); // all attempts used
      expect(sleeps.length, 3); // sleeps BETWEEN attempts only
    });

    test('non-transient error rethrows immediately — no retry, no sleep',
        () async {
      var calls = 0;
      final sleeps = <Duration>[];
      await expectLater(
        retryAsync(
          () async {
            calls++;
            throw '409 Conflict';
          },
          retryIf: isTransientUploadError,
          sleep: (d) async => sleeps.add(d),
        ),
        throwsA('409 Conflict'),
      );
      expect(calls, 1);
      expect(sleeps, isEmpty);
    });

    test('default backoff grows per attempt', () {
      expect(defaultUploadBackoff(1), const Duration(milliseconds: 400));
      expect(defaultUploadBackoff(2), const Duration(milliseconds: 700));
      expect(defaultUploadBackoff(3), const Duration(milliseconds: 1000));
    });
  });
}
