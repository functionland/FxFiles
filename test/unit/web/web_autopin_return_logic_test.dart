// PURE (browser-free) logic tests for the web-build Blox auto-pin return.
//
// These exercise ONLY `web_autopin_return_logic.dart` (+ the shared parser in
// `blox_pairing_links.dart`), which import nothing web-specific, so they run
// on the Dart VM under `flutter test`.
//
// Covered:
//  1. detectAutopinReturn — the three URL forms the capture accepts, and the
//     no-op on a normal startup / other routes.
//  2. stripAutopinReturnFromLocation — origin + base-href path kept, return
//     keys dropped from the query (other params kept), fragment reset to `/`
//     only when it carried the return.
//  3. The memory pending holder — stash/take/peek one-shot semantics.
//  4. sessionStorage encode/decode round trip + fail-closed decode
//     (malformed JSON, wrong shapes, invalid payloads).

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/services/blox_pairing_links.dart';
import 'package:fula_files/web/services/web_autopin_return_logic.dart';

void main() {
  const appBase = 'https://files.fx.land/app/';

  setUp(() {
    // Reset the module-level holder between tests.
    takePendingAutopinReturnFromMemory();
  });

  // ===========================================================================
  // 1. detectAutopinReturn
  // ===========================================================================
  group('detectAutopinReturn', () {
    test('hash-route form (what the forwarder\'s "Continue in web app" emits)',
        () {
      final c = detectAutopinReturn(Uri.parse(
          '$appBase#/autopin-complete?secret=s1&hardwareId=hw&bloxPeerId=pid&bloxName=Nm'));
      expect(c, isNotNull);
      expect(c!.params.secret, 's1');
      expect(c.params.hardwareId, 'hw');
      expect(c.params.bloxPeerId, 'pid');
      expect(c.params.bloxName, 'Nm');
      expect(c.strippedUrl, '$appBase#/');
    });

    test('bare fragment form (FxBlox returning straight to /app/)', () {
      final c = detectAutopinReturn(
          Uri.parse('$appBase#secret=s2&hardwareId=hw&bloxPeerId=&bloxName='));
      expect(c, isNotNull);
      expect(c!.params.secret, 's2');
      expect(c.params.bloxPeerId, isNull);
      expect(c.strippedUrl, '$appBase#/');
    });

    test('query form', () {
      final c = detectAutopinReturn(Uri.parse('$appBase?secret=s3&bloxName=N#/'));
      expect(c, isNotNull);
      expect(c!.params.secret, 's3');
      expect(c.strippedUrl, '$appBase#/');
    });

    test('normal startup / other routes → null', () {
      expect(detectAutopinReturn(Uri.parse(appBase)), isNull);
      expect(detectAutopinReturn(Uri.parse('$appBase#/')), isNull);
      expect(detectAutopinReturn(Uri.parse('$appBase#/settings')), isNull);
      expect(detectAutopinReturn(Uri.parse('$appBase?e2e=list#/b/documents')),
          isNull);
      // A `secret` on a DIFFERENT hash route is not an autopin return
      // (e.g. the NFT claim route also carries a `secret`).
      expect(
          detectAutopinReturn(Uri.parse(
              '$appBase#/nft-claim?chain=8453&token=1&secret=claimsecret')),
          isNull);
    });

    test('an OAuth redirect (?code=…) is not mistaken for a return', () {
      expect(detectAutopinReturn(Uri.parse('$appBase?code=abc&state=xyz#/')),
          isNull);
    });
  });

  // ===========================================================================
  // 2. stripAutopinReturnFromLocation
  // ===========================================================================
  group('stripAutopinReturnFromLocation', () {
    test('keeps origin + base-href path, resets the route fragment', () {
      expect(
          stripAutopinReturnFromLocation(
              Uri.parse('$appBase#/autopin-complete?secret=s')),
          '$appBase#/');
      expect(
          stripAutopinReturnFromLocation(
              Uri.parse('https://files.fx.land/#/autopin-complete?secret=s')),
          'https://files.fx.land/#/');
    });

    test('drops only the four return keys from the query, keeps the rest', () {
      final out = stripAutopinReturnFromLocation(Uri.parse(
          '$appBase?e2e=list&secret=s&hardwareId=h&bloxPeerId=p&bloxName=n&seed=w1#/'));
      expect(out, '$appBase?e2e=list&seed=w1#/');
    });

    test('a fragment that is NOT the return is kept verbatim', () {
      expect(
          stripAutopinReturnFromLocation(
              Uri.parse('$appBase?secret=s#/b/documents?open=k')),
          '$appBase#/b/documents?open=k');
    });

    test('trailing-slash hash route is recognised and reset too', () {
      expect(
          stripAutopinReturnFromLocation(
              Uri.parse('$appBase#/autopin-complete/?secret=s')),
          '$appBase#/');
    });

    test('bare secret fragment is replaced by the home route', () {
      expect(
          stripAutopinReturnFromLocation(Uri.parse('$appBase#secret=s&bloxName=n')),
          '$appBase#/');
    });

    test('no fragment at all stays without one', () {
      expect(stripAutopinReturnFromLocation(Uri.parse('$appBase?secret=s')),
          appBase);
    });

    test('never emits a stray "?" for an emptied query', () {
      final out = stripAutopinReturnFromLocation(
          Uri.parse('$appBase?secret=s#/autopin-complete?secret=s'));
      expect(out, isNot(contains('?#')));
      expect(out, '$appBase#/');
    });
  });

  // ===========================================================================
  // 3. Memory pending holder
  // ===========================================================================
  group('pending holder (memory)', () {
    test('take is one-shot and null when empty', () {
      expect(hasPendingAutopinReturnInMemory(), isFalse);
      expect(takePendingAutopinReturnFromMemory(), isNull);
      stashPendingAutopinReturnInMemory(
          const AutopinCompleteParams(secret: 'abc'));
      expect(hasPendingAutopinReturnInMemory(), isTrue);
      expect(takePendingAutopinReturnFromMemory()?.secret, 'abc');
      expect(hasPendingAutopinReturnInMemory(), isFalse);
      expect(takePendingAutopinReturnFromMemory(), isNull);
    });

    test('stashing null is a no-op (does not clear an existing value)', () {
      stashPendingAutopinReturnInMemory(
          const AutopinCompleteParams(secret: 'keep'));
      stashPendingAutopinReturnInMemory(null);
      expect(takePendingAutopinReturnFromMemory()?.secret, 'keep');
    });

    test('a later stash overwrites the earlier one', () {
      stashPendingAutopinReturnInMemory(
          const AutopinCompleteParams(secret: 'first'));
      stashPendingAutopinReturnInMemory(
          const AutopinCompleteParams(secret: 'second'));
      expect(takePendingAutopinReturnFromMemory()?.secret, 'second');
    });
  });

  // ===========================================================================
  // 4. sessionStorage encoding
  // ===========================================================================
  group('session encode/decode', () {
    test('round-trips every field', () {
      const p = AutopinCompleteParams(
        secret: 's',
        hardwareId: 'h',
        bloxPeerId: 'p',
        bloxName: 'Café Blox',
      );
      final back = decodeAutopinReturnFromSession(
          encodeAutopinReturnForSession(p));
      expect(back, isNotNull);
      expect(back!.secret, 's');
      expect(back.hardwareId, 'h');
      expect(back.bloxPeerId, 'p');
      expect(back.bloxName, 'Café Blox');
    });

    test('round-trips with optional fields absent', () {
      const p = AutopinCompleteParams(secret: 'only');
      final back = decodeAutopinReturnFromSession(
          encodeAutopinReturnForSession(p));
      expect(back!.secret, 'only');
      expect(back.hardwareId, isNull);
      expect(back.bloxPeerId, isNull);
      expect(back.bloxName, isNull);
    });

    test('fails closed on missing / malformed / wrong-shape input', () {
      expect(decodeAutopinReturnFromSession(null), isNull);
      expect(decodeAutopinReturnFromSession(''), isNull);
      expect(decodeAutopinReturnFromSession('not json'), isNull);
      expect(decodeAutopinReturnFromSession('[1,2]'), isNull);
      expect(decodeAutopinReturnFromSession('{"secret": 1}'), isNull);
      expect(decodeAutopinReturnFromSession('{"secret": ""}'), isNull);
      expect(decodeAutopinReturnFromSession('{"hardwareId": "h"}'), isNull);
    });

    test('fails closed on a payload that fails validation', () {
      final tooLong = '{"secret": "${'a' * 600}"}';
      expect(decodeAutopinReturnFromSession(tooLong), isNull);
      expect(decodeAutopinReturnFromSession('{"secret": "a\\nb"}'), isNull);
    });

    test('the session key is namespaced', () {
      expect(kAutopinReturnSessionKey, startsWith('fxfiles.'));
    });
  });
}
