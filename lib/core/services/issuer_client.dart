/// Client for the pinning-service issuer endpoints that mint JWTs for
/// Mode B / Mode C sign-in (audit F-A1 / F-A3 redesign, 2026-05-18).
///
/// Wraps the four routes implemented in `pinning-service/pinning-webui`
/// at commit 25280a1:
///   POST /auth/register-mode-b
///   POST /auth/register-mode-c
///   POST /auth/challenge
///   POST /auth/sign-in
///
/// The seed never leaves the device. This client transports only:
///  - The 16-byte `effective_user_id` (derived client-side from the seed).
///  - The 32-byte Ed25519 public key (derived client-side from the seed).
///  - Challenge / signature byte arrays.
///  - For Mode B: the OAuth ID token from Google/Apple, which the
///    issuer hands off to its existing OAuth verifier.
///
/// HTTP errors are surfaced as `IssuerException` with the upstream
/// `code` string when available (e.g. `PUBLIC_KEY_MISMATCH`,
/// `SIGNATURE_INVALID`, `USER_NOT_FOUND`). UI layers should map those
/// to user-facing copy.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Tag identifying a successful seed-auth response. Mirrors the
/// server-side `mode` field returned by all four endpoints.
enum SeedAuthMode { b, c }

/// Result of `/auth/register-mode-{b,c}` or `/auth/sign-in`.
class SeedAuthResult {
  /// The minted JWT (HS256, same shape as a Mode A `/api/keys` token).
  final String jwt;

  /// 32-char lowercase hex — the JWT's `sub`. Also the gateway's
  /// per-user namespace input.
  final String effectiveUserIdHex;

  /// Which mode the issuer recognised this user as.
  final SeedAuthMode mode;

  /// True if this call created a NEW record (first-time sign-up).
  /// False for an idempotent re-registration on a new device.
  final bool created;

  /// (Mode B only) Whether the OAuth identity ALREADY had a Mode A
  /// account before this Mode B registration. UI layers should warn
  /// the user that their new vault is separate. False / null for
  /// Mode C.
  final bool? hasModeA;

  const SeedAuthResult({
    required this.jwt,
    required this.effectiveUserIdHex,
    required this.mode,
    required this.created,
    this.hasModeA,
  });
}

/// Thrown when the issuer returns a non-2xx response.
///
/// `code` is the upstream string (e.g. `PUBLIC_KEY_MISMATCH`) when the
/// server provided one; `null` for transport-level failures.
class IssuerException implements Exception {
  final int statusCode;
  final String? code;
  final String message;

  const IssuerException(this.statusCode, this.code, this.message);

  @override
  String toString() =>
      'IssuerException(status=$statusCode, code=$code, message="$message")';
}

class IssuerClient {
  /// Base URL of the pinning-service deployment. e.g.
  /// `https://cloud.fx.land`. NO trailing slash.
  final String baseUrl;

  /// HTTP client to use. Default: a fresh `http.Client()`. Injected for
  /// tests.
  final http.Client _http;

  /// Request timeout. Issuer endpoints are fast; 15s is generous.
  final Duration timeout;

  IssuerClient({
    required this.baseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
  }) : _http = httpClient ?? http.Client();

  /// First-time sign-up via Mode B (OAuth + seed). Idempotent for the
  /// same Ed25519 public key (returns the existing JWT). Returns
  /// 409 `PUBLIC_KEY_MISMATCH` if the `effective_user_id` is already
  /// registered under a different public key (squatting attempt — or
  /// the user has corrupted local state).
  Future<SeedAuthResult> registerModeB({
    required String provider, // 'google' or 'apple'
    required String oauthToken,
    required String effectiveUserIdHex,
    required Uint8List publicKey, // 32 raw bytes
    required Uint8List challenge, // 32 raw bytes (client-generated)
    required Uint8List signature, // 64 raw bytes (Ed25519 over transcript)
  }) async {
    final body = {
      'provider': provider,
      'oauth_token': oauthToken,
      'effective_user_id_hex': effectiveUserIdHex,
      'public_key_b64': base64Encode(publicKey),
      'challenge_b64': base64Encode(challenge),
      'signature_b64': base64Encode(signature),
    };
    final res = await _post('/auth/register-mode-b', body);
    return SeedAuthResult(
      jwt: res['jwt'] as String,
      effectiveUserIdHex: res['effective_user_id_hex'] as String,
      mode: SeedAuthMode.b,
      created: (res['created'] as bool?) ?? false,
      hasModeA: res['has_mode_a'] as bool?,
    );
  }

  /// First-time sign-up via Mode C (seed only, no OAuth). Idempotent
  /// for the same Ed25519 public key.
  Future<SeedAuthResult> registerModeC({
    required String effectiveUserIdHex,
    required Uint8List publicKey,
    required Uint8List challenge,
    required Uint8List signature,
  }) async {
    final body = {
      'effective_user_id_hex': effectiveUserIdHex,
      'public_key_b64': base64Encode(publicKey),
      'challenge_b64': base64Encode(challenge),
      'signature_b64': base64Encode(signature),
    };
    final res = await _post('/auth/register-mode-c', body);
    return SeedAuthResult(
      jwt: res['jwt'] as String,
      effectiveUserIdHex: res['effective_user_id_hex'] as String,
      mode: SeedAuthMode.c,
      created: (res['created'] as bool?) ?? false,
    );
  }

  /// Request a fresh single-use challenge nonce. The returned bytes
  /// MUST be signed by the seed-derived Ed25519 private key (with the
  /// `purpose` tag in the signed transcript) and submitted to the
  /// matching endpoint within 60 seconds.
  ///
  /// Audit finding #1 fix: the challenge is now required for
  /// **registration** too, not just sign-in — without server-issued
  /// single-use challenges, a captured registration body could be
  /// replayed to mint perpetually-valid JWTs.
  ///
  /// `purpose` is one of:
  /// - `'sign-in'` — default; the issuer requires the user to exist.
  /// - `'register-mode-b'` — pre-registration nonce for Mode B.
  /// - `'register-mode-c'` — pre-registration nonce for Mode C.
  ///
  /// Throws `IssuerException` with code `USER_NOT_FOUND` (HTTP 404) if
  /// `purpose == 'sign-in'` and the issuer has no record of this
  /// `effective_user_id`. For register purposes the user need not
  /// exist (we're creating them).
  Future<Uint8List> challenge(
    String effectiveUserIdHex, {
    String purpose = 'sign-in',
  }) async {
    final res = await _post('/auth/challenge', {
      'effective_user_id_hex': effectiveUserIdHex,
      'purpose': purpose,
    });
    final b64 = res['challenge_b64'] as String;
    return Uint8List.fromList(base64Decode(b64));
  }

  /// Submit a signed challenge for sign-in. Server verifies with the
  /// stored public key (set at registration time) and mints a JWT.
  ///
  /// On failure, common codes:
  /// - `CHALLENGE_INVALID` — nonce missing/expired/tampered.
  /// - `SIGNATURE_INVALID` — wrong private key.
  /// - `USER_NOT_FOUND` — effective_user_id unknown to the issuer.
  Future<SeedAuthResult> signIn({
    required String effectiveUserIdHex,
    required Uint8List challenge,
    required Uint8List signature,
  }) async {
    final res = await _post('/auth/sign-in', {
      'effective_user_id_hex': effectiveUserIdHex,
      'challenge_b64': base64Encode(challenge),
      'signature_b64': base64Encode(signature),
    });
    final modeStr = res['mode'] as String;
    return SeedAuthResult(
      jwt: res['jwt'] as String,
      effectiveUserIdHex: res['effective_user_id_hex'] as String,
      mode: modeStr == 'B' ? SeedAuthMode.b : SeedAuthMode.c,
      created: false,
    );
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$baseUrl$path');
    final http.Response res;
    try {
      res = await _http
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const IssuerException(0, 'TIMEOUT', 'issuer request timed out');
    } catch (e) {
      throw IssuerException(0, 'TRANSPORT', 'transport error: $e');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    // Try to extract a JSON `{error, code}` body; fall back to plain text.
    String? code;
    String message = res.body;
    try {
      final parsed = jsonDecode(res.body) as Map<String, dynamic>;
      code = parsed['code'] as String?;
      message = (parsed['error'] as String?) ?? res.body;
    } catch (_) {
      // Non-JSON body — keep `message` as the raw response text.
    }
    throw IssuerException(res.statusCode, code, message);
  }
}
