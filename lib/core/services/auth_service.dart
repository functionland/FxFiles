import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/encryption_service.dart';

enum AuthProvider { google, apple, microsoft }

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
const String _googleServerClientId = '407708964452-9gh602vsccdvkq6bmsj5pgf4pj94510v.apps.googleusercontent.com'; // Web Client ID - leave empty if you don't need idToken

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
  }

  Future<AuthUser?> signInWithApple() async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

      final userIdentifier = credential.userIdentifier;
      if (userIdentifier == null) return null;

      _currentUser = AuthUser(
        id: userIdentifier,
        email: credential.email ?? '',
        displayName: credential.givenName != null
            ? '${credential.givenName} ${credential.familyName ?? ''}'.trim()
            : null,
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

      return _currentUser;
    } catch (e) {
      debugPrint('Apple Sign-In error: $e');
      rethrow;
    }
  }

  Future<void> _deriveEncryptionKey() async {
    if (_currentUser == null) return;

    final combinedId = '${_currentUser!.provider.name}:${_currentUser!.id}';
    
    _encryptionKey = await EncryptionService.instance.deriveKeyFromUserId(
      combinedId,
    );

    await SecureStorageService.instance.write(
      SecureStorageKeys.encryptionKey,
      base64Encode(_encryptionKey!),
    );
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
  // ============================================================================

  Uint8List? _publicKey;
  Uint8List? _privateKey;

  Future<Uint8List?> getPublicKey() async {
    if (_publicKey != null) return _publicKey;

    final stored = await SecureStorageService.instance.read(
      SecureStorageKeys.userPublicKey,
    );

    if (stored != null) {
      _publicKey = base64Decode(stored);
      return _publicKey;
    }

    if (_currentUser != null) {
      await _generateShareKeyPair();
      return _publicKey;
    }

    return null;
  }

  Future<Uint8List?> getPrivateKey() async {
    if (_privateKey != null) return _privateKey;

    final stored = await SecureStorageService.instance.read(
      SecureStorageKeys.userPrivateKey,
    );

    if (stored != null) {
      _privateKey = base64Decode(stored);
      return _privateKey;
    }

    if (_currentUser != null) {
      await _generateShareKeyPair();
      return _privateKey;
    }

    return null;
  }

  Future<void> _generateShareKeyPair() async {
    if (_currentUser == null) return;
    
    // Derive key pair deterministically from user ID
    // Uses different salt than encryption key, so they're cryptographically isolated
    final combinedId = '${_currentUser!.provider.name}:${_currentUser!.id}';
    final keyPair = await EncryptionService.instance.deriveKeyPairFromUserId(combinedId);
    
    _publicKey = keyPair.publicKey;
    _privateKey = keyPair.privateKey;

    await SecureStorageService.instance.write(
      SecureStorageKeys.userPublicKey,
      base64Encode(_publicKey!),
    );
    await SecureStorageService.instance.write(
      SecureStorageKeys.userPrivateKey,
      base64Encode(_privateKey!),
    );
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

      _currentUser = null;
      _encryptionKey = null;
      _publicKey = null;
      _privateKey = null;
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
