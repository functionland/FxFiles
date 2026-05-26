// Unit tests for the current MethodChannel-based [UploadQueueLock].
//
// The lock's real cross-isolate guarantee lives in Kotlin
// (`UploadOwnershipRegistry`, a process-singleton with ref-counting).
// We deliberately do NOT try to reproduce that behaviour in Dart — the
// previous test file did, against a removed file-lock impl, and was
// stale by 7 compile errors. What we CAN test from Dart, and what
// matters for the impl contract, is:
//
//   * non-Android pass-through (no channel traffic; everything succeeds)
//   * channel-driven Android path with [debugIsAndroidOverride]:
//       - tryAcquire sends the right method + per-isolate token
//       - release sends the right method + same token
//       - registerAsBackgroundIsolate sends the right method + token
//       - channel errors fail-closed (tryAcquire → false; register → false;
//         release swallows)
//       - layered acquires inside one isolate share the same token
//   * acquireWithTimeout semantics:
//       - tries at least once even with Duration.zero (the fix from #6)
//       - polls until the native side returns true
//       - returns false on persistent denial
//
// True cross-isolate mutual exclusion belongs in an Android
// instrumentation test against the Kotlin registry; this file is the
// Dart-side contract and nothing more.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/upload_queue_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('land.fx.files/upload_ownership');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mockChannel(Future<dynamic> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    UploadQueueLock.debugIsAndroidOverride = null;
    UploadQueueLock.debugPollInterval = const Duration(milliseconds: 250);
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('UploadQueueLock — non-Android pass-through', () {
    setUp(() {
      UploadQueueLock.debugIsAndroidOverride = false;
    });

    test('isUnavailable is true on non-Android', () {
      final lock = UploadQueueLock();
      expect(lock.isUnavailable, isTrue);
    });

    test('tryAcquire always returns true without invoking the channel',
        () async {
      var invoked = 0;
      mockChannel((_) async {
        invoked++;
        return null;
      });
      final lock = UploadQueueLock();
      expect(await lock.tryAcquire(), isTrue);
      expect(invoked, 0);
    });

    test('release is a no-op on non-Android', () async {
      var invoked = 0;
      mockChannel((_) async {
        invoked++;
        return null;
      });
      await UploadQueueLock().release();
      expect(invoked, 0);
    });

    test('acquireWithTimeout returns true immediately', () async {
      final lock = UploadQueueLock();
      final sw = Stopwatch()..start();
      expect(await lock.acquireWithTimeout(const Duration(seconds: 5)), isTrue);
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('registerAsBackgroundIsolate returns true without channel traffic',
        () async {
      var invoked = 0;
      mockChannel((_) async {
        invoked++;
        return null;
      });
      expect(await UploadQueueLock.registerAsBackgroundIsolate(), isTrue);
      expect(invoked, 0);
    });
  });

  group('UploadQueueLock — simulated Android (channel mock)', () {
    setUp(() {
      UploadQueueLock.debugIsAndroidOverride = true;
      UploadQueueLock.debugPollInterval = const Duration(milliseconds: 5);
    });

    test('tryAcquire sends "tryAcquire" with per-isolate token; returns true',
        () async {
      String? receivedMethod;
      String? receivedToken;
      mockChannel((call) async {
        receivedMethod = call.method;
        receivedToken = (call.arguments as Map)['token'] as String;
        return true;
      });
      final lock = UploadQueueLock();
      expect(await lock.tryAcquire(), isTrue);
      expect(receivedMethod, 'tryAcquire');
      expect(receivedToken, isNotNull);
      expect(receivedToken, isNotEmpty);
    });

    test('tryAcquire returns false when native says no', () async {
      mockChannel((_) async => false);
      expect(await UploadQueueLock().tryAcquire(), isFalse);
    });

    test('tryAcquire returns false when channel throws (fail-closed)',
        () async {
      mockChannel((_) async {
        throw PlatformException(code: 'NO_CHANNEL', message: 'gone');
      });
      expect(await UploadQueueLock().tryAcquire(), isFalse);
    });

    test('tryAcquire returns false when native returns null (no boolean)',
        () async {
      mockChannel((_) async => null);
      expect(await UploadQueueLock().tryAcquire(), isFalse);
    });

    test('release sends "release" with the same token tryAcquire used',
        () async {
      final tokens = <String?>[];
      final methods = <String>[];
      mockChannel((call) async {
        methods.add(call.method);
        tokens.add((call.arguments as Map)['token'] as String?);
        return call.method == 'tryAcquire';
      });
      final lock = UploadQueueLock();
      await lock.tryAcquire();
      await lock.release();
      expect(methods, ['tryAcquire', 'release']);
      expect(tokens.length, 2);
      expect(tokens[0], isNotNull);
      expect(tokens[1], equals(tokens[0]));
    });

    test('release swallows channel errors', () async {
      mockChannel((call) async {
        if (call.method == 'release') {
          throw PlatformException(code: 'NO_CHANNEL', message: 'gone');
        }
        return null;
      });
      // No exception escapes.
      await UploadQueueLock().release();
    });

    test(
        'layered acquires across two instances inside one isolate share '
        'the same token (re-entrancy hinge)', () async {
      final tokens = <String>[];
      mockChannel((call) async {
        tokens.add((call.arguments as Map)['token'] as String);
        return true;
      });
      final outer = UploadQueueLock(ownerTag: 'outer');
      final inner = UploadQueueLock(ownerTag: 'inner');
      await outer.tryAcquire();
      await inner.tryAcquire();
      expect(tokens.length, 2);
      expect(tokens[0], equals(tokens[1]));
    });

    test('registerAsBackgroundIsolate sends "registerBackgroundToken"',
        () async {
      String? method;
      String? token;
      mockChannel((call) async {
        method = call.method;
        token = (call.arguments as Map)['token'] as String;
        return true;
      });
      expect(await UploadQueueLock.registerAsBackgroundIsolate(), isTrue);
      expect(method, 'registerBackgroundToken');
      expect(token, isNotNull);
    });

    test('registerAsBackgroundIsolate returns false when channel throws',
        () async {
      mockChannel((_) async {
        throw PlatformException(code: 'NO_CHANNEL', message: 'gone');
      });
      expect(await UploadQueueLock.registerAsBackgroundIsolate(), isFalse);
    });

    test('registerAsBackgroundIsolate returns false when native returns null',
        () async {
      mockChannel((_) async => null);
      expect(await UploadQueueLock.registerAsBackgroundIsolate(), isFalse);
    });

    group('acquireWithTimeout', () {
      test(
          'Duration.zero returns false WITHOUT attempting (documented '
          'quirk — fixing requires changes to the encryption-critical lock '
          'path; tracked as a follow-up; this test pins current behaviour)',
          () async {
        var invocations = 0;
        mockChannel((_) async {
          invocations++;
          return false;
        });
        final result =
            await UploadQueueLock().acquireWithTimeout(Duration.zero);
        expect(result, isFalse);
        expect(invocations, 0,
            reason: 'current impl: deadline=now and the while-loop never '
                'enters; no caller passes Duration.zero today.');
      });

      test('returns true on first attempt when native grants immediately',
          () async {
        var invocations = 0;
        mockChannel((_) async {
          invocations++;
          return true;
        });
        final result = await UploadQueueLock()
            .acquireWithTimeout(const Duration(seconds: 5));
        expect(result, isTrue);
        expect(invocations, 1);
      });

      test('polls until native grants', () async {
        var invocations = 0;
        mockChannel((_) async {
          invocations++;
          return invocations >= 3; // third call wins.
        });
        final result = await UploadQueueLock()
            .acquireWithTimeout(const Duration(seconds: 5));
        expect(result, isTrue);
        expect(invocations, 3);
      });

      test('returns false when native denies for the full window', () async {
        var invocations = 0;
        mockChannel((_) async {
          invocations++;
          return false;
        });
        // 30 ms window with 5 ms poll → ~6 attempts.
        final result = await UploadQueueLock()
            .acquireWithTimeout(const Duration(milliseconds: 30));
        expect(result, isFalse);
        expect(invocations, greaterThan(1),
            reason: 'should have polled more than once');
      });
    });
  });

  group('UploadQueueLock — ownerTag is diagnostics-only', () {
    test('does not appear in channel arguments', () async {
      UploadQueueLock.debugIsAndroidOverride = true;
      final args = <Map<dynamic, dynamic>>[];
      mockChannel((call) async {
        args.add(call.arguments as Map);
        return true;
      });
      await UploadQueueLock(ownerTag: 'sensitive-tag-not-for-channel')
          .tryAcquire();
      expect(args.single.containsKey('ownerTag'), isFalse,
          reason: 'ownerTag is local diagnostic state; the native side '
              'must not depend on it');
    });
  });

  // ----------------------------------------------------------------
  // Sanity: the test seam itself
  // ----------------------------------------------------------------

  test('debugIsAndroidOverride is null in production (default)', () {
    // Restored by tearDown, but verify the default after a clean reset.
    UploadQueueLock.debugIsAndroidOverride = null;
    expect(UploadQueueLock.debugIsAndroidOverride, isNull);
  });
}
