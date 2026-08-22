import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/services/bucket_health_breaker.dart';

/// Controllable clock so cooldown expiry is tested without real waiting.
class _Clock {
  DateTime now = DateTime.utc(2026, 8, 22, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  late BucketHealthBreaker b;
  late _Clock clock;

  setUp(() {
    clock = _Clock();
    b = BucketHealthBreaker()..clock = clock.call;
    BucketHealthBreaker.enabled = true;
  });

  tearDown(() => BucketHealthBreaker.enabled = false);

  group('BucketHealthBreaker', () {
    test('a healthy bucket is never skipped', () {
      expect(b.shouldSkip('tag-metadata'), isFalse);
      expect(b.failureCount('tag-metadata'), 0);
      expect(b.remaining('tag-metadata'), isNull);
    });

    test('one failure opens the first cooldown step', () {
      b.recordFailure('tag-metadata');
      expect(b.shouldSkip('tag-metadata'), isTrue);
      expect(b.remaining('tag-metadata'), const Duration(seconds: 30));
      // Other buckets are unaffected — the breaker is per-bucket.
      expect(b.shouldSkip('tag-metadata-v8'), isFalse);
    });

    test('cooldown expires and lets exactly one attempt through', () {
      b.recordFailure('archives');
      clock.advance(const Duration(seconds: 29));
      expect(b.shouldSkip('archives'), isTrue);
      clock.advance(const Duration(seconds: 2));
      expect(b.shouldSkip('archives'), isFalse);
    });

    test('consecutive failures escalate 30s -> 2min -> 5min and cap', () {
      b.recordFailure('archives');
      expect(b.remaining('archives'), const Duration(seconds: 30));

      clock.advance(const Duration(seconds: 31));
      b.recordFailure('archives');
      expect(b.remaining('archives'), const Duration(minutes: 2));

      clock.advance(const Duration(minutes: 3));
      b.recordFailure('archives');
      expect(b.remaining('archives'), const Duration(minutes: 5));

      // Capped: a fourth (and any later) failure stays at the last step.
      clock.advance(const Duration(minutes: 6));
      b.recordFailure('archives');
      expect(b.remaining('archives'), const Duration(minutes: 5));
      expect(b.failureCount('archives'), 4);
    });

    test('an expired window keeps the failure count so it keeps escalating',
        () {
      b.recordFailure('archives');
      clock.advance(const Duration(seconds: 31));
      // Window elapsed: the attempt is allowed...
      expect(b.shouldSkip('archives'), isFalse);
      // ...but the history is NOT forgotten, so the next failure escalates
      // instead of restarting at 30s forever.
      expect(b.failureCount('archives'), 1);
      b.recordFailure('archives');
      expect(b.remaining('archives'), const Duration(minutes: 2));
    });

    test('success clears the state and restarts the ladder', () {
      b.recordFailure('tag-metadata');
      b.recordFailure('tag-metadata');
      expect(b.failureCount('tag-metadata'), 2);

      b.recordSuccess('tag-metadata');
      expect(b.failureCount('tag-metadata'), 0);
      expect(b.shouldSkip('tag-metadata'), isFalse);

      b.recordFailure('tag-metadata');
      expect(b.remaining('tag-metadata'), const Duration(seconds: 30));
    });

    test('reset drops every bucket (sign-out / user switch)', () {
      b.recordFailure('tag-metadata');
      b.recordFailure('archives');
      b.reset();
      expect(b.shouldSkip('tag-metadata'), isFalse);
      expect(b.shouldSkip('archives'), isFalse);
      expect(b.failureCount('archives'), 0);
    });

    test('disabled is a hard no-op: native behaviour is byte-identical', () {
      BucketHealthBreaker.enabled = false;
      b.recordFailure('tag-metadata');
      expect(b.shouldSkip('tag-metadata'), isFalse,
          reason: 'the flag gates skipping entirely, so native never skips');
    });
  });

  group('isBreakerWorthyFailure', () {
    test('trips on the real gc-damaged-bucket error from production', () {
      // Verbatim from the reported console log.
      expect(
        isBreakerWorthyFailure(
            'AnyhowException(S3 error (InternalError): Core error: block '
            'store error: operation timed out after 30s)'),
        isTrue,
      );
    });

    test('trips on the Dart-side timeout', () {
      expect(
        isBreakerWorthyFailure(
            'TimeoutException after 0:00:30.000000: Future not completed'),
        isTrue,
      );
    });

    test('does NOT trip on structural absence — a new bucket stays usable',
        () {
      expect(isBreakerWorthyFailure('NoSuchKey'), isFalse);
      expect(isBreakerWorthyFailure('NoSuchBucket'), isFalse);
      expect(
        isBreakerWorthyFailure('FulaApiException: Failed to download object: '
            'AnyhowException(Object not found: website-metadata/.fula/'
            'website_jobs/d51d222b3baf65fb.json)'),
        isFalse,
      );
    });

    test('absence wins even when the message also carries a timeout word',
        () {
      // Order matters: absence is checked first so a mixed message can
      // never cool down a bucket that is merely empty.
      expect(
        isBreakerWorthyFailure('NoSuchKey (operation timed out)'),
        isFalse,
      );
    });

    test('does NOT trip on unrelated/generic errors', () {
      expect(isBreakerWorthyFailure('FormatException: bad json'), isFalse);
      expect(isBreakerWorthyFailure('some 500 in a CID Qm500abc'), isFalse,
          reason: 'a bare number must never be treated as a server error');
    });
  });

  group('BucketCooldownException', () {
    test('names the bucket and reads as unavailable, not absent', () {
      const e = BucketCooldownException('tag-metadata', Duration(seconds: 12));
      final s = e.toString();
      expect(s, contains('tag-metadata'));
      expect(s, contains('12'));
      // Load-bearing: WebListingSwr._isConfirmedAbsence must not classify
      // this as an absence, or a cooldown would be frozen as "does not
      // exist" forever on the legacy half.
      expect(s.contains('NoSuchKey'), isFalse);
      expect(s.contains('Object not found:'), isFalse);
    });
  });
}
