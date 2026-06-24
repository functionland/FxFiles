import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// H5-web — PURE (browser-free) logic for the web same-tab OAuth 2.1 + PKCE
/// hosted-connect flow.
///
/// This file deliberately imports NOTHING web-specific (no `package:web`,
/// `dart:js_interop`, `dart:html`). Every value the browser layer needs is
/// computed here from plain inputs, so this is the ONLY layer the unit tests
/// touch — `flutter test` runs on the Dart VM (which compiles the IO/stub
/// branch of the conditional import, never the web impl), so any logic that
/// must be tested has to live here.
///
/// The web entry-point (`web_hosted_oauth.dart` → `..._web.dart`) is the thin
/// shell that reads/writes `window.sessionStorage`, navigates the tab, and
/// performs the network `register`/`token` calls; it delegates ALL decisions
/// (redirect-uri derivation, the pending-transaction shape, and the
/// state/iss/error validation) to the functions here.
///
/// SECURITY (mirrors `HostedOauthClient`, the native path — do NOT weaken):
///  - PKCE S256: a 43-char high-entropy `code_verifier`; the challenge is
///    `BASE64URL(SHA256(ASCII(verifier)))` (computed via the SHARED
///    `HostedOauthClient.deriveS256Challenge`, which is RFC-7636-pinned).
///  - `state`: a random nonce bound to THIS transaction; the callback is
///    rejected unless it carries the exact `state` we stored.
///  - Mix-up / issuer binding: the pending transaction is bound to the
///    normalized Worker origin (`issuerOrigin`); an RFC 9207 `iss` on the
///    callback MUST equal it (the web exchange ALSO re-checks `iss` on the
///    token response, exactly like the native `_exchangeCode`).
///  - Fail-closed: any `error`, a `state` mismatch, an `iss` mismatch, a
///    missing `code`, or a non-2xx token exchange yields no access token.

/// The pending OAuth transaction persisted to `window.sessionStorage` between
/// the START navigation and the post-redirect COMPLETE step.
///
/// Stored under [sessionStorageKey] as JSON. It carries NO long-lived secret
/// beyond the single-use PKCE [verifier] (which is exactly what PKCE requires
/// to survive the redirect); it is cleared on any terminal outcome.
class WebOauthPendingTxn {
  const WebOauthPendingTxn({
    required this.verifier,
    required this.state,
    required this.clientId,
    required this.workerUrl,
    required this.label,
    required this.issuerOrigin,
    required this.redirectUri,
    required this.createdAt,
  });

  /// PKCE `code_verifier` (single-use; redeemed once at `/token`).
  final String verifier;

  /// CSRF nonce bound to this transaction; the callback `state` must match it.
  final String state;

  /// The DCR-issued `client_id` used at `/authorize` and `/token`.
  final String clientId;

  /// The normalized Worker base URL (e.g. `https://mcp.cloud.fx.land`).
  final String workerUrl;

  /// The user-entered connection label (e.g. `Claude.ai`).
  final String label;

  /// The Worker's issuer origin — the mix-up-defense anchor: a callback/token
  /// `iss` MUST equal this.
  final String issuerOrigin;

  /// The EXACT `redirect_uri` registered + sent at `/authorize`; reused
  /// verbatim at `/token` (an OAuth 2.1 requirement — it must be identical).
  final String redirectUri;

  /// Wall-clock creation time (ISO-8601) — for optional staleness display.
  final String createdAt;

  /// The `window.sessionStorage` key the pending transaction lives under.
  static const String sessionStorageKey = 'fxfiles.hostedOauth.pending';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'verifier': verifier,
        'state': state,
        'clientId': clientId,
        'workerUrl': workerUrl,
        'label': label,
        'issuerOrigin': issuerOrigin,
        'redirectUri': redirectUri,
        'createdAt': createdAt,
      };

  String encode() => jsonEncode(toJson());

  /// Parse a pending transaction from its stored JSON string.
  ///
  /// Returns null if [raw] is null/empty, not a JSON object, or missing any
  /// required field (fail-closed: a malformed txn yields no completion).
  static WebOauthPendingTxn? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final verifier = decoded['verifier'];
    final state = decoded['state'];
    final clientId = decoded['clientId'];
    final workerUrl = decoded['workerUrl'];
    final label = decoded['label'];
    final issuerOrigin = decoded['issuerOrigin'];
    final redirectUri = decoded['redirectUri'];
    final createdAt = decoded['createdAt'];
    if (verifier is! String ||
        verifier.isEmpty ||
        state is! String ||
        state.isEmpty ||
        clientId is! String ||
        clientId.isEmpty ||
        workerUrl is! String ||
        workerUrl.isEmpty ||
        label is! String ||
        issuerOrigin is! String ||
        issuerOrigin.isEmpty ||
        redirectUri is! String ||
        redirectUri.isEmpty ||
        createdAt is! String) {
      return null;
    }
    return WebOauthPendingTxn(
      verifier: verifier,
      state: state,
      clientId: clientId,
      workerUrl: workerUrl,
      label: label,
      issuerOrigin: issuerOrigin,
      redirectUri: redirectUri,
      createdAt: createdAt,
    );
  }
}

/// The terminal outcome of the COMPLETE step, returned to the caller (the web
/// home init) purely for logging — the web layer itself shows the SnackBar and
/// navigates, so callers do not need to act on this.
enum WebOauthCompleteOutcome {
  /// No captured code / no pending txn — normal app start, nothing happened.
  none,

  /// The connection was created and persisted successfully.
  success,

  /// A captured code existed but completion failed (validation, exchange, or
  /// the downstream connection build) — a SnackBar surfaced the reason.
  failure,
}

/// The parameters captured from the OAuth redirect URL (the `?…` query that
/// precedes the `#` fragment). Captured as EARLY as possible in `main()`
/// before the hash router can strip them.
class WebOauthCallbackParams {
  const WebOauthCallbackParams({
    this.code,
    this.state,
    this.iss,
    this.error,
  });

  final String? code;
  final String? state;
  final String? iss;
  final String? error;

  /// True iff this looks like an OAuth redirect at all (a `code` or an
  /// `error` present) — used by CAPTURE to decide whether to strip the URL.
  bool get isOauthRedirect =>
      (code != null && code!.isNotEmpty) ||
      (error != null && error!.isNotEmpty);

  /// Read the OAuth callback parameters from a full redirect [uri].
  ///
  /// Reads from [Uri.queryParameters] (the query BEFORE the `#`), which is why
  /// CAPTURE must run before the hash router rewrites the location.
  factory WebOauthCallbackParams.fromUri(Uri uri) {
    final q = uri.queryParameters;
    return WebOauthCallbackParams(
      code: q['code'],
      state: q['state'],
      iss: q['iss'],
      error: q['error'],
    );
  }
}

/// The outcome of validating a captured redirect against the stored pending
/// transaction — either the parameters needed to exchange the code, or a
/// fail-closed [failureReason].
class WebOauthValidation {
  const WebOauthValidation._({
    this.exchange,
    this.failureReason,
  });

  /// Non-null on success: everything the token exchange needs.
  final WebOauthExchangeRequest? exchange;

  /// Non-null on failure: a human-readable reason (already user-safe).
  final String? failureReason;

  bool get isValid => exchange != null;

  factory WebOauthValidation.failure(String reason) =>
      WebOauthValidation._(failureReason: reason);

  factory WebOauthValidation.success(WebOauthExchangeRequest exchange) =>
      WebOauthValidation._(exchange: exchange);
}

/// The validated inputs to the `/token` exchange (built only after every
/// security check passed).
class WebOauthExchangeRequest {
  const WebOauthExchangeRequest({
    required this.tokenUrl,
    required this.issuerOrigin,
    required this.clientId,
    required this.code,
    required this.codeVerifier,
    required this.redirectUri,
    required this.workerUrl,
    required this.label,
  });

  /// `{workerUrl}/token`.
  final String tokenUrl;
  final String issuerOrigin;
  final String clientId;
  final String code;
  final String codeVerifier;
  final String redirectUri;
  final String workerUrl;
  final String label;
}

/// Validate a captured OAuth redirect against the stored pending transaction,
/// applying EVERY native hardening check before allowing a code exchange.
///
/// Fail-closed order (mirrors `HostedOauthClient.authenticate`):
///   1. `state` MUST be present and equal the stored state (CSRF /
///      unsolicited-callback defense).
///   2. an `error` parameter → denied.
///   3. if an RFC 9207 `iss` is present, it MUST resolve to the stored
///      `issuerOrigin` (mix-up defense). (The token-response `iss` is checked
///      separately by the exchange, exactly like the native `_exchangeCode`.)
///   4. a `code` MUST be present.
///
/// On success returns the [WebOauthExchangeRequest]; otherwise a
/// [WebOauthValidation.failure] with a user-safe reason.
WebOauthValidation validateWebOauthCallback({
  required WebOauthCallbackParams params,
  required WebOauthPendingTxn txn,
}) {
  // 1. state CSRF check — reject unless the callback carries OUR exact state.
  final state = params.state;
  if (state == null || state.isEmpty || state != txn.state) {
    return WebOauthValidation.failure(
      'Hosted AI sign-in could not be verified (state mismatch).',
    );
  }

  // 2. explicit error from the AS.
  final error = params.error;
  if (error != null && error.isNotEmpty) {
    return WebOauthValidation.failure('Hosted AI sign-in was denied: $error');
  }

  // 3. RFC 9207 issuer check on the callback (mix-up defense): if present it
  //    MUST match the Worker origin we are connecting to. A non-absolute `iss`
  //    has no origin (`Uri.origin` throws on a scheme-less URI), so guard it and
  //    fail closed.
  final iss = params.iss;
  if (iss != null && iss.isNotEmpty) {
    final issOrigin = _safeOrigin(iss);
    if (issOrigin == null || issOrigin != txn.issuerOrigin) {
      return WebOauthValidation.failure(
        'OAuth issuer mismatch on the sign-in callback.',
      );
    }
  }

  // 4. an authorization code must be present.
  final code = params.code;
  if (code == null || code.isEmpty) {
    return WebOauthValidation.failure(
      'Hosted AI sign-in returned no authorization code.',
    );
  }

  return WebOauthValidation.success(
    WebOauthExchangeRequest(
      tokenUrl: '${txn.workerUrl}/token',
      issuerOrigin: txn.issuerOrigin,
      clientId: txn.clientId,
      code: code,
      codeVerifier: txn.verifier,
      redirectUri: txn.redirectUri,
      workerUrl: txn.workerUrl,
      label: txn.label,
    ),
  );
}

/// The origin of [value] (`scheme://host[:port]`), or null if it is not an
/// absolute http(s) URL. `Uri.origin` THROWS on a scheme-less or non-http(s)
/// URI, so this wraps it — security-critical callers (issuer binding) need a
/// fail-closed null, never an exception.
String? _safeOrigin(String value) {
  final parsed = Uri.tryParse(value);
  if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) return null;
  if (parsed.scheme != 'http' && parsed.scheme != 'https') return null;
  try {
    return parsed.origin;
  } catch (_) {
    return null;
  }
}

/// Derive the OAuth `redirect_uri` (the SPA "app root") from [base]
/// (normally `Uri.base`).
///
/// It is the origin + path with the query AND fragment stripped — e.g.
/// `https://host/` or `https://host/app/` when served under a base href. The
/// IDENTICAL string is used at register, authorize, and token (it is stored in
/// the pending txn and reused verbatim at `/token`).
///
/// Implementation note: built as `origin + path` (NOT via `Uri.replace`, which
/// would emit a stray `?` for an empty query). `Uri.origin` already drops the
/// default port; the path is kept exactly as served (it does NOT force a
/// trailing slash), so a base-href subpath survives. The deployed Worker
/// accepts the resulting `https` redirect_uri via DCR.
String deriveWebRedirectUri(Uri base) {
  return base.origin + base.path;
}

/// Strip the query string from a full location [uri] while preserving the path
/// and the hash fragment (the route). Used by CAPTURE to rewrite the address
/// bar via `history.replaceState` so a refresh cannot replay the `?code`.
///
/// Built as `origin + path + #fragment` (NOT via `Uri.replace`, which emits a
/// stray `?` for an empty query) so the rewritten URL keeps the exact route.
String stripQueryPreservingFragment(Uri uri) {
  final base = uri.origin + uri.path;
  return uri.fragment.isNotEmpty ? '$base#${uri.fragment}' : base;
}

/// Build the `/authorize` URL for the web same-tab redirect.
///
/// Identical query shape to the native `HostedOauthClient` (response_type,
/// client_id, redirect_uri, scope, state, code_challenge, S256) — only the
/// `redirect_uri` differs (the https app root instead of the custom scheme).
Uri buildWebAuthorizeUrl({
  required String workerUrl,
  required String clientId,
  required String redirectUri,
  required String scope,
  required String state,
  required String codeChallenge,
}) {
  return Uri.parse('$workerUrl/authorize').replace(
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
}

/// Normalize a user-entered Worker URL: trim + drop any trailing slashes, so
/// `'$base/authorize'` etc. never produce a double slash. Mirrors the native
/// `_normalizeBase`.
String normalizeWorkerBase(String workerUrl) {
  var s = workerUrl.trim();
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// A cryptographically-secure RNG shared by the PKCE/state generators.
final Random _secureRandom = Random.secure();

/// `n` random bytes as an unpadded base64url string (URL-safe RFC 7636
/// charset). Mirrors the native `HostedOauthClient._randomUrlSafe`.
String randomUrlSafe(int n) {
  final bytes = Uint8List(n);
  for (var i = 0; i < n; i++) {
    bytes[i] = _secureRandom.nextInt(256);
  }
  return base64UrlEncode(bytes).replaceAll('=', '');
}

/// A 43-char PKCE `code_verifier` (base64url of 32 random bytes) — the
/// minimum-length, high-entropy verifier RFC 7636 §4.1 recommends. Mirrors the
/// native `_generateCodeVerifier`.
String generateCodeVerifier() => randomUrlSafe(32);
