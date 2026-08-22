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

    test('consecutive failures escalate 30s -> 2m -> 10m -> 1h and cap', () {
      b.recordFailure('archives');
      expect(b.remaining('archives'), const Duration(seconds: 30));

      clock.advance(const Duration(seconds: 31));
      b.recordFailure('archives');
      expect(b.remaining('archives'), const Duration(minutes: 2));

      clock.advance(const Duration(minutes: 3));
      b.recordFailure('archives');
      expect(b.remaining('archives'), const Duration(minutes: 10));

      clock.advance(const Duration(minutes: 11));
      b.recordFailure('archives');
      expect(b.remaining('archives'), const Duration(hours: 1));

      // Capped: a fifth (and any later) failure stays at the last step.
      clock.advance(const Duration(hours: 2));
      b.recordFailure('archives');
      expect(b.remaining('archives'), const Duration(hours: 1));
      expect(b.failureCount('archives'), 5);
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

  /// The stall is paid on the FIRST read of a session, so in-memory-only
  /// state meant every page load re-paid ~30s of tab-wide blockage
  /// (measured: capture 3, 2026-08-22).
  group('persistence across page loads', () {
    test('export/import survives a reload and still skips', () {
      b.recordFailure('tag-metadata');
      final saved = b.exportState();

      // New session, same wall clock.
      final b2 = BucketHealthBreaker()..clock = clock.call;
      b2.importState(saved);
      expect(b2.shouldSkip('tag-metadata'), isTrue,
          reason: 'a reload must not re-pay the 30s stall');
      expect(b2.failureCount('tag-metadata'), 1);
    });

    test('a restored entry keeps escalating instead of restarting at 30s', () {
      b.recordFailure('tag-metadata');
      clock.advance(const Duration(seconds: 31));
      final b2 = BucketHealthBreaker()..clock = clock.call;
      b2.importState(b.exportState());
      // Window elapsed, so one attempt is allowed...
      expect(b2.shouldSkip('tag-metadata'), isFalse);
      // ...and it escalates from where the previous session left off.
      b2.recordFailure('tag-metadata');
      expect(b2.remaining('tag-metadata'), const Duration(minutes: 2));
    });

    test('long-expired entries are dropped so a recovered bucket is retried',
        () {
      b.recordFailure('tag-metadata');
      final saved = b.exportState();
      clock.advance(const Duration(hours: 9)); // well past keepExpiredFor
      final b2 = BucketHealthBreaker()..clock = clock.call;
      b2.importState(saved);
      expect(b2.failureCount('tag-metadata'), 0);
      expect(b2.shouldSkip('tag-metadata'), isFalse);
    });

    test('importState does NOT fire onChanged (no write-back at boot)', () {
      b.recordFailure('tag-metadata');
      final saved = b.exportState();
      var fired = 0;
      final b2 = BucketHealthBreaker()
        ..clock = clock.call
        ..onChanged = () => fired++;
      b2.importState(saved);
      expect(fired, 0);
    });

    test('reset fires onChanged even when empty, so storage is cleared', () {
      var fired = 0;
      b.onChanged = () => fired++;
      b.reset();
      expect(fired, 1,
          reason: 'a persisted cooldown must not outlive sign-out');
    });

    test('recordFailure and recordSuccess both notify', () {
      var fired = 0;
      b.onChanged = () => fired++;
      b.recordFailure('tag-metadata');
      expect(fired, 1);
      b.recordSuccess('tag-metadata');
      expect(fired, 2);
      // A no-op success must not churn storage.
      b.recordSuccess('tag-metadata');
      expect(fired, 2);
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
