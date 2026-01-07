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
    
    const iosOptions = IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
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
}
