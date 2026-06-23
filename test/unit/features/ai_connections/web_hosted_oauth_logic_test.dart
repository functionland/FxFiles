// H5-web — PURE (browser-free) logic tests for the web same-tab OAuth flow.
//
// These exercise ONLY `web_hosted_oauth_logic.dart`, which imports nothing
// web-specific, so they run on the Dart VM under `flutter test` (the
// conditional export compiles the IO stub here, never the package:web impl).
//
// Covered:
//  1. WebOauthPendingTxn JSON round-trip + fail-closed tryDecode.
//  2. validateWebOauthCallback — the full hardening ladder: state CSRF, error,
//     iss mix-up (callback), missing code, and the success shape.
//  3. deriveWebRedirectUri — origin+path, query+fragment stripped, identical
//     under base-href.
//  4. stripQueryPreservingFragment — drops ?query, keeps the # route.
//  5. PKCE verifier/challenge wiring (challenge derived via the shared
//     HostedOauthClient.deriveS256Challenge; verifier shape).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/features/ai_connections/services/hosted_oauth_client.dart';
import 'package:fula_files/features/ai_connections/services/web_hosted_oauth_logic.dart';

void main() {
  // A canonical valid pending transaction reused across tests.
  WebOauthPendingTxn txn({
    String state = 'state-abc',
    String issuerOrigin = 'https://mcp.cloud.fx.land',
    String workerUrl = 'https://mcp.cloud.fx.land',
    String redirectUri = 'https://app.fx.land/',
    String verifier = 'verifier-xyz-123',
    String clientId = 'client-123',
    String label = 'Claude.ai',
  }) =>
      WebOauthPendingTxn(
        verifier: verifier,
        state: state,
        clientId: clientId,
        workerUrl: workerUrl,
        label: label,
        issuerOrigin: issuerOrigin,
        redirectUri: redirectUri,
        createdAt: '2026-06-23T00:00:00.000Z',
      );

  // ===========================================================================
  // 1. WebOauthPendingTxn — JSON round-trip + fail-closed decode.
  // ===========================================================================
  group('WebOauthPendingTxn JSON', () {
    test('round-trips every field through encode/tryDecode', () {
      final original = txn();
      final restored = WebOauthPendingTxn.tryDecode(original.encode());
      expect(restored, isNotNull);
      expect(restored!.verifier, original.verifier);
      expect(restored.state, original.state);
      expect(restored.clientId, original.clientId);
      expect(restored.workerUrl, original.workerUrl);
      expect(restored.label, original.label);
      expect(restored.issuerOrigin, original.issuerOrigin);
      expect(restored.redirectUri, original.redirectUri);
      expect(restored.createdAt, original.createdAt);
    });

    test('the stored key is stable (sessionStorage contract)', () {
      expect(WebOauthPendingTxn.sessionStorageKey,
          'fxfiles.hostedOauth.pending');
    });

    test('tryDecode returns null for null / empty / non-JSON / non-object', () {
      expect(WebOauthPendingTxn.tryDecode(null), isNull);
      expect(WebOauthPendingTxn.tryDecode(''), isNull);
      expect(WebOauthPendingTxn.tryDecode('not json {{{'), isNull);
      expect(WebOauthPendingTxn.tryDecode('"a string"'), isNull);
      expect(WebOauthPendingTxn.tryDecode('[1,2,3]'), isNull);
    });

    test('tryDecode is fail-closed when ANY required field is missing/empty',
        () {
      final full = jsonDecode(txn().encode()) as Map<String, dynamic>;
      // Drop each required key in turn → null.
      for (final key in full.keys.where((k) => k != 'label')) {
        final copy = Map<String, dynamic>.from(full)..remove(key);
        expect(WebOauthPendingTxn.tryDecode(jsonEncode(copy)), isNull,
            reason: 'missing "$key" must fail-closed');
      }
      // Empty (vs absent) of a security-critical field also fails.
      for (final key in const [
        'verifier',
        'state',
        'clientId',
        'workerUrl',
        'issuerOrigin',
        'redirectUri',
      ]) {
        final copy = Map<String, dynamic>.from(full)..[key] = '';
        expect(WebOauthPendingTxn.tryDecode(jsonEncode(copy)), isNull,
            reason: 'empty "$key" must fail-closed');
      }
    });

    test('an empty label is allowed (it is not security-critical)', () {
      final full = jsonDecode(txn().encode()) as Map<String, dynamic>
        ..['label'] = '';
      final decoded = WebOauthPendingTxn.tryDecode(jsonEncode(full));
      expect(decoded, isNotNull);
      expect(decoded!.label, '');
    });
  });

  // ===========================================================================
  // 2. validateWebOauthCallback — the full fail-closed hardening ladder.
  // ===========================================================================
  group('validateWebOauthCallback', () {
    test('SUCCESS: matching state, no error, no/au-matching iss, code present',
        () {
      final res = validateWebOauthCallback(
        params: const WebOauthCallbackParams(
          code: 'authcode-1',
          state: 'state-abc',
        ),
        txn: txn(),
      );
      expect(res.isValid, isTrue);
      final ex = res.exchange!;
      expect(ex.code, 'authcode-1');
      expect(ex.codeVerifier, 'verifier-xyz-123');
      expect(ex.clientId, 'client-123');
      expect(ex.redirectUri, 'https://app.fx.land/');
      expect(ex.tokenUrl, 'https://mcp.cloud.fx.land/token');
      expect(ex.issuerOrigin, 'https://mcp.cloud.fx.land');
      expect(ex.workerUrl, 'https://mcp.cloud.fx.land');
      expect(ex.label, 'Claude.ai');
    });

    test('SUCCESS: a matching RFC 9207 iss is accepted', () {
      final res = validateWebOauthCallback(
        params: const WebOauthCallbackParams(
          code: 'c',
          state: 'state-abc',
          iss: 'https://mcp.cloud.fx.land',
        ),
        txn: txn(),
      );
      expect(res.isValid, isTrue);
    });

    test('REJECT: missing state (CSRF)', () {
      final res = validateWebOauthCallback(
        params: const WebOauthCallbackParams(code: 'c'),
        txn: txn(),
      );
      expect(res.isValid, isFalse);
      expect(res.failureReason, contains('state'));
    });

    test('REJECT: wrong state (CSRF / unsolicited callback)', () {
      final res = validateWebOauthCallback(
        params: const WebOauthCallbackParams(code: 'c', state: 'WRONG'),
        txn: txn(),
      );
      expect(res.isValid, isFalse);
      expect(res.failureReason, contains('state'));
    });

    test('REJECT: an error param fails even with a matching state', () {
      final res = validateWebOauthCallback(
        params: const WebOauthCallbackParams(
          state: 'state-abc',
          error: 'access_denied',
        ),
        txn: txn(),
      );
      expect(res.isValid, isFalse);
      expect(res.failureReason, contains('access_denied'));
    });

    test('REJECT: iss mix-up — a different issuer origin is refused', () {
      final res = validateWebOauthCallback(
        params: const WebOauthCallbackParams(
          code: 'c',
          state: 'state-abc',
          iss: 'https://evil.example.com',
        ),
        txn: txn(),
      );
      expect(res.isValid, isFalse);
      expect(res.failureReason, contains('issuer'));
    });

    test('REJECT: iss present but unparseable/empty-origin is refused', () {
      final res = validateWebOauthCallback(
        params: const WebOauthCallbackParams(
          code: 'c',
          state: 'state-abc',
          iss: 'not a url',
        ),
        txn: txn(),
      );
      expect(res.isValid, isFalse);
      expect(res.failureReason, contains('issuer'));
    });

    test('REJECT: no code (after state + error + iss pass)', () {
      final res = validateWebOauthCallback(
        params: const WebOauthCallbackParams(state: 'state-abc'),
        txn: txn(),
      );
      expect(res.isValid, isFalse);
      expect(res.failureReason, contains('authorization code'));
    });

    test('order: state is checked before error (a wrong state on an error '
        'callback still reports state)', () {
      final res = validateWebOauthCallback(
        params: const WebOauthCallbackParams(
          state: 'WRONG',
          error: 'access_denied',
        ),
        txn: txn(),
      );
      expect(res.isValid, isFalse);
      expect(res.failureReason, contains('state'));
    });
  });

  // ===========================================================================
  // 3. deriveWebRedirectUri — origin + path, query + fragment stripped.
  // ===========================================================================
  group('deriveWebRedirectUri', () {
    test('strips a ?query and a #hash route, keeps origin + root path', () {
      expect(
        deriveWebRedirectUri(
          Uri.parse('https://app.fx.land/?code=abc&state=s#/ai-connections'),
        ),
        'https://app.fx.land/',
      );
    });

    test('preserves a base-href path (served under a subpath)', () {
      expect(
        deriveWebRedirectUri(
          Uri.parse('https://functionland.github.io/FxFiles/?code=x#/home'),
        ),
        'https://functionland.github.io/FxFiles/',
      );
    });

    test('is identical whether or not a query/fragment is present '
        '(register == authorize == token)', () {
      final clean = Uri.parse('https://app.fx.land/app/');
      final dirty =
          Uri.parse('https://app.fx.land/app/?code=c&state=s#/x/y?z=1');
      expect(deriveWebRedirectUri(clean), deriveWebRedirectUri(dirty));
    });
  });

  // ===========================================================================
  // 4. stripQueryPreservingFragment — drop ?query, keep the #route.
  // ===========================================================================
  group('stripQueryPreservingFragment', () {
    test('removes the OAuth query but keeps the hash route', () {
      expect(
        stripQueryPreservingFragment(
          Uri.parse('https://app.fx.land/?code=abc&state=s#/ai-connections'),
        ),
        'https://app.fx.land/#/ai-connections',
      );
    });

    test('with no fragment, just drops the query', () {
      expect(
        stripQueryPreservingFragment(
          Uri.parse('https://app.fx.land/?code=abc'),
        ),
        'https://app.fx.land/',
      );
    });

    test('with no query, is a stable no-op on the route', () {
      expect(
        stripQueryPreservingFragment(
          Uri.parse('https://app.fx.land/#/home'),
        ),
        'https://app.fx.land/#/home',
      );
    });
  });

  // ===========================================================================
  // 5. PKCE wiring — verifier shape + challenge via the SHARED native helper.
  // ===========================================================================
  group('PKCE primitives', () {
    test('generateCodeVerifier is a 43-char unpadded base64url string', () {
      final v = generateCodeVerifier();
      expect(v.length, 43); // base64url of 32 bytes, no padding
      expect(v.contains('='), isFalse);
      expect(v.contains('+'), isFalse);
      expect(v.contains('/'), isFalse);
    });

    test('two verifiers differ (entropy sanity)', () {
      expect(generateCodeVerifier(), isNot(generateCodeVerifier()));
    });

    test('the S256 challenge equals the shared HostedOauthClient derivation '
        '(RFC 7636 §B vector)', () {
      // Same vector the native client test pins — the web flow MUST reuse this
      // exact derivation, not a divergent copy.
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      const expected = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
      expect(HostedOauthClient.deriveS256Challenge(verifier), expected);
    });

    test('buildWebAuthorizeUrl carries the standard PKCE/OAuth query shape',
        () {
      final url = buildWebAuthorizeUrl(
        workerUrl: 'https://mcp.cloud.fx.land',
        clientId: 'client-1',
        redirectUri: 'https://app.fx.land/',
        scope: 'mcp',
        state: 'state-1',
        codeChallenge: 'challenge-1',
      );
      expect(url.path, '/authorize');
      final q = url.queryParameters;
      expect(q['response_type'], 'code');
      expect(q['client_id'], 'client-1');
      expect(q['redirect_uri'], 'https://app.fx.land/');
      expect(q['scope'], 'mcp');
      expect(q['state'], 'state-1');
      expect(q['code_challenge'], 'challenge-1');
      expect(q['code_challenge_method'], 'S256');
    });
  });

  // ===========================================================================
  // 6. normalizeWorkerBase — trailing-slash trim (matches the native helper).
  // ===========================================================================
  group('normalizeWorkerBase', () {
    test('trims trailing slashes and surrounding whitespace', () {
      expect(normalizeWorkerBase('  https://mcp.cloud.fx.land/  '),
          'https://mcp.cloud.fx.land');
      expect(normalizeWorkerBase('https://mcp.cloud.fx.land///'),
          'https://mcp.cloud.fx.land');
      expect(normalizeWorkerBase('https://mcp.cloud.fx.land'),
          'https://mcp.cloud.fx.land');
    });
  });
}
