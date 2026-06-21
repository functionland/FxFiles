import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  SecureStorageService._();
  static final SecureStorageService instance = SecureStorageService._();

  late FlutterSecureStorage _storage;

  Future<void> init() async {
    const androidOptions = AndroidOptions(
      sharedPreferencesName: 'fula_files_secure_prefs',
      preferencesKeyPrefix: 'fula_',
    );
    
    // `first_unlock` requires the device to have been unlocked at least once
    // since boot — same semantics we need for WorkManager / BGTaskScheduler
    // background access, but it narrows the `accessible` class to the
    // smallest one compatible with background reads. Do NOT downgrade to
    // `passcode_this_device`: users without a passcode would lose access.
    const iosOptions = IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
      accountName: 'fula_files',
    );

    const windowsOptions = WindowsOptions();
    const macOsOptions = MacOsOptions();

    _storage = const FlutterSecureStorage(
      aOptions: androidOptions,
      iOptions: iosOptions,
      wOptions: windowsOptions,
      mOptions: macOsOptions,
    );
  }

  Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  Future<String?> read(String key) async {
    return await _storage.read(key: key);
  }

  Future<void> delete(String key) async {
    await _storage.delete(key: key);
  }

  Future<void> deleteAll() async {
    await _storage.deleteAll();
  }

  Future<Map<String, String>> readAll() async {
    return await _storage.readAll();
  }

  Future<bool> containsKey(String key) async {
    return await _storage.containsKey(key: key);
  }

  Future<void> writeJson(String key, Map<String, dynamic> value) async {
    await write(key, jsonEncode(value));
  }

  Future<Map<String, dynamic>?> readJson(String key) async {
    final value = await read(key);
    if (value == null) return null;
    return jsonDecode(value) as Map<String, dynamic>;
  }
}

class SecureStorageKeys {
  SecureStorageKeys._();

  static const String apiGatewayUrl = 'api_gateway_url';
  static const String ipfsServerUrl = 'ipfs_server_url';
  static const String billingServerUrl = 'billing_server_url';
  static const String jwtToken = 'jwt_token';
  static const String encryptionKey = 'encryption_key';
  static const String userCredentials = 'user_credentials';
  static const String authProvider = 'auth_provider';
  static const String refreshToken = 'refresh_token';
  
  // Sharing keys (X25519 key pair)
  static const String userPublicKey = 'user_public_key';
  static const String userPrivateKey = 'user_private_key';

  // Website builder keys
  static const String aiEndpointUrl = 'ai_endpoint_url';
  static const String ipfsGatewayUrl = 'ipfs_gateway_url';
  static const String analyticsEndpointUrl = 'analytics_endpoint_url';

  // IPFS upload endpoint (ipfs-server with /upload and /gateway)
  static const String ipfsEndpointUrl = 'ipfs_endpoint_url';

  // fula-client cold-start resolver fields (read at sign-in, used by the
  // SDK to locate this user's anchor when the master gateway is down).
  // EVM chain RPC URL the resolver reads the on-chain anchor from
  // (Base mainnet by default).
  static const String baseRpcUrl = 'base_rpc_url';
  // Address of the deployed users-index anchor contract on the chain above.
  static const String usersIndexAnchorAddress = 'users_index_anchor_address';
  // IPNS name (`k51qzi5...`) printed by `setup-users-index-publisher.sh` on
  // the master. Same value for every user; bake the deploy default into the
  // app and let advanced users override here.
  static const String usersIndexIpnsName = 'users_index_ipns_name';
  // Newline-separated list of IPNS gateway URL templates the cold-start
  // resolver uses to fetch the per-user anchor. `{cid}` is replaced with
  // the IPNS name. Empty -> SDK's curated IPNS-aware subset.
  static const String usersIndexIpnsGatewayUrls =
      'users_index_ipns_gateway_urls';

  // NFT wallet keys
  static const String nftWalletPrivateKey = 'nft_wallet_private_key';

  // Blox pairing keys (for local-first retrieval)
  static const String bloxPairingSecret = 'blox_pairing_secret';
  static const String bloxHardwareId = 'blox_hardware_id';
  static const String bloxPeerId = 'blox_peer_id';
  static const String bloxName = 'blox_name';
  static const String bloxIpOverride = 'blox_ip_override';
  static const String bloxLastKnownIp = 'blox_last_known_ip';

  // Apple Sign-In derivation email (pinned on first key derivation)
  static const String derivationEmail = 'derivation_email';

  // App backup password keys
  static const String appPasswordSaltPrefix = 'app_password_salt_';
  static const String appPasswordVerifierPrefix = 'app_password_verifier_';
  // Derived encryption key — stored in SecureStorage so background tasks can use it.
  // The OS secure enclave protects it at rest. The raw password is never stored.
  static const String appDerivedKeyPrefix = 'app_derived_key_';

  // AES-256 key (base64 of 32 random bytes) for encrypting local Hive boxes
  // that hold sensitive metadata (face embeddings, OCR tags). Generated once
  // per install and never leaves SecureStorage.
  static const String hiveMetadataKey = 'hive_metadata_key';

  // ISO-8601 timestamp until which the sync upload queue is paused. Persisted
  // so a pause survives app kill — without this, a force-kill mid-pause would
  // lose the resume callback and leave _consecutiveFailures stale on relaunch.
  static const String syncPausedUntil = 'sync_paused_until';

  // Sentinel set when the user explicitly signs out. Suppresses Google's
  // silent lightweight re-authentication, which would otherwise undo the sign
  // out the next time `checkExistingSession` runs (because the on-device
  // Google account stays alive even after `disconnect()`).
  // Cleared on a successful interactive sign-in.
  static const String authSignedOut = 'auth_signed_out';

  // Audit F-A1 / F-A3 redesign (2026-05-18) — seed-as-identity model.
  //
  // Which key-derivation mode the user picked at first sign-in:
  //   '1_mode_A' — OAuth-only (legacy, unchanged for existing users)
  //   '2_mode_B' — OAuth + password (seed mixed into KDF + JWT sub)
  //   '2_mode_C' — Passphrase only, no OAuth
  // Absent → user has not yet picked. Show mode-chooser screen.
  static const String keyDerivationVersion = 'key_derivation_version';

  // For Mode B users: the 32-hex effective_user_id that the issuer's
  // JWT `sub` carries. Cached so we don't recompute on every launch.
  // For Mode A users this is absent (their JWT carries SHA-256(email)).
  static const String effectiveUserIdHex = 'effective_user_id_hex';

  // OAuth provider tag used when computing a Mode B effective_user_id.
  // Either 'google' or 'apple'. Absent for Mode A and Mode C.
  static const String modeOauthProvider = 'mode_oauth_provider';

  // OAuth `sub` claim captured at Mode B sign-up. Pinned so subsequent
  // sign-ins on the same device can re-derive the effective_user_id
  // without re-running OAuth (offline launch with cached JWT). Absent
  // for Mode A and Mode C.
  static const String modeOauthSub = 'mode_oauth_sub';

  // E2E plan Phase 5 — 32-byte AEAD key for encrypting the per-user
  // bucketsIndex envelope (`K_index` in the plan). BLAKE3-derived from
  // the existing `encryptionKey` (the master KEK) with context
  // `"fula:user-buckets-index:v1"`. Only populated for Mode B/C users;
  // Mode A keeps this absent and the SDK falls back to today's
  // plaintext path. Stored base64-encoded.
  static const String bucketsIndexKey = 'buckets_index_key_v1';

  // E2E plan Phase 5 — 32-byte Ed25519 seed for signing the
  // per-user entry the master publishes in the global CBOR
  // (`K_entry_seed` in the plan). BLAKE3-derived from `encryptionKey`
  // with context `"fula:user-entry-signing:v1"`. Only populated for
  // Mode B/C users; Mode A keeps this absent. Stored base64-encoded.
  static const String userEntrySigningSeed = 'user_entry_signing_seed_v1';

  // Website stable-link (IPNS) feature.
  //
  // Per-group Ed25519 private seed (32 bytes, base64-encoded), keyed by the
  // website group's tagId via this prefix (cf. [appPasswordSaltPrefix]). The
  // group's permanent IPNS name (`k51…`) is derived from the public key; this
  // seed is what lets the app re-sign IPNS record updates on every
  // regeneration. Backed up in the encrypted cloud sync so reinstalls / other
  // devices can keep updating the same name. Treated as MEDIUM sensitivity:
  // it only controls a pointer to already-public content, but a leak allows
  // repointing the user's stable link.
  static const String groupIpnsPrivKeyPrefix = 'group_ipns_priv_';

  // Optional override for the stateless front-door Worker base URL the stable
  // share link is built from (default `https://fxfiles.top/w/`). The IPNS
  // name is appended. Empty/absent -> the bundled default.
  static const String websiteLinkWorkerBaseUrl = 'website_link_worker_base_url';

  // Optional override for the IPNS publishing endpoint (default w3name at
  // `https://name.web3.storage`). The app POSTs the signed IPNS record to
  // `{endpoint}/name/{ipnsName}`. Swappable to fx's own IPNS publisher without
  // changing the (publisher-independent) IPNS name.
  static const String websiteIpnsPublishEndpoint =
      'website_ipns_publish_endpoint';

  // P13 — AI Connections. JSON array of the persisted (NON-secret) MCP pairing
  // records: each entry holds only the MCP public key, a user label, id and
  // createdAt (see AiConnection). The one-time connection bundle's SECRETS
  // (mcp_secret_b64, workspace_secret_b64, the scoped jwt) are deliberately
  // NEVER persisted — the bundle is shown once for the user to copy.
  static const String aiConnections = 'ai_connections';
}
