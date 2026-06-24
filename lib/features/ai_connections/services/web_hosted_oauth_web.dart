// Web (browser) implementation of the same-tab OAuth 2.1 + PKCE hosted-connect
// flow (H5-web). Loaded ONLY on web via the conditional export in
// `web_hosted_oauth.dart`; the native build gets `web_hosted_oauth_io.dart`.
//
// THREE pieces, matching the SPA same-tab-redirect design:
//   START   — startWebHostedOauth: DCR-register with redirect_uri = app root,
//             generate PKCE + state, persist the pending txn to sessionStorage,
//             then window.location.assign(authorizeUrl) (the page unloads).
//   CAPTURE — captureWebOauthRedirect: called as early as possible in main()
//             BEFORE runApp; reads code/state/iss/error from Uri.base (the
//             query precedes the # fragment, so it survives hash routing IF
//             read first), stashes them module-level, then strips the query via
//             history.replaceState so a refresh cannot replay the code.
//   COMPLETE— completeWebHostedOauthIfPending: called from the post-login home
//             init (where the KEK + pinning session exist); validates
//             state/iss/error, exchanges the code for an access token, then runs
//             the UNCHANGED createHostedConnection(...) seam, clears the txn,
//             and navigates to AI Connections with a success/failure SnackBar.
//
// All decisions (redirect-uri derivation, txn shape, validation) live in the
// browser-free `web_hosted_oauth_logic.dart`; this file is the thin browser +
// network shell around them.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'package:fula_files/core/services/wallet_service.dart'
    show walletNavigatorKey;
import 'package:fula_files/features/ai_connections/services/ai_connection_service.dart';
import 'package:fula_files/features/ai_connections/services/hosted_oauth_client.dart';
import 'package:fula_files/features/ai_connections/services/web_hosted_oauth_logic.dart';

// ── CAPTURE module-level holder ──────────────────────────────────────────────
// Set ONCE by captureWebOauthRedirect() at startup; consumed by
// completeWebHostedOauthIfPending(). Cleared on any terminal outcome so a home
// re-mount cannot replay it.
WebOauthCallbackParams? _captured;

/// In-flight guard: COMPLETE is fired from the home init, which can run more
/// than once (initState + a session transition). The captured holder is the
/// primary one-shot, but completion is async, so this prevents two overlapping
/// completions from both reading the holder before the first clears it.
bool _completing = false;

/// START — begin the web same-tab OAuth flow against [workerUrl].
///
/// Does ALL fallible work (DCR register, PKCE/state generation, the
/// sessionStorage write) BEFORE navigating, so if anything throws the page
/// stays put and the provider's catch can surface an error (the page only
/// unloads on the final `location.assign`, which does not return).
Future<void> startWebHostedOauth({
  required String workerUrl,
  required String label,
}) async {
  final base = normalizeWorkerBase(workerUrl);
  final issuerOrigin = Uri.parse(base).origin;

  // The redirect_uri = the SPA app root, derived from the live URL. The
  // IDENTICAL string is registered, sent at /authorize, stored, and reused at
  // /token.
  final redirectUri = deriveWebRedirectUri(Uri.base);

  // ── Dynamic Client Registration (RFC 7591) with the https redirect_uri ──────
  final clientId = await _registerWebClient(base: base, redirectUri: redirectUri);

  // ── PKCE + state for THIS transaction ───────────────────────────────────────
  final codeVerifier = generateCodeVerifier();
  // REUSE the native client's exact, RFC-7636-pinned S256 derivation (a
  // divergent copy could reintroduce the verifier-string-vs-entropy bug). It is
  // @visibleForTesting on HostedOauthClient; this production reuse is
  // deliberate, so the native file stays byte-for-byte unchanged.
  // ignore: invalid_use_of_visible_for_testing_member
  final codeChallenge = HostedOauthClient.deriveS256Challenge(codeVerifier);
  final state = randomUrlSafe(32);

  final txn = WebOauthPendingTxn(
    verifier: codeVerifier,
    state: state,
    clientId: clientId,
    workerUrl: base,
    label: label,
    issuerOrigin: issuerOrigin,
    redirectUri: redirectUri,
    createdAt: DateTime.now().toUtc().toIso8601String(),
  );

  // Persist the pending txn (sync write — flushed before navigation).
  web.window.sessionStorage
      .setItem(WebOauthPendingTxn.sessionStorageKey, txn.encode());

  final authorizeUrl = buildWebAuthorizeUrl(
    workerUrl: base,
    clientId: clientId,
    redirectUri: redirectUri,
    scope: HostedOauthClient.scope,
    state: state,
    codeChallenge: codeChallenge,
  );

  // Navigate the SAME tab. This does not return — the page unloads.
  web.window.location.assign(authorizeUrl.toString());
}

/// CAPTURE — read the OAuth redirect params from the current URL and strip the
/// query so a refresh cannot replay the code. Safe to call unconditionally at
/// startup; a no-op when the URL is not an OAuth redirect.
void captureWebOauthRedirect() {
  final params = WebOauthCallbackParams.fromUri(Uri.base);
  if (!params.isOauthRedirect) return;
  _captured = params;
  try {
    // Strip ONLY the query; keep the path + hash route intact.
    final stripped = stripQueryPreservingFragment(Uri.base);
    web.window.history.replaceState(null, '', stripped);
  } catch (e) {
    // A failed strip is not fatal — the code is already captured in memory and
    // is single-use server-side; just log it.
    debugPrint('captureWebOauthRedirect: replaceState failed: $e');
  }
}

/// COMPLETE — if a code was captured AND a pending txn exists, finish the
/// hosted connect: validate, exchange the code, build the connection, then
/// navigate + SnackBar. Idempotent: clears BOTH the module holder and the
/// sessionStorage txn on every terminal outcome (success or failure), so a home
/// re-mount never re-runs it.
Future<WebOauthCompleteOutcome> completeWebHostedOauthIfPending() async {
  if (_completing) return WebOauthCompleteOutcome.none;
  final captured = _captured;
  if (captured == null || captured.code == null || captured.code!.isEmpty) {
    return WebOauthCompleteOutcome.none;
  }
  _completing = true;
  try {
    final raw = web.window.sessionStorage
        .getItem(WebOauthPendingTxn.sessionStorageKey);
    final txn = WebOauthPendingTxn.tryDecode(raw);
    if (txn == null) {
      // A captured code with no (or a corrupt) pending txn: we cannot safely
      // complete (no verifier / no issuer binding). Clear the holder so it does
      // not linger, but do NOT surface an error — this is the
      // signed-out-then-refreshed corner, not a user action to report.
      _captured = null;
      _clearPendingTxn();
      return WebOauthCompleteOutcome.none;
    }

    // From here on this IS a user-initiated completion: clear the one-shot
    // state up-front so neither a success nor a thrown failure can replay it.
    _captured = null;
    _clearPendingTxn();

    final validation = validateWebOauthCallback(params: captured, txn: txn);
    if (!validation.isValid) {
      _showSnack(validation.failureReason ?? 'Hosted AI sign-in failed.');
      return WebOauthCompleteOutcome.failure;
    }
    final req = validation.exchange!;

    try {
      final accessToken = await _exchangeWebCode(req);

      // Run the UNCHANGED createHostedConnection seam: fresh keypair, derive
      // workspace secret, mint connection token, build + POST capability,
      // persist the non-secret record. A fresh keypair per connect is correct.
      await AiConnectionService.instance.createHostedConnection(
        label: req.label,
        workerUrl: req.workerUrl,
        fetchWorkerToken: (_) async => accessToken,
      );

      _navigateToAiConnections();
      _showSnack('Connected ${req.label}.');
      return WebOauthCompleteOutcome.success;
    } catch (e) {
      _navigateToAiConnections();
      _showSnack(_friendlyError(e));
      return WebOauthCompleteOutcome.failure;
    }
  } finally {
    _completing = false;
  }
}

// ── DCR (web): register a PUBLIC client with the https redirect_uri ──────────
//
// Same RFC 7591 body as the native HostedOauthClient._registerClient, but the
// redirect_uri is the https app root (not the custom scheme). VERIFIED: the
// deployed Worker accepts an https redirect_uri via DCR (HTTP 201). Fail-closed
// on a non-2xx response or a missing client_id.
Future<String> _registerWebClient({
  required String base,
  required String redirectUri,
}) async {
  final client = http.Client();
  try {
    final response = await client
        .post(
          Uri.parse('$base/register'),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, dynamic>{
            'client_name': HostedOauthClient.clientName,
            'redirect_uris': <String>[redirectUri],
            'token_endpoint_auth_method': 'none', // public client (no secret)
            'grant_types': <String>['authorization_code'],
            'response_types': <String>['code'],
            'scope': HostedOauthClient.scope,
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
    client.close();
  }
}

// ── Token exchange (web) ─────────────────────────────────────────────────────
//
// POST {worker}/token (authorization_code grant) with the stored redirect_uri +
// code_verifier. Re-checks the token-response `iss` against the issuer origin —
// the SECOND issuer check, exactly like the native _exchangeCode (the first is
// the callback-`iss` check in validateWebOauthCallback). Fail-closed on non-2xx
// / a missing access_token / an issuer mismatch.
Future<String> _exchangeWebCode(WebOauthExchangeRequest req) async {
  final client = http.Client();
  try {
    final response = await client
        .post(
          Uri.parse(req.tokenUrl),
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': 'application/json',
          },
          body: {
            'grant_type': 'authorization_code',
            'code': req.code,
            'redirect_uri': req.redirectUri,
            'client_id': req.clientId,
            'code_verifier': req.codeVerifier,
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
    // SECOND issuer check: if the AS echoes its issuer it must match the Worker.
    final iss = decoded['iss'];
    if (iss is String &&
        iss.isNotEmpty &&
        Uri.parse(iss).origin != req.issuerOrigin) {
      throw StateError('OAuth issuer mismatch in the token response.');
    }
    final token = decoded['access_token'];
    if (token is! String || token.isEmpty) {
      throw Exception('Token response missing "access_token".');
    }
    return token;
  } finally {
    client.close();
  }
}

void _clearPendingTxn() {
  try {
    web.window.sessionStorage.removeItem(WebOauthPendingTxn.sessionStorageKey);
  } catch (e) {
    debugPrint('completeWebHostedOauth: clear txn failed: $e');
  }
}

/// Navigate the root navigator to the AI Connections screen. Best-effort: if
/// the navigator context is not ready the SnackBar still informs the user.
void _navigateToAiConnections() {
  final ctx = walletNavigatorKey.currentContext;
  if (ctx == null) return;
  try {
    ctx.go('/ai-connections');
  } catch (e) {
    debugPrint('completeWebHostedOauth: navigate failed: $e');
  }
}

/// Show a SnackBar via the root navigator's ScaffoldMessenger, scheduled after
/// the current frame (COMPLETE runs from initState/post-login init).
void _showSnack(String message) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final ctx = walletNavigatorKey.currentContext;
    if (ctx == null) return;
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  });
}

/// Turn an exception into a user-safe message (the createHostedConnection /
/// exchange errors already carry readable text).
String _friendlyError(Object e) {
  final s = e.toString();
  return s.startsWith('Exception: ') ? s.substring('Exception: '.length) : s;
}
