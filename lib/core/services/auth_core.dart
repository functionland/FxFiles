import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:http/http.dart' as http;

import 'package:fula_files/core/platform/rust_lib_init.dart' as rust_lib;
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/utils/canonical_kek_input.dart';

/// Platform-neutral auth primitives shared by the native [AuthService]
/// and the web shell.
///
/// SINGLE SOURCE OF TRUTH for everything that decides which bytes a
/// user's master key is derived from and which bytes get signed toward
/// the issuer. A drifted copy of any constant or input-assembly rule in
/// here derives a DIFFERENT key for the same identity and silently
/// fails to decrypt the user's existing data — which is why native and
/// web must both call through this class instead of carrying their own
/// copies.
///
/// Deliberately imports NO dart:io, no native-only services, and no
/// OAuth SDKs, so it is safe in the web compile graph. Extracted
/// move-and-delegate from auth_service.dart (P2 of the web port); the
/// behavior and every byte of protocol input are unchanged.
class AuthCore {
  AuthCore._();

  // ==========================================================================
  // Protocol constants (wire/KDF compatibility — DO NOT EDIT values).
  // ==========================================================================

  /// Argon2id context for Mode A (legacy OAuth) master keys.
  static const String kekContextModeA = 'fula-files-v1';

  /// Argon2id context for Mode B (OAuth + seed) master keys.
  static const String kekContextModeB = 'fula-files-v2-mode-b';

  /// Argon2id context for Mode C (seed only) master keys.
  static const String kekContextModeC = 'fula-files-v2-mode-c';

  /// BLAKE3 derive-key context for the per-user buckets-index key
  /// (K_index) — Mode B/C only.
  static const String bucketsIndexKeyContext = 'fula:user-buckets-index:v1';

  /// BLAKE3 derive-key context for the per-user entry-signing seed
  /// (K_entry_seed) — Mode B/C only.
  static const String userEntrySigningContext = 'fula:user-entry-signing:v1';

  /// Domain separator for issuer transcripts. The trailing `\0` IS
  /// part of the protocol: the issuer's `buildSignedTranscript` in
  /// pinning-service/server/services/seedAuth.ts reconstructs
  /// `"fula.seed-auth.v1\0" || purpose || 0x00 || euid_hex || 0x00 ||
  /// challenge` byte-for-byte. (The pre-extraction auth_service.dart
  /// carried the NUL as a literal 0x00 byte inside the string literal,
  /// which renders like a space in most editors — the explicit escape
  /// here is byte-identical and visible. Pinned by the golden-bytes
  /// test in test/unit/core/services/auth_core_test.dart.)
  static const String seedAuthDomainSeparator = 'fula.seed-auth.v1\u0000';

  /// Default issuer (pinning-service that mints JWTs).
  static const String defaultIssuerBaseUrl = 'https://cloud.fx.land';

  // ==========================================================================
  // Transcript + signing-key primitives (Mode B/C seed auth).
  // ==========================================================================

  /// Build the byte sequence the client signs with its seed-derived
  /// Ed25519 private key. MUST match exactly what the issuer
  /// reconstructs in `pinning-service/server/services/seedAuth.ts`'s
  /// `buildSignedTranscript`.
  ///
  /// Layout:
  ///   "fula.seed-auth.v1\0" || purpose || 0x00 ||
  ///   effective_user_id_hex_ascii || 0x00 || challenge
  static Uint8List buildSignedTranscript(
    String purpose,
    String effectiveUserIdHex,
    Uint8List challenge,
  ) {
    final out = BytesBuilder();
    out.add(utf8.encode(seedAuthDomainSeparator));
    out.add(utf8.encode(purpose));
    out.add([0]);
    out.add(ascii.encode(effectiveUserIdHex));
    out.add([0]);
    out.add(challenge);
    return out.toBytes();
  }

  /// Derive the Ed25519 signing keypair from the user's seed (or, for
  /// Mode B, the `modeBSigningInput(provider, oauthSub, seed)` tuple
  /// encoding). Pure deterministic: same input → same keypair on any
  /// device. The FFI handles NFKC + domain-separation; we just consume
  /// the 32-byte signing seed it returns.
  static Future<SimpleKeyPair> deriveSigningKeypair(String seed) async {
    await rust_lib.ensureRustLibInitialized();
    final signingSeed = await fula.deriveSigningSeed(seed: seed);
    final algorithm = Ed25519();
    return algorithm.newKeyPairFromSeed(signingSeed);
  }

  /// 16-byte effective_user_id (hex) for Mode B users.
  static Future<String> computeEffectiveUserIdModeBHex({
    required String provider,
    required String oauthSub,
    required String seed,
  }) async {
    await rust_lib.ensureRustLibInitialized();
    final bytes = await fula.computeEffectiveUserIdModeB(
      provider: provider,
      oauthSub: oauthSub,
      seed: seed,
    );
    return bytesToHex(bytes);
  }

  /// 16-byte effective_user_id (hex) for Mode C users.
  static Future<String> computeEffectiveUserIdModeCHex(String seed) async {
    await rust_lib.ensureRustLibInitialized();
    final bytes = await fula.computeEffectiveUserIdModeC(seed: seed);
    return bytesToHex(bytes);
  }

  static String bytesToHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  // ==========================================================================
  // Master-KEK derivation (Argon2id via fula_client — identical bytes on
  // native FFI and web WASM).
  // ==========================================================================

  /// Mode A KDF input string: `"{provider}:{userId}:{email}"`. The email
  /// MUST be the pinned derivation email (persisted at first sign-in),
  /// not whatever the OAuth provider returned this session — Apple's
  /// relay addresses drift across devices.
  static String modeAKekInput({
    required String providerName,
    required String userId,
    required String email,
  }) =>
      '$providerName:$userId:$email';

  /// Derive the Mode A master key (Argon2id, v1 context).
  static Future<Uint8List> deriveKekModeA({
    required String providerName,
    required String userId,
    required String email,
  }) async {
    await rust_lib.ensureRustLibInitialized();
    final input = modeAKekInput(
      providerName: providerName,
      userId: userId,
      email: email,
    );
    return Uint8List.fromList(
      await fula.deriveKey(context: kekContextModeA, input: utf8.encode(input)),
    );
  }

  /// Derive the Mode B master key (Argon2id over the canonical
  /// length-prefixed `(provider, oauth_sub, NFC(seed))` encoding).
  static Future<Uint8List> deriveKekModeB({
    required String provider,
    required String oauthSub,
    required String seed,
  }) async {
    await rust_lib.ensureRustLibInitialized();
    return Uint8List.fromList(
      await fula.deriveKey(
        context: kekContextModeB,
        input: canonicalKekInputModeB(provider, oauthSub, seed),
      ),
    );
  }

  /// Derive the Mode C master key (Argon2id over the canonical
  /// length-prefixed `NFC(seed)` encoding).
  static Future<Uint8List> deriveKekModeC(String seed) async {
    await rust_lib.ensureRustLibInitialized();
    return Uint8List.fromList(
      await fula.deriveKey(
        context: kekContextModeC,
        input: canonicalKekInputModeC(seed),
      ),
    );
  }

  /// Derive the Mode B/C per-user index keys from the master KEK:
  /// K_index (buckets-index encryption) + K_entry_seed (entry signing).
  /// Mode A users skip this — their KEK is derivable from public OAuth
  /// attributes, so encrypting under it would not be privacy-preserving.
  static Future<({Uint8List bucketsIndexKey, Uint8List userEntrySigningSeed})>
      deriveBucketsIndexKeys(Uint8List kek) async {
    await rust_lib.ensureRustLibInitialized();
    final bucketsIndexKey = Uint8List.fromList(
      await fula.blake3DeriveKey(context: bucketsIndexKeyContext, input: kek),
    );
    final userEntrySigningSeed = Uint8List.fromList(
      await fula.blake3DeriveKey(context: userEntrySigningContext, input: kek),
    );
    return (
      bucketsIndexKey: bucketsIndexKey,
      userEntrySigningSeed: userEntrySigningSeed,
    );
  }

  // ==========================================================================
  // Issuer plumbing.
  // ==========================================================================

  /// Resolve the issuer base URL (the pinning-service that mints JWTs).
  /// Pulled from SecureStorage if the user customized it; otherwise
  /// [defaultIssuerBaseUrl].
  static Future<String> issuerBaseUrl() async {
    final stored = await SecureStorageService.instance.read(
      SecureStorageKeys.billingServerUrl,
    );
    if (stored != null && stored.isNotEmpty) return stored;
    return defaultIssuerBaseUrl;
  }

  /// Mode A in-app JWT-bearer fetch: POST the OAuth ID token to the
  /// pinning-service `/auth/google` or `/auth/apple` endpoint and read
  /// the minted JWT from the response. Returns `null` on any transport
  /// or non-2xx error — sign-in still succeeds with the local-only
  /// encryption key, and the legacy browser /get-key fallback in the
  /// setup sheet remains available.
  static Future<String?> exchangeOAuthIdTokenForJwt({
    required String path,
    required Map<String, dynamic> body,
  }) async {
    try {
      final baseUrl = await issuerBaseUrl();
      final uri = Uri.parse('$baseUrl$path');
      final res = await http
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final jwt = data['jwt'];
        if (jwt is String && jwt.isNotEmpty) return jwt;
        debugPrint(
            'AuthCore: $path returned 2xx but no jwt field — server may need updating');
        return null;
      }
      debugPrint('AuthCore: $path failed ${res.statusCode}: ${res.body}');
      return null;
    } catch (e) {
      debugPrint('AuthCore: $path exchange error: $e');
      return null;
    }
  }

  /// Extract the JWT-payload `sub` claim without verifying the
  /// signature (display/derivation use only — the gateway is the
  /// authority on validity).
  static String? extractJwtSub(String? jwt) {
    if (jwt == null || jwt.isEmpty) return null;
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return null;
      var payload = parts[1];
      final pad = (4 - payload.length % 4) % 4;
      payload = payload + ('=' * pad);
      final decoded = utf8.decode(base64Url.decode(payload));
      final json = jsonDecode(decoded);
      if (json is! Map) return null;
      final sub = json['sub'];
      if (sub is! String) return null;
      return sub.isEmpty ? null : sub;
    } catch (_) {
      return null;
    }
  }
}
