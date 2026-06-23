import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// H5 — the OAuth 2.1 + PKCE client that authenticates FxFiles to a user-run
/// hosted **Worker** (the Cloudflare Worker is the OAuth Authorization Server;
/// it brokers Google upstream).
///
/// PRODUCTION PATH (deferred to H4 for live verification): FxFiles is a PUBLIC
/// client (no client secret). It first REGISTERS via Dynamic Client Registration
/// (`POST {workerUrl}/register`, RFC 7591 — the Worker REQUIRES a registered
/// client_id; verified against `cloudflare/src/index.ts` +
/// `workers-oauth-provider`), then opens `{workerUrl}/authorize` in the system
/// browser via `url_launcher` and receives the redirect back through the
/// already-registered `fxfiles://auth-callback` custom scheme via `app_links`
/// (the SAME external-browser + deep-link pattern `DeepLinkService.openGetApiKeyPage`
/// uses). It exchanges the code at `{workerUrl}/token` for a Worker access token.
///
/// SECURITY (advisor-reviewed: built-in advisor + Codex GPT-5.5):
///  - PKCE S256: `code_challenge = BASE64URL(SHA256(ASCII(code_verifier)))` — the
///    hash is over the verifier STRING's bytes (RFC 7636), NOT the raw entropy.
///    A custom-scheme interceptor that grabs the `code` cannot redeem it without
///    the verifier (which never leaves the device).
///  - `state`: a random nonce bound to THIS transaction; the callback is rejected
///    unless it carries the exact state we sent (CSRF / unsolicited-callback).
///  - Mix-up / issuer binding: because the user types an arbitrary Worker URL, the
///    pending transaction is bound to the normalized Worker origin; the code is
///    redeemed ONLY against that Worker's `/token`, and if the token response (or
///    an RFC 9207 `iss` on the callback) names an issuer it MUST equal the Worker
///    origin. `state`/`code_verifier` are dropped after completion.
///  - This class returns ONLY the Worker access token. It never persists anything;
///    the caller (AiConnectionService.createHostedConnection) decides what to do.
///
/// This is the REAL seam injected as `fetchWorkerToken` into
/// `AiConnectionService.createHostedConnection`. Unit tests do NOT use this class
/// (no browser/network under `flutter test`); they inject a fake that returns a
/// canned token. The live handshake is verifiable only against a deployed Worker
/// (H4).
class HostedOauthClient {
  HostedOauthClient({
    http.Client? httpClient,
    AppLinks? appLinks,
    Future<bool> Function(Uri url)? launch,
  })  : _httpClient = httpClient,
        _appLinks = appLinks ?? AppLinks(),
        _launch = launch ?? _defaultLaunch;

  final http.Client? _httpClient;
  final AppLinks _appLinks;
  final Future<bool> Function(Uri url) _launch;

  /// The custom-scheme redirect FxFiles is registered to receive (Android
  /// intent-filter / iOS Info.plist / Windows registry — see DeepLinkService).
  static const String redirectUri = 'fxfiles://auth-callback';

  /// Human-readable client name sent at Dynamic Client Registration.
  static const String clientName = 'FxFiles';

  /// The single scope this Worker's AS grants (and `/capability` requires, H2).
  static const String scope = 'mcp';

  static final Random _random = Random.secure();

  static Future<bool> _defaultLaunch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  /// Run the full OAuth 2.1 + PKCE authorization-code flow against [workerUrl]
  /// and return the Worker access token.
  ///
  /// [timeout] bounds the whole interactive flow (browser → callback). Throws on
  /// cancellation/timeout, a `state` mismatch, an issuer mismatch, or a non-2xx
  /// token exchange — fail-closed so a botched handshake never yields a token.
  Future<String> authenticate(
    String workerUrl, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final base = _normalizeBase(workerUrl);
    final issuerOrigin = Uri.parse(base).origin;

    // ── Dynamic Client Registration (RFC 7591) ───────────────────────────────
    // The Worker (workers-oauth-provider) REQUIRES a registered client_id — a
    // hardcoded id is rejected at /authorize ("Invalid client …"). FxFiles is a
    // mobile public client with no hosted client-metadata document (so CIMD is
    // not viable); it registers dynamically as a PUBLIC client
    // (token_endpoint_auth_method=none → NO client secret) and uses the returned
    // client_id for this flow.
    final clientId = await _registerClient(base);

    // ── PKCE + state for THIS transaction ────────────────────────────────────
    final codeVerifier = _generateCodeVerifier();
    final codeChallenge = deriveS256Challenge(codeVerifier);
    final state = _randomUrlSafe(32);

    final authorizeUrl = Uri.parse('$base/authorize').replace(
      queryParameters: <String, String>{
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'scope': scope,
        'state': state,
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
      },
    );

    // Begin listening BEFORE launching the browser so a fast callback can't race
    // ahead of the subscription.
    final callbackFuture = _awaitCallback(state: state, timeout: timeout);

    final launched = await _launch(authorizeUrl);
    if (!launched) {
      throw StateError('Could not open the hosted AI sign-in page.');
    }

    final callback = await callbackFuture;

    // RFC 9207 issuer check (if the AS includes `iss` on the redirect): it MUST
    // match the Worker origin the user is connecting to (mix-up defense).
    final iss = callback.queryParameters['iss'];
    if (iss != null && iss.isNotEmpty && Uri.parse(iss).origin != issuerOrigin) {
      throw StateError('OAuth issuer mismatch on the sign-in callback.');
    }

    final error = callback.queryParameters['error'];
    if (error != null && error.isNotEmpty) {
      throw StateError('Hosted AI sign-in was denied: $error');
    }
    final code = callback.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw StateError('Hosted AI sign-in returned no authorization code.');
    }

    // ── Exchange the code at the SAME Worker's /token (issuer-bound) ──────────
    return _exchangeCode(
      tokenUrl: Uri.parse('$base/token'),
      issuerOrigin: issuerOrigin,
      clientId: clientId,
      code: code,
      codeVerifier: codeVerifier,
    );
  }

  /// Register FxFiles as an OAuth client via Dynamic Client Registration
  /// (RFC 7591, `POST {workerUrl}/register`) and return the issued `client_id`.
  ///
  /// FxFiles registers as a PUBLIC client (`token_endpoint_auth_method: none`),
  /// so the Worker issues NO client secret — PKCE secures the code exchange. The
  /// only required field is `redirect_uris`; a custom-scheme redirect
  /// (`fxfiles://auth-callback`) is accepted by the Worker's scheme validation.
  ///
  /// Throws on a non-2xx response or a missing `client_id` (fail-closed).
  Future<String> _registerClient(String base) async {
    final client = _httpClient ?? http.Client();
    try {
      final response = await client
          .post(
            Uri.parse('$base/register'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{
              'client_name': clientName,
              'redirect_uris': <String>[redirectUri],
              'token_endpoint_auth_method': 'none', // public client (no secret)
              'grant_types': <String>['authorization_code'],
              'response_types': <String>['code'],
              'scope': scope,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'Client registration failed: ${response.statusCode} - ${response.body}',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('Malformed client registration response.');
      }
      final clientId = decoded['client_id'];
      if (clientId is! String || clientId.isEmpty) {
        throw Exception('Client registration response missing "client_id".');
      }
      return clientId;
    } finally {
      if (_httpClient == null) client.close();
    }
  }

  /// Listen for the `fxfiles://auth-callback` redirect carrying the matching
  /// [state]. Ignores unrelated deep links (other features share this scheme).
  Future<Uri> _awaitCallback({
    required String state,
    required Duration timeout,
  }) {
    final completer = Completer<Uri>();
    late final StreamSubscription<Uri> sub;
    sub = _appLinks.uriLinkStream.listen(
      (uri) {
        if (uri.scheme != 'fxfiles' || uri.host != 'auth-callback') return;
        // Only accept the callback whose state matches THIS transaction.
        if (uri.queryParameters['state'] != state) return;
        if (!completer.isCompleted) completer.complete(uri);
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );
    return completer.future
        .timeout(timeout, onTimeout: () {
          throw TimeoutException('Hosted AI sign-in timed out.');
        })
        .whenComplete(sub.cancel);
  }

  Future<String> _exchangeCode({
    required Uri tokenUrl,
    required String issuerOrigin,
    required String clientId,
    required String code,
    required String codeVerifier,
  }) async {
    final client = _httpClient ?? http.Client();
    try {
      final response = await client
          .post(
            tokenUrl,
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded',
              'Accept': 'application/json',
            },
            body: {
              'grant_type': 'authorization_code',
              'code': code,
              'redirect_uri': redirectUri,
              'client_id': clientId,
              'code_verifier': codeVerifier,
            },
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'Token exchange failed: ${response.statusCode} - ${response.body}',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('Malformed token response.');
      }
      // If the AS echoes its issuer, it must match the Worker we asked.
      final iss = decoded['iss'];
      if (iss is String && iss.isNotEmpty && Uri.parse(iss).origin != issuerOrigin) {
        throw StateError('OAuth issuer mismatch in the token response.');
      }
      final token = decoded['access_token'];
      if (token is! String || token.isEmpty) {
        throw Exception('Token response missing "access_token".');
      }
      return token;
    } finally {
      if (_httpClient == null) client.close();
    }
  }

  // ── PKCE primitives (RFC 7636) ─────────────────────────────────────────────

  /// A 43-char `code_verifier`: base64url-unpadded of 32 random bytes (the
  /// minimum-length, high-entropy verifier RFC 7636 §4.1 recommends).
  static String _generateCodeVerifier() => _randomUrlSafe(32);

  /// `code_challenge = BASE64URL-no-pad(SHA256(ASCII(code_verifier)))`.
  ///
  /// CRITICAL (Codex): the digest is over the bytes of the verifier STRING, not
  /// the original entropy — `ascii.encode(verifier)`, then SHA-256, then
  /// base64url without padding. Exposed for a test against the RFC 7636 §B vector.
  @visibleForTesting
  static String deriveS256Challenge(String codeVerifier) {
    final digest = sha256.convert(ascii.encode(codeVerifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  /// `n` random bytes as an unpadded base64url string (URL-safe, RFC 7636
  /// `[A-Za-z0-9-_]` charset, no `=`).
  static String _randomUrlSafe(int n) {
    final bytes = Uint8List(n);
    for (var i = 0; i < n; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _normalizeBase(String workerUrl) {
    var s = workerUrl.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}
