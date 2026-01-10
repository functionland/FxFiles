import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cryptography/cryptography.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/sync_service.dart';

enum AuthProvider { google }

// Google OAuth Configuration
// See: https://console.cloud.google.com/apis/credentials
//
// Required setup in Google Cloud Console:
// 1. Create an Android OAuth client with package: land.fx.files and your SHA-1
// 2. Create a Web OAuth client (for serverClientId to get idToken)
// 3. Configure OAuth consent screen
//
// Note: For Android, clientId is auto-detected from the signing config
const String _googleClientIdIOS = ''; // iOS OAuth Client ID
const String _googleServerClientId = '1095513138272-ctte75q6u17pjusvk9nj607qhecd03qn.apps.googleusercontent.com'; // Web Client ID - leave empty if you don't need idToken

class AuthUser {
  final String id;
  final String email;
  final String? displayName;
  final String? photoUrl;
  final AuthProvider provider;

  AuthUser({
    required this.id,
    required this.email,
    this.displayName,
    this.photoUrl,
    required this.provider,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'displayName': displayName,
    'photoUrl': photoUrl,
    'provider': provider.name,
  };

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
    id: json['id'],
    email: json['email'],
    displayName: json['displayName'],
    photoUrl: json['photoUrl'],
    provider: AuthProvider.values.firstWhere(
      (e) => e.name == json['provider'],
    ),
  );
}

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final _googleSignIn = GoogleSignIn.instance;
  bool _googleInitialized = false;

  AuthUser? _currentUser;
  Uint8List? _encryptionKey;

  AuthUser? get currentUser => _currentUser;
  bool get isAuthenticated => _currentUser != null;
  Uint8List? get encryptionKey => _encryptionKey;

  Future<void> _ensureGoogleInitialized() async {
    if (_googleInitialized) return;

    String? clientId;
    String? serverClientId;

    if (Platform.isAndroid) {
      // Android: clientId is auto-detected, only serverClientId needed for idToken
      serverClientId = _googleServerClientId.isNotEmpty ? _googleServerClientId : null;
    } else if (Platform.isIOS) {
      clientId = _googleClientIdIOS.isNotEmpty ? _googleClientIdIOS : null;
      serverClientId = _googleServerClientId.isNotEmpty ? _googleServerClientId : null;
    }

    await _googleSignIn.initialize(
      clientId: clientId,
      serverClientId: serverClientId,
    );
    _googleInitialized = true;
  }

  /// Check if Google Sign-In is properly configured
  bool get isGoogleSignInConfigured {
    if (Platform.isAndroid) {
      return _googleServerClientId.isNotEmpty;
    } else if (Platform.isIOS) {
      return _googleClientIdIOS.isNotEmpty;
    }
    return false;
  }

  Future<bool> checkExistingSession() async {
    try {
      final userJson = await SecureStorageService.instance.readJson(
        SecureStorageKeys.userCredentials,
      );

      if (userJson != null) {
        _currentUser = AuthUser.fromJson(userJson);
        await _deriveEncryptionKey();
        await _initializeFulaClient();
        return true;
      }

      await _ensureGoogleInitialized();
      final result = _googleSignIn.attemptLightweightAuthentication();
      if (result != null) {
        final account = await result;
        if (account != null) {
          await _handleGoogleSignIn(account);
          return true;
        }
      }

      return false;
    } catch (e) {
      debugPrint('Error checking existing session: $e');
      return false;
    }
  }

  Future<AuthUser?> signInWithGoogle() async {
    try {
      await _ensureGoogleInitialized();

      if (!_googleSignIn.supportsAuthenticate()) {
        debugPrint('Google Sign-In: authenticate not supported on this platform');
        throw Exception('Google Sign-In not supported on this device');
      }

      final account = await _googleSignIn.authenticate();
      await _handleGoogleSignIn(account);
      return _currentUser;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return null; // User cancelled, not an error
      }
      debugPrint('Google Sign-In error: ${e.code} - ${e.description}');
      throw Exception('Google Sign-In failed: ${e.description ?? e.code.name}');
    } catch (e) {
      debugPrint('Google Sign-In error: $e');
      // Check for common Credential Manager errors
      final errorStr = e.toString();
      if (errorStr.contains('GetCredentialResponse') || errorStr.contains('CredMan')) {
        throw Exception('Google Sign-In configuration error. Please check SHA-1 fingerprint and OAuth client IDs in Google Cloud Console.');
      }
      rethrow;
    }
  }

  Future<void> _handleGoogleSignIn(GoogleSignInAccount account) async {
    _currentUser = AuthUser(
      id: account.id,
      email: account.email,
      displayName: account.displayName,
      photoUrl: account.photoUrl,
      provider: AuthProvider.google,
    );

    await SecureStorageService.instance.writeJson(
      SecureStorageKeys.userCredentials,
      _currentUser!.toJson(),
    );

    await SecureStorageService.instance.write(
      SecureStorageKeys.authProvider,
      AuthProvider.google.name,
    );

    await _deriveEncryptionKey();
    await _initializeFulaClient();
  }

  /// Derive encryption key using PBKDF2 (same as before for compatibility)
  Future<void> _deriveEncryptionKey() async {
    if (_currentUser == null) return;

    final combinedId = '${_currentUser!.provider.name}:${_currentUser!.id}';

    // Use PBKDF2 with same parameters as before for key compatibility
    // Salt: 'fula-files-v1:{email}'
    // Iterations: 100,000
    // Output: 256 bits (32 bytes)
    final salt = 'fula-files-v1:${_currentUser!.email}';

    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );

    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(combinedId)),
      nonce: utf8.encode(salt),
    );

    _encryptionKey = Uint8List.fromList(await secretKey.extractBytes());

    await SecureStorageService.instance.write(
      SecureStorageKeys.encryptionKey,
      base64Encode(_encryptionKey!),
    );
  }

  /// Initialize the fula_client with the derived encryption key
  Future<void> _initializeFulaClient() async {
    if (_encryptionKey == null) {
      debugPrint('Cannot initialize FulaApiService: no encryption key');
      return;
    }

    try {
      // Get stored endpoint and token
      final endpoint = await SecureStorageService.instance.read(
        SecureStorageKeys.apiGatewayUrl,
      );
      final accessToken = await SecureStorageService.instance.read(
        SecureStorageKeys.jwtToken,
      );

      if (endpoint != null && endpoint.isNotEmpty) {
        await FulaApiService.instance.initialize(
          endpoint: endpoint,
          secretKey: _encryptionKey!,
          accessToken: accessToken,
        );
        debugPrint('FulaApiService initialized');
      } else {
        debugPrint('FulaApiService not initialized: no endpoint configured');
      }
    } catch (e) {
      debugPrint('Failed to initialize FulaApiService: $e');
    }
  }

  Future<Uint8List?> getEncryptionKey() async {
    if (_encryptionKey != null) return _encryptionKey;

    final stored = await SecureStorageService.instance.read(
      SecureStorageKeys.encryptionKey,
    );

    if (stored != null) {
      _encryptionKey = base64Decode(stored);
      return _encryptionKey;
    }

    if (_currentUser != null) {
      await _deriveEncryptionKey();
      return _encryptionKey;
    }

    return null;
  }

  // ============================================================================
  // KEY PAIR MANAGEMENT FOR SHARING
  // Now uses fula_client's built-in keypair
  // ============================================================================

  /// Get the user's public key for sharing
  /// This is derived from the secret key by fula_client
  Future<Uint8List?> getPublicKey() async {
    if (!FulaApiService.instance.isConfigured) {
      // Try to initialize if not configured
      await _initializeFulaClient();
    }

    if (FulaApiService.instance.isConfigured) {
      return FulaApiService.instance.getPublicKey();
    }

    // Fallback: try to load from storage (for backwards compatibility)
    final stored = await SecureStorageService.instance.read(
      SecureStorageKeys.userPublicKey,
    );
    if (stored != null) {
      return base64Decode(stored);
    }

    return null;
  }

  /// Get the user's private key for sharing
  /// With fula_client, the private key is managed internally
  /// This method is kept for backward compatibility but returns the secret key
  Future<Uint8List?> getPrivateKey() async {
    // The private key in fula_client is derived from the secret key
    // We return the secret key for backward compatibility
    return getEncryptionKey();
  }

  Future<String?> getShareId() async {
    final key = await getPublicKey();
    if (key == null) return null;
    return encodeShareId(key);
  }

  static String encodeShareId(Uint8List publicKey) {
    final encoded = base64UrlEncode(publicKey).replaceAll('=', '');
    return 'FULA-$encoded';
  }

  static Uint8List decodeShareId(String input) {
    String keyStr = input.trim();

    if (keyStr.toUpperCase().startsWith('FULA-')) {
      keyStr = keyStr.substring(5);
    }

    try {
      final padded = _addBase64Padding(keyStr);
      final standard = padded.replaceAll('-', '+').replaceAll('_', '/');
      return base64Decode(standard);
    } catch (_) {
      return base64Decode(_addBase64Padding(keyStr));
    }
  }

  static String _addBase64Padding(String input) {
    final remainder = input.length % 4;
    if (remainder == 0) return input;
    return input + '=' * (4 - remainder);
  }

  Uint8List parsePublicKey(String input) {
    return decodeShareId(input);
  }

  Future<String?> getPublicKeyString() async {
    final key = await getPublicKey();
    return key != null ? base64Encode(key) : null;
  }

  Future<void> signOut() async {
    try {
      final provider = await SecureStorageService.instance.read(
        SecureStorageKeys.authProvider,
      );

      if (provider == AuthProvider.google.name) {
        await _ensureGoogleInitialized();
        await _googleSignIn.disconnect();
      }

      await SecureStorageService.instance.delete(SecureStorageKeys.userCredentials);
      await SecureStorageService.instance.delete(SecureStorageKeys.authProvider);
      await SecureStorageService.instance.delete(SecureStorageKeys.encryptionKey);
      await SecureStorageService.instance.delete(SecureStorageKeys.userPublicKey);
      await SecureStorageService.instance.delete(SecureStorageKeys.userPrivateKey);

      // Clear API key and tokens (tied to user account)
      await SecureStorageService.instance.delete(SecureStorageKeys.jwtToken);
      await SecureStorageService.instance.delete(SecureStorageKeys.refreshToken);

      // Clear sync queues and cached data for the old user
      await SyncService.instance.clearAll();

      // Reset FulaApiService
      FulaApiService.instance.reset();

      _currentUser = null;
      _encryptionKey = null;
    } catch (e) {
      debugPrint('Sign out error: $e');
      rethrow;
    }
  }

  Future<bool> reauthenticate() async {
    final provider = await SecureStorageService.instance.read(
      SecureStorageKeys.authProvider,
    );

    if (provider == AuthProvider.google.name) {
      await _ensureGoogleInitialized();
      final result = _googleSignIn.attemptLightweightAuthentication();
      if (result != null) {
        final account = await result;
        if (account != null) {
          await _handleGoogleSignIn(account);
          return true;
        }
      }
      return false;
    }

    return false;
  }
}
