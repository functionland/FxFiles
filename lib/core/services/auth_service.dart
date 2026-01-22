import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/cloud_sync_mapping_service.dart';

enum AuthProvider { google, apple }

// Google OAuth Configuration
// See: https://console.cloud.google.com/apis/credentials
//
// Required setup in Google Cloud Console:
// 1. Create an Android OAuth client with package: land.fx.files and your SHA-1
// 2. Create a Web OAuth client (for serverClientId to get idToken)
// 3. Configure OAuth consent screen
//
// Note: For Android, clientId is auto-detected from the signing config
const String _googleClientIdIOS = '1095513138272-41oj756pperrsh5aqumh3nktvankcdel.apps.googleusercontent.com'; // iOS OAuth Client ID
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
    debugPrint('AuthService: checkExistingSession called');
    try {
      final userJson = await SecureStorageService.instance.readJson(
        SecureStorageKeys.userCredentials,
      );

      debugPrint('AuthService: userJson = ${userJson != null ? "found" : "null"}');

      if (userJson != null) {
        _currentUser = AuthUser.fromJson(userJson);
        debugPrint('AuthService: Restored user: ${_currentUser!.email}');
        await _deriveEncryptionKey();
        debugPrint('AuthService: After _deriveEncryptionKey, key is ${_encryptionKey == null ? "null" : "set"}');
        await _initializeFulaClient();
        // Re-link cloud mappings for reinstall persistence (runs in background)
        if (FulaApiService.instance.isConfigured) {
          CloudSyncMappingService.instance.relinkMappings();
        }
        return true;
      }

      await _ensureGoogleInitialized();
      final result = _googleSignIn.attemptLightweightAuthentication();
      if (result != null) {
        try {
          // Add 5-second timeout to prevent hang on Android 16 (Credential Manager issue)
          final account = await result.timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              debugPrint('Google lightweight auth timed out - likely Android 16 Credential Manager issue');
              return null;
            },
          );
          if (account != null) {
            await _handleGoogleSignIn(account);
            return true;
          }
        } catch (e) {
          debugPrint('Lightweight auth failed: $e');
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
    // Re-link cloud mappings for reinstall persistence (runs in background)
    if (FulaApiService.instance.isConfigured) {
      CloudSyncMappingService.instance.relinkMappings();
    }
  }

  /// Check if Sign in with Apple is available (iOS 13+ or macOS 10.15+)
  Future<bool> get isAppleSignInAvailable async {
    if (!Platform.isIOS && !Platform.isMacOS) return false;
    return await SignInWithApple.isAvailable();
  }

  Future<AuthUser?> signInWithApple() async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

      // Apple only provides email and name on first sign-in
      // After that, we need to use stored values
      String? email = credential.email;
      String? displayName;

      if (credential.givenName != null || credential.familyName != null) {
        displayName = [credential.givenName, credential.familyName]
            .where((n) => n != null && n.isNotEmpty)
            .join(' ');
        if (displayName.isEmpty) displayName = null;
      }

      // If email is null (not first sign-in), try to get from stored user
      if (email == null) {
        final storedUser = await SecureStorageService.instance.readJson(
          SecureStorageKeys.userCredentials,
        );
        if (storedUser != null && storedUser['provider'] == 'apple') {
          email = storedUser['email'];
          displayName ??= storedUser['displayName'];
        }
      }

      // Use userIdentifier as the unique ID (stable across sign-ins)
      final userId = credential.userIdentifier;
      if (userId == null) {
        throw Exception('Apple Sign-In failed: No user identifier received');
      }

      // If still no email, use a placeholder based on user ID
      // This can happen if user chose to hide their email
      email ??= '$userId@privaterelay.appleid.com';

      await _handleAppleSignIn(
        userId: userId,
        email: email,
        displayName: displayName,
      );

      return _currentUser;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        return null; // User cancelled, not an error
      }
      debugPrint('Apple Sign-In error: ${e.code} - ${e.message}');
      throw Exception('Apple Sign-In failed: ${e.message}');
    } catch (e) {
      debugPrint('Apple Sign-In error: $e');
      rethrow;
    }
  }

  Future<void> _handleAppleSignIn({
    required String userId,
    required String email,
    String? displayName,
  }) async {
    _currentUser = AuthUser(
      id: userId,
      email: email,
      displayName: displayName,
      photoUrl: null, // Apple doesn't provide profile photos
      provider: AuthProvider.apple,
    );

    await SecureStorageService.instance.writeJson(
      SecureStorageKeys.userCredentials,
      _currentUser!.toJson(),
    );

    await SecureStorageService.instance.write(
      SecureStorageKeys.authProvider,
      AuthProvider.apple.name,
    );

    await _deriveEncryptionKey();
    await _initializeFulaClient();
    // Re-link cloud mappings for reinstall persistence (runs in background)
    if (FulaApiService.instance.isConfigured) {
      CloudSyncMappingService.instance.relinkMappings();
    }
  }

  /// Derive encryption key using Argon2id (memory-hard KDF) via fula_client
  ///
  /// Uses the standard fula.deriveKey() function to ensure cross-platform
  /// compatibility between FxFiles (Flutter) and WebUI (WASM).
  ///
  /// Argon2id parameters:
  /// - Memory: 64 MiB
  /// - Iterations: 3
  /// - Parallelism: 1
  ///
  /// Input format: "google:{userId}:{email}"
  /// Context/Salt: "fula-files-v1"
  Future<void> _deriveEncryptionKey() async {
    if (_currentUser == null) return;

    // Combined input: "google:{userId}:{email}"
    final input = '${_currentUser!.provider.name}:${_currentUser!.id}:${_currentUser!.email}';

    // Use Argon2id via fula_client for cross-platform consistency and brute-force resistance
    // This produces identical keys on Flutter (native) and WebUI (WASM)
    _encryptionKey = Uint8List.fromList(
      await fula.deriveKey(context: 'fula-files-v1', input: utf8.encode(input)),
    );

    debugPrint('AuthService: Derived key using Argon2id');
    debugPrint('  Input: "$input"');
    debugPrint('  Key first 4 bytes: ${_encryptionKey!.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');

    await SecureStorageService.instance.write(
      SecureStorageKeys.encryptionKey,
      base64Encode(_encryptionKey!),
    );
  }

  /// Initialize the fula_client with the derived encryption key
  Future<void> _initializeFulaClient() async {
    debugPrint('AuthService: _initializeFulaClient called');
    debugPrint('AuthService: _encryptionKey is ${_encryptionKey == null ? "null" : "set (${_encryptionKey!.length} bytes)"}');

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

      debugPrint('AuthService: endpoint = $endpoint');
      debugPrint('AuthService: accessToken = ${accessToken != null ? "${accessToken.substring(0, 20)}..." : "null"}');

      if (endpoint != null && endpoint.isNotEmpty) {
        await FulaApiService.instance.initialize(
          endpoint: endpoint,
          secretKey: _encryptionKey!,
          accessToken: accessToken,
        );
        debugPrint('FulaApiService initialized successfully');
        debugPrint('AuthService: FulaApiService.isConfigured = ${FulaApiService.instance.isConfigured}');

        // Debug: Print public key for comparison with WebUI
        try {
          final pubKey = await FulaApiService.instance.getPublicKey();
          debugPrint('AuthService: Public key (first 8 bytes): ${pubKey.sublist(0, 8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
          debugPrint('AuthService: Full public key (base64): ${base64Encode(pubKey)}');
        } catch (e) {
          debugPrint('AuthService: Could not get public key: $e');
        }
      } else {
        debugPrint('FulaApiService not initialized: no endpoint configured');
      }
    } catch (e, stack) {
      debugPrint('Failed to initialize FulaApiService: $e');
      debugPrint('Stack: $stack');
    }
  }

  /// Public method to reinitialize FulaApiService after settings change
  /// Call this after updating API gateway URL or JWT token
  Future<void> reinitializeFulaClient() async {
    debugPrint('AuthService: reinitializeFulaClient called');
    debugPrint('AuthService: _currentUser = ${_currentUser?.email ?? "null"}');

    // If no current user, try to restore the session first
    if (_currentUser == null) {
      debugPrint('AuthService: No current user, attempting to restore session...');
      final hasSession = await checkExistingSession();
      debugPrint('AuthService: Session restore result: $hasSession');
      // checkExistingSession already calls _initializeFulaClient if successful
      if (hasSession && FulaApiService.instance.isConfigured) {
        debugPrint('AuthService: FulaApiService already initialized via session restore');
        return;
      }
    }

    // Ensure we have an encryption key
    if (_encryptionKey == null) {
      debugPrint('AuthService: No encryption key, calling getEncryptionKey()');
      await getEncryptionKey();
      debugPrint('AuthService: After getEncryptionKey(), _encryptionKey is ${_encryptionKey == null ? "null" : "set"}');
    }
    await _initializeFulaClient();
  }

  Future<Uint8List?> getEncryptionKey() async {
    debugPrint('AuthService: getEncryptionKey called');
    if (_encryptionKey != null) {
      debugPrint('AuthService: Using cached encryption key');
      return _encryptionKey;
    }

    final stored = await SecureStorageService.instance.read(
      SecureStorageKeys.encryptionKey,
    );
    debugPrint('AuthService: Stored encryption key = ${stored != null ? "found" : "null"}');

    if (stored != null) {
      _encryptionKey = base64Decode(stored);
      return _encryptionKey;
    }

    debugPrint('AuthService: _currentUser = ${_currentUser?.email ?? "null"}');
    if (_currentUser != null) {
      await _deriveEncryptionKey();
      return _encryptionKey;
    }

    debugPrint('AuthService: Cannot get encryption key - no stored key and no current user');
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

  /// Get the encryption key as a base64 string for display/backup purposes
  Future<String?> getEncryptionKeyBase64() async {
    final key = await getEncryptionKey();
    if (key == null) return null;
    return base64Encode(key);
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

      // Clear cached sync mappings
      CloudSyncMappingService.instance.clear();

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
        try {
          // Add 5-second timeout to prevent hang on Android 16 (Credential Manager issue)
          final account = await result.timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              debugPrint('Google lightweight auth timed out in reauthenticate - likely Android 16 Credential Manager issue');
              return null;
            },
          );
          if (account != null) {
            await _handleGoogleSignIn(account);
            return true;
          }
        } catch (e) {
          debugPrint('Reauthenticate lightweight auth failed: $e');
        }
      }
      return false;
    }

    return false;
  }
}
