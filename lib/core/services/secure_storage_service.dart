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
}
