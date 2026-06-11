import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:http/http.dart' as http;

import 'package:fula_files/core/platform/rust_lib_init.dart' as rust_lib;
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/issuer_client.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/utils/canonical_kek_input.dart';
import 'package:fula_files/core/utils/seed_signing_input.dart';

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

  /// Challenge purposes (must match the issuer's purpose tags).
  static const String purposeRegisterModeB = 'register-mode-b';
  static const String purposeRegisterModeC = 'register-mode-c';

  /// keyDerivationVersion tags persisted per mode.
  static const String modeTagB = '2_mode_B';
  static const String modeTagC = '2_mode_C';

  /// Default gateway endpoints seeded after a sign-in writes a JWT
  /// (mirrors the deep-link /get-key flow so all sign-in paths reach
  /// the same persisted state).
  static const String defaultS3GatewayUrl = 'https://s3.cloud.fx.land';
  static const String defaultIpfsServerUrl = 'https://api.cloud.fx.land';

  /// Synthetic email for Mode C vaults (no OAuth identity).
  static String syntheticModeCEmail(String effectiveUserIdHex) =>
      '$effectiveUserIdHex@seed.fxfiles.local';

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

  /// Seed the default gateway/IPFS endpoint URLs if absent (mirrors the
  /// deep-link /get-key flow's writes so every sign-in path reaches the
  /// same persisted state; without this, initializeFulaFromStorage bails
  /// with no-endpoint on the next cold start even though the user holds
  /// a valid JWT).
  static Future<void> seedDefaultEndpoints() async {
    final existingGateway = await SecureStorageService.instance.read(
      SecureStorageKeys.apiGatewayUrl,
    );
    if (existingGateway == null || existingGateway.isEmpty) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.apiGatewayUrl,
        defaultS3GatewayUrl,
      );
    }
    final existingIpfs = await SecureStorageService.instance.read(
      SecureStorageKeys.ipfsServerUrl,
    );
    if (existingIpfs == null || existingIpfs.isEmpty) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.ipfsServerUrl,
        defaultIpfsServerUrl,
      );
    }
  }

  // ==========================================================================
  // Mode B / Mode C registration orchestration (seed-as-identity).
  // The seed never leaves the device; only the derived effective_user_id,
  // public key, challenge and signature transit to the issuer.
  // ==========================================================================

  /// Mode B sign-in / sign-up (idempotent at the issuer). Derives the
  /// identity + signing keypair locally, runs the challenge/register
  /// round-trip, derives the master KEK, persists the session storage
  /// state, and returns the issuer result + KEK. Platform side effects
  /// (in-memory user state, UI event emission) are the caller's job.
  static Future<({SeedAuthResult result, Uint8List kek})>
      performModeBRegistration({
    required String provider, // 'google' or 'apple'
    required String oauthToken,
    required String oauthSub,
    required String email,
    required String displayName,
    String? photoUrl,
    required String seed,
  }) async {
    if (seed.isEmpty) {
      throw ArgumentError('Mode B password must not be empty');
    }

    // 1. Derive identity locally.
    final effectiveUserIdHex = await computeEffectiveUserIdModeBHex(
      provider: provider,
      oauthSub: oauthSub,
      seed: seed,
    );
    // Audit fix #3 (2026-05-18): bind the Mode B signing key to the full
    // (provider, oauth_sub, password) tuple, not just the password.
    final keyPair = await deriveSigningKeypair(
      modeBSigningInput(provider, oauthSub, seed),
    );
    final pubKey = await keyPair.extractPublicKey();

    // 2. Server-issued single-use challenge (audit finding #1: defeats
    // capture-and-replay of registration bodies).
    final issuer = IssuerClient(baseUrl: await issuerBaseUrl());
    final challenge = await issuer.challenge(
      effectiveUserIdHex,
      purpose: purposeRegisterModeB,
    );

    // 3. Sign the register transcript over the server's challenge.
    final transcript = buildSignedTranscript(
      purposeRegisterModeB,
      effectiveUserIdHex,
      challenge,
    );
    final signature = await Ed25519().sign(transcript, keyPair: keyPair);

    // 4. Register (server re-consumes the nonce and verifies).
    final result = await issuer.registerModeB(
      provider: provider,
      oauthToken: oauthToken,
      effectiveUserIdHex: effectiveUserIdHex,
      publicKey: Uint8List.fromList(pubKey.bytes),
      challenge: challenge,
      signature: Uint8List.fromList(signature.bytes),
    );

    // 5. Master KEK (Argon2id, Mode B context).
    final kek = await deriveKekModeB(
      provider: provider,
      oauthSub: oauthSub,
      seed: seed,
    );

    // 6. Persist session storage state.
    await persistSeedSession(
      result: result,
      kek: kek,
      provider: provider,
      oauthSub: oauthSub,
      email: email,
      displayName: displayName,
      photoUrl: photoUrl,
    );

    return (result: result, kek: kek);
  }

  /// Mode C sign-in / sign-up (idempotent at the issuer). No OAuth —
  /// the seed IS the user. Same contract as [performModeBRegistration].
  static Future<({SeedAuthResult result, Uint8List kek, String email})>
      performModeCRegistration({
    required String seed,
    String? displayName,
  }) async {
    if (seed.trim().isEmpty) {
      throw ArgumentError('Mode C seed must not be empty');
    }

    final effectiveUserIdHex = await computeEffectiveUserIdModeCHex(seed);
    final keyPair = await deriveSigningKeypair(seed);
    final pubKey = await keyPair.extractPublicKey();

    final issuer = IssuerClient(baseUrl: await issuerBaseUrl());
    final challenge = await issuer.challenge(
      effectiveUserIdHex,
      purpose: purposeRegisterModeC,
    );

    final transcript = buildSignedTranscript(
      purposeRegisterModeC,
      effectiveUserIdHex,
      challenge,
    );
    final signature = await Ed25519().sign(transcript, keyPair: keyPair);

    final result = await issuer.registerModeC(
      effectiveUserIdHex: effectiveUserIdHex,
      publicKey: Uint8List.fromList(pubKey.bytes),
      challenge: challenge,
      signature: Uint8List.fromList(signature.bytes),
    );

    final kek = await deriveKekModeC(seed);

    final email = syntheticModeCEmail(effectiveUserIdHex);
    await persistSeedSession(
      result: result,
      kek: kek,
      provider: null,
      oauthSub: null,
      email: email,
      displayName: displayName ?? 'Passphrase Vault',
      photoUrl: null,
    );

    return (result: result, kek: kek, email: email);
  }

  /// Persist the seed-auth session storage state (everything except
  /// platform in-memory state and UI events). Write set and values are
  /// identical to the pre-extraction AuthService._persistSeedAuthSession,
  /// with the deep-link notify's endpoint seeding inlined as
  /// [seedDefaultEndpoints].
  static Future<void> persistSeedSession({
    required SeedAuthResult result,
    required List<int> kek,
    required String? provider,
    required String? oauthSub,
    required String email,
    required String displayName,
    String? photoUrl,
  }) async {
    final modeTag = result.mode == SeedAuthMode.b ? modeTagB : modeTagC;

    await SecureStorageService.instance.write(
      SecureStorageKeys.keyDerivationVersion,
      modeTag,
    );
    await SecureStorageService.instance.write(
      SecureStorageKeys.effectiveUserIdHex,
      result.effectiveUserIdHex,
    );
    if (provider != null) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.modeOauthProvider,
        provider,
      );
    }
    if (oauthSub != null) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.modeOauthSub,
        oauthSub,
      );
    }
    await SecureStorageService.instance.write(
      SecureStorageKeys.jwtToken,
      result.jwt,
    );
    // Mode B/C JWTs are already valid storage-gateway API keys; seed the
    // gateway/IPFS endpoint defaults BEFORE any FulaApiService init reads
    // them (otherwise the app stays authenticated-but-offline with
    // "endpoint configured = false").
    await seedDefaultEndpoints();
    await SecureStorageService.instance.write(
      SecureStorageKeys.encryptionKey,
      base64Encode(kek),
    );
    await SecureStorageService.instance.write(
      SecureStorageKeys.derivationEmail,
      email,
    );
    // Same JSON shape as AuthUser.toJson() so native session restore and
    // the web shell read one format. Mode C is reported as 'google' for
    // backward compat with existing consumers (no OAuth identity anyway).
    await SecureStorageService.instance.writeJson(
      SecureStorageKeys.userCredentials,
      <String, dynamic>{
        'id': result.effectiveUserIdHex,
        'email': email,
        'displayName': displayName,
        'photoUrl': photoUrl,
        'provider': provider == 'apple' ? 'apple' : 'google',
      },
    );

    // Clear the sign-out sentinel.
    await SecureStorageService.instance.delete(SecureStorageKeys.authSignedOut);

    debugPrint(
      'AuthCore: persisted Mode ${result.mode.name.toUpperCase()} session '
      '(effective_user_id=${result.effectiveUserIdHex.substring(0, 8)}…, '
      'created=${result.created})',
    );
  }

  // ==========================================================================
  // FulaApiService initialization from persisted session state.
  // ==========================================================================

  /// Assemble FulaApiService.initialize parameters from SecureStorage
  /// and run it. Returns whether the client is configured, whether the
  /// legacy endpoint-missing state was repaired by seeding defaults
  /// (callers may want to emit a UI event), and the access token used.
  ///
  /// Caller-side follow-ups deliberately NOT done here: starting
  /// MasterHealthService, native retry hooks (ShelfService), event
  /// emission.
  static Future<({bool configured, bool seededEndpoints, String? accessToken})>
      initializeFulaFromStorage({required Uint8List kek}) async {
    var seededEndpoints = false;

    var endpoint = await SecureStorageService.instance.read(
      SecureStorageKeys.apiGatewayUrl,
    );
    final accessToken = await SecureStorageService.instance.read(
      SecureStorageKeys.jwtToken,
    );

    // Migration for users who signed in under the pre-fix in-app flow:
    // JWT persisted but endpoint defaults never written.
    if ((endpoint == null || endpoint.isEmpty) &&
        accessToken != null &&
        accessToken.isNotEmpty) {
      debugPrint('AuthCore: JWT present but endpoint missing — '
          'seeding default gateway/IPFS URLs');
      await seedDefaultEndpoints();
      seededEndpoints = true;
      endpoint = await SecureStorageService.instance.read(
        SecureStorageKeys.apiGatewayUrl,
      );
    }

    debugPrint(
        'AuthCore: endpoint configured = ${endpoint != null && endpoint.isNotEmpty}');
    debugPrint(
        'AuthCore: accessToken present = ${accessToken != null && accessToken.isNotEmpty}');

    if (endpoint == null || endpoint.isEmpty) {
      debugPrint('FulaApiService not initialized: no endpoint configured');
      return (
        configured: false,
        seededEndpoints: seededEndpoints,
        accessToken: accessToken,
      );
    }

    // Pinned derivation email — used by FulaApiService for the per-user
    // cold-start key so the on-chain registry resolver can locate this
    // user's anchor.
    final derivationEmail = await SecureStorageService.instance.read(
      SecureStorageKeys.derivationEmail,
    );

    // User-editable cold-start resolver overrides (Settings > Fula API
    // Configuration). Empty/null fall back to FulaApiService defaults.
    final baseRpcUrl = await SecureStorageService.instance.read(
      SecureStorageKeys.baseRpcUrl,
    );
    final usersIndexAnchor = await SecureStorageService.instance.read(
      SecureStorageKeys.usersIndexAnchorAddress,
    );
    final usersIndexIpns = await SecureStorageService.instance.read(
      SecureStorageKeys.usersIndexIpnsName,
    );
    final usersIndexIpnsGatewayRaw = await SecureStorageService.instance
        .read(SecureStorageKeys.usersIndexIpnsGatewayUrls);
    final usersIndexIpnsGateways = usersIndexIpnsGatewayRaw
        ?.split(RegExp(r'[\n,]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);

    // Mode B/C users get K_index + K_entry_seed so the SDK can encrypt
    // + sign the per-user bucketsIndex envelope. Mode A skips (KEK is
    // derivable from public OAuth attributes — encrypting under it would
    // not be privacy-preserving; SDK falls back to legacy users[] path).
    Uint8List? bucketsIndexKey;
    Uint8List? userEntrySigningSeed;
    final modeVersion = await SecureStorageService.instance.read(
      SecureStorageKeys.keyDerivationVersion,
    );
    final isModeBC = modeVersion != null &&
        (modeVersion.contains('mode_B') || modeVersion.contains('mode_C'));
    if (isModeBC) {
      try {
        final indexKeys = await deriveBucketsIndexKeys(kek);
        bucketsIndexKey = indexKeys.bucketsIndexKey;
        userEntrySigningSeed = indexKeys.userEntrySigningSeed;
        // Persist for fast re-load on next cold start.
        await SecureStorageService.instance.write(
          SecureStorageKeys.bucketsIndexKey,
          base64Encode(bucketsIndexKey),
        );
        await SecureStorageService.instance.write(
          SecureStorageKeys.userEntrySigningSeed,
          base64Encode(userEntrySigningSeed),
        );
        debugPrint(
            'AuthCore: derived K_index + K_entry_seed for Mode B/C user');
      } catch (e) {
        debugPrint('AuthCore: blake3DeriveKey failed: $e; '
            'falling back to legacy users[] path');
        bucketsIndexKey = null;
        userEntrySigningSeed = null;
      }
    }

    await FulaApiService.instance.initialize(
      endpoint: endpoint,
      secretKey: kek,
      accessToken: accessToken,
      userEmail: derivationEmail,
      chainRpcUrl: baseRpcUrl,
      usersIndexAnchorAddress: usersIndexAnchor,
      usersIndexIpnsName: usersIndexIpns,
      usersIndexIpnsGatewayUrls: usersIndexIpnsGateways,
      bucketsIndexKey: bucketsIndexKey,
      userEntrySigningSeed: userEntrySigningSeed,
    );
    debugPrint('FulaApiService initialized successfully');
    debugPrint(
        'AuthCore: FulaApiService.isConfigured = ${FulaApiService.instance.isConfigured}');

    return (
      configured: FulaApiService.instance.isConfigured,
      seededEndpoints: seededEndpoints,
      accessToken: accessToken,
    );
  }

  /// Delete the per-session SecureStorage keys (exact parity with the
  /// native signOut's SecureStorage deletion set).
  static Future<void> clearSessionStorage() async {
    await SecureStorageService.instance.delete(SecureStorageKeys.userCredentials);
    await SecureStorageService.instance.delete(SecureStorageKeys.authProvider);
    await SecureStorageService.instance.delete(SecureStorageKeys.encryptionKey);
    await SecureStorageService.instance.delete(SecureStorageKeys.derivationEmail);
    await SecureStorageService.instance.delete(SecureStorageKeys.userPublicKey);
    await SecureStorageService.instance.delete(SecureStorageKeys.userPrivateKey);
    await SecureStorageService.instance.delete(SecureStorageKeys.jwtToken);
    await SecureStorageService.instance.delete(SecureStorageKeys.refreshToken);
    await SecureStorageService.instance.delete(SecureStorageKeys.keyDerivationVersion);
    await SecureStorageService.instance.delete(SecureStorageKeys.effectiveUserIdHex);
    await SecureStorageService.instance.delete(SecureStorageKeys.modeOauthProvider);
    await SecureStorageService.instance.delete(SecureStorageKeys.modeOauthSub);
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
