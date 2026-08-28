// Unit tests for the Blox auto-pin pairing hand-off links
// (`docs/AUTOPIN-HANDOFF.md` v1.1). Pure Dart — runs on the VM.
//
// Covered:
//  1. Outbound URL building (web = FRAGMENT carrier, native = query): base,
//     param set, NO query on the web URL, encoding of the template as ONE
//     value, round-trip decode back to the template, placeholder presence,
//     fail-closed ArgumentErrors.
//  2. The return template constants: fragment form, all four `$placeholders`
//     kept LITERAL (no Dart interpolation), legacy template shape.
//  3. parseAutopinCompleteParams: fragment-first precedence over query, the
//     hash-route form, the legacy query form, empty-optional normalization,
//     malformed encodings failing soft, and no-secret → null.
//  4. AutopinCompleteParams validation: lengths, control chars, map shapes.

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/services/blox_pairing_links.dart';

void main() {
  const token = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1In0.sig+/=';
  const endpoint = 'https://api.cloud.fx.land';

  // ===========================================================================
  // 1. Outbound URL building.
  // ===========================================================================
  group('buildBloxWebPairUrl / buildBloxNativePairUrl', () {
    // The web carrier puts the params in the FRAGMENT (v1.1): what FxBlox-web
    // reads from `location.hash`, decoded the same way the native query is.
    Map<String, String> webParams(Uri uri) => Uri.splitQueryString(uri.fragment);

    test('web URL targets blox.fx.land/autopin-pair with the three params in '
        'the FRAGMENT', () {
      final uri = buildBloxWebPairUrl(token: token, endpoint: endpoint);
      expect(uri.scheme, 'https');
      expect(uri.host, 'blox.fx.land');
      expect(uri.path, '/autopin-pair');
      final params = webParams(uri);
      expect(params.keys.toSet(), <String>{'token', 'endpoint', 'returnUrl'});
      expect(params['token'], token);
      expect(params['endpoint'], endpoint);
      expect(params['returnUrl'], kAutopinReturnTemplate);
    });

    test('web URL carries NO query — nothing for the Pages server / Referer',
        () {
      final uri = buildBloxWebPairUrl(token: token, endpoint: endpoint);
      expect(uri.hasQuery, isFalse);
      expect(uri.query, isEmpty);
      expect(uri.queryParameters, isEmpty);
      final raw = uri.toString();
      expect(raw, isNot(contains('?')));
      expect(raw, startsWith('https://blox.fx.land/autopin-pair#token='));
      // The JWT must not appear before the '#'.
      expect(raw.substring(0, raw.indexOf('#')), isNot(contains(token)));
    });

    test('native URL is fxblox://autopin-pair with the IDENTICAL params as a '
        'query', () {
      final web = buildBloxWebPairUrl(token: token, endpoint: endpoint);
      final native = buildBloxNativePairUrl(token: token, endpoint: endpoint);
      expect(native.scheme, 'fxblox');
      expect(native.host, 'autopin-pair');
      expect(native.hasFragment, isFalse);
      expect(native.query, web.fragment);
      expect(native.queryParameters, webParams(web));
    });

    test('the template is percent-encoded as ONE value (no raw & # \$ = ?)',
        () {
      final uri = buildBloxWebPairUrl(token: token, endpoint: endpoint);
      final raw = uri.toString();
      final returnUrlRaw = raw.substring(raw.indexOf('returnUrl=') + 10);
      expect(returnUrlRaw, isNot(contains('&')));
      expect(returnUrlRaw, isNot(contains('#')));
      expect(returnUrlRaw, isNot(contains('?')));
      expect(returnUrlRaw, isNot(contains(r'$')));
      expect(returnUrlRaw, isNot(contains('=')));
      expect(returnUrlRaw, contains('%24secret'));
      expect(returnUrlRaw, contains('%23secret%3D'));
      // Exactly the string FxBlox `decodeURIComponent`s back to the template.
      expect(Uri.decodeComponent(returnUrlRaw), kAutopinReturnTemplate);
    });

    test('token characters that are special in URLs survive the round trip '
        '(both carriers)', () {
      const nasty = 'a b&c=d#e/f?g+h%i\$j';
      final web = buildBloxWebPairUrl(token: nasty, endpoint: endpoint);
      expect(webParams(web)['token'], nasty);
      final native = buildBloxNativePairUrl(token: nasty, endpoint: endpoint);
      expect(native.queryParameters['token'], nasty);
    });

    test('a custom template is accepted when it has every placeholder', () {
      final uri = buildBloxWebPairUrl(
        token: token,
        endpoint: endpoint,
        returnTemplate: kAutopinLegacyReturnTemplate,
      );
      expect(webParams(uri)['returnUrl'], kAutopinLegacyReturnTemplate);
    });

    test('fails closed on an empty token / endpoint', () {
      expect(() => buildBloxWebPairUrl(token: '', endpoint: endpoint),
          throwsArgumentError);
      expect(() => buildBloxNativePairUrl(token: token, endpoint: ''),
          throwsArgumentError);
    });

    test('fails closed on a template missing a placeholder', () {
      expect(
        () => buildBloxWebPairUrl(
          token: token,
          endpoint: endpoint,
          returnTemplate: r'https://files.fx.land/autopin-complete#secret=$secret',
        ),
        throwsArgumentError,
      );
    });
  });

  // ===========================================================================
  // 2. Template constants.
  // ===========================================================================
  group('return template constants', () {
    test('canonical template is the https fragment form', () {
      expect(
        kAutopinReturnTemplate,
        r'https://files.fx.land/autopin-complete#secret=$secret&hardwareId=$hardwareId&bloxPeerId=$bloxPeerId&bloxName=$bloxName',
      );
      final u = Uri.parse(kAutopinReturnTemplate);
      expect(u.scheme, 'https');
      expect(u.host, kAutopinReturnHost);
      expect(u.path, kAutopinReturnPath);
      expect(u.query, isEmpty, reason: 'the secret must NOT be in the query');
      expect(u.fragment, startsWith(r'secret=$secret'));
    });

    test('all four placeholders are present, literal, and exactly once', () {
      expect(returnTemplateHasAllPlaceholders(kAutopinReturnTemplate), isTrue);
      expect(returnTemplateHasAllPlaceholders(kAutopinLegacyReturnTemplate),
          isTrue);
      for (final p in kAutopinReturnPlaceholders) {
        expect(p, startsWith(r'$'));
        expect(r'$'.allMatches(p).length, 1);
        expect(kAutopinReturnTemplate.split(p).length - 1, 1,
            reason: '$p must appear exactly once');
      }
      expect(kAutopinReturnPlaceholders,
          [r'$secret', r'$hardwareId', r'$bloxPeerId', r'$bloxName']);
    });

    test('legacy template keeps the fxfiles:// query shape', () {
      final u = Uri.parse(kAutopinLegacyReturnTemplate);
      expect(u.scheme, 'fxfiles');
      expect(u.host, 'autopin-complete');
      expect(u.queryParameters['secret'], r'$secret');
    });

    test('returnTemplateHasAllPlaceholders rejects a partial template', () {
      expect(returnTemplateHasAllPlaceholders(r'x#secret=$secret&bloxName=$bloxName'),
          isFalse);
    });
  });

  // ===========================================================================
  // 3. parseAutopinCompleteParams.
  // ===========================================================================
  group('parseAutopinCompleteParams', () {
    test('canonical fragment form (what FxBlox substitutes into v1)', () {
      final p = parseAutopinCompleteParams(Uri.parse(
          'https://files.fx.land/autopin-complete#secret=s3cr3t&hardwareId=hw1&bloxPeerId=12D3KooW&bloxName=My%20Blox'));
      expect(p, isNotNull);
      expect(p!.secret, 's3cr3t');
      expect(p.hardwareId, 'hw1');
      expect(p.bloxPeerId, '12D3KooW');
      expect(p.bloxName, 'My Blox');
    });

    test('web hash-route form (#/autopin-complete?…)', () {
      final p = parseAutopinCompleteParams(Uri.parse(
          'https://files.fx.land/app/#/autopin-complete?secret=abc&hardwareId=hw&bloxPeerId=pid&bloxName=Nm'));
      expect(p, isNotNull);
      expect(p!.secret, 'abc');
      expect(p.hardwareId, 'hw');
      expect(p.bloxPeerId, 'pid');
      expect(p.bloxName, 'Nm');
    });

    test('web hash-route form tolerates a trailing slash', () {
      final p = parseAutopinCompleteParams(Uri.parse(
          'https://files.fx.land/app/#/autopin-complete/?secret=abc&bloxName=Nm'));
      expect(p?.secret, 'abc');
      expect(p?.bloxName, 'Nm');
    });

    test('isAutopinReturnRoutePath accepts both slash forms only', () {
      expect(isAutopinReturnRoutePath('/autopin-complete'), isTrue);
      expect(isAutopinReturnRoutePath('/autopin-complete/'), isTrue);
      expect(isAutopinReturnRoutePath('/settings'), isFalse);
      expect(isAutopinReturnRoutePath('/autopin-completed'), isFalse);
      expect(isAutopinReturnRoutePath('/'), isFalse);
    });

    test('a hash route that is NOT /autopin-complete is ignored', () {
      final p = parseAutopinCompleteParams(
          Uri.parse('https://files.fx.land/app/#/settings?secret=abc'));
      expect(p, isNull);
    });

    test('legacy fxfiles:// query form', () {
      final p = parseAutopinCompleteParams(Uri.parse(
          'fxfiles://autopin-complete?secret=q1&hardwareId=h&bloxPeerId=p&bloxName=n'));
      expect(p, isNotNull);
      expect(p!.secret, 'q1');
      expect(p.bloxName, 'n');
    });

    test('https query form (forwarder fallback)', () {
      final p = parseAutopinCompleteParams(
          Uri.parse('https://files.fx.land/autopin-complete?secret=q2'));
      expect(p?.secret, 'q2');
    });

    test('fragment WINS over query when both carry a secret', () {
      final p = parseAutopinCompleteParams(Uri.parse(
          'https://files.fx.land/autopin-complete?secret=fromQuery&bloxName=Q#secret=fromFragment&bloxName=F'));
      expect(p!.secret, 'fromFragment');
      expect(p.bloxName, 'F');
    });

    test('a fragment WITHOUT a secret falls through to the query', () {
      final p = parseAutopinCompleteParams(Uri.parse(
          'https://files.fx.land/autopin-complete?secret=fromQuery#other=1'));
      expect(p!.secret, 'fromQuery');
    });

    test('empty optional fields normalize to null (FxBlox sends hardwareId=)',
        () {
      final p = parseAutopinCompleteParams(Uri.parse(
          'https://files.fx.land/autopin-complete#secret=s&hardwareId=&bloxPeerId=&bloxName='));
      expect(p!.hardwareId, isNull);
      expect(p.bloxPeerId, isNull);
      expect(p.bloxName, isNull);
    });

    test('percent-encoded values are decoded once', () {
      final p = parseAutopinCompleteParams(Uri.parse(
          'https://files.fx.land/autopin-complete#secret=a%2Bb%3D%26c&bloxName=Caf%C3%A9'));
      expect(p!.secret, 'a+b=&c');
      expect(p.bloxName, 'Café');
    });

    test('no secret anywhere → null', () {
      expect(
          parseAutopinCompleteParams(
              Uri.parse('https://files.fx.land/autopin-complete')),
          isNull);
      expect(
          parseAutopinCompleteParams(Uri.parse(
              'https://files.fx.land/autopin-complete?hardwareId=h#bloxName=n')),
          isNull);
      expect(
          parseAutopinCompleteParams(
              Uri.parse('https://files.fx.land/autopin-complete?secret=')),
          isNull);
    });

    test('a malformed fragment encoding fails soft to the query', () {
      final p = parseAutopinCompleteParams(
          Uri.parse('https://files.fx.land/x?secret=ok#secret=%E0%A4%A'));
      expect(p?.secret, 'ok');
    });
  });

  // ===========================================================================
  // 4. AutopinCompleteParams.
  // ===========================================================================
  group('AutopinCompleteParams', () {
    test('fromMap requires a non-empty secret', () {
      expect(AutopinCompleteParams.fromMap(const {}), isNull);
      expect(AutopinCompleteParams.fromMap(const {'secret': ''}), isNull);
      expect(AutopinCompleteParams.fromMap(const {'secret': 'x'})?.secret, 'x');
    });

    test('a sane payload validates', () {
      const p = AutopinCompleteParams(
        secret: 'd41d8cd98f00b204e9800998ecf8427e',
        hardwareId: 'ABC123',
        bloxPeerId: '12D3KooWQYhTNQdmr3ArTeUHRYzFg94BKyTkoWBDWez9kSCVe2Xo',
        bloxName: 'Living room Blox',
      );
      expect(p.validationError, isNull);
      expect(p.isValid, isTrue);
    });

    test('length caps are enforced per field', () {
      expect(
          AutopinCompleteParams(secret: 'a' * 513).validationError, isNotNull);
      expect(AutopinCompleteParams(secret: 'a' * 512).validationError, isNull);
      expect(
          AutopinCompleteParams(secret: 's', hardwareId: 'h' * 257)
              .validationError,
          isNotNull);
      expect(
          AutopinCompleteParams(secret: 's', bloxPeerId: 'p' * 129)
              .validationError,
          isNotNull);
      expect(
          AutopinCompleteParams(secret: 's', bloxName: 'n' * 129)
              .validationError,
          isNotNull);
    });

    test('control characters are rejected in every field', () {
      expect(const AutopinCompleteParams(secret: 'a\nb').validationError,
          isNotNull);
      expect(
          const AutopinCompleteParams(secret: 's', hardwareId: 'h\x00')
              .validationError,
          isNotNull);
      expect(
          const AutopinCompleteParams(secret: 's', bloxPeerId: 'p\x7f')
              .validationError,
          isNotNull);
      expect(
          const AutopinCompleteParams(secret: 's', bloxName: 'n\tm')
              .validationError,
          isNotNull);
      // Unicode text is fine.
      expect(
          const AutopinCompleteParams(secret: 's', bloxName: 'Büro 🏠')
              .validationError,
          isNull);
    });

    test('toLegacyMap keeps the DeepLinkService shape (nulls preserved)', () {
      const p = AutopinCompleteParams(secret: 's', bloxName: 'n');
      expect(p.toLegacyMap(), {
        'secret': 's',
        'hardwareId': null,
        'bloxPeerId': null,
        'bloxName': 'n',
      });
    });

    test('toQueryParameters omits nulls', () {
      const p = AutopinCompleteParams(secret: 's', hardwareId: 'h');
      expect(p.toQueryParameters(), {'secret': 's', 'hardwareId': 'h'});
    });

    test('toString never leaks the secret', () {
      const p = AutopinCompleteParams(secret: 'super-secret-value');
      expect(p.toString(), isNot(contains('super-secret-value')));
    });
  });
}
