import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:fula_files/core/utils/bip39_local.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart' show ExternalLibrary;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_client/fula_client.dart' show RustLib;
import 'package:fula_files/core/services/deep_link_service.dart';
import 'package:fula_files/core/services/issuer_client.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/utils/canonical_kek_input.dart';
import 'package:fula_files/core/utils/seed_signing_input.dart';
import 'package:fula_files/core/services/dump_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/bucket_cache_service.dart';
import 'package:fula_files/core/services/cloud_sync_mapping_service.dart';
import 'package:fula_files/core/services/master_health_service.dart';
import 'package:fula_files/core/services/tag_storage_service.dart';
import 'package:fula_files/core/services/website_service.dart';
import 'package:fula_files/core/services/nft_service.dart';
import 'package:fula_files/core/services/nft_wallet_service.dart';
import 'package:fula_files/core/services/folder_watch_service.dart';
import 'package:fula_files/core/services/sharing_service.dart';
import 'package:fula_files/core/services/collaboration_service.dart';
import 'package:fula_files/core/services/collab_folder_sync_service.dart';
import 'package:fula_files/core/utils/platform_capabilities.dart';

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

  // In-flight reinit dedupe. `FulaApiService.initialize` clears the bucket
  // forest cache and rebuilds the encrypted client; if N callers race
  // (file_browser self-heal + home-screen ensureAuthRestored + face-metadata
  // sync + cloud-mapping restore, all firing concurrently right after sign-in)
  // we used to start N parallel reinits, each clearing the cache the others
  // had just populated, so every bucket reloaded N times — pinning the UI
  // and grinding the gateway. With this guard, the first caller does the
  // work; everyone else awaits its Future.
  Future<void>? _reinitializeInFlight;

  // Broadcast auth state changes so UI listening outside the main provider
  // tree (e.g. modal sheets) can react when sign-in or sign-out completes
  // — necessary because the profile sheet pops before awaiting the actual
  // sign-in, which leaves any caller awaiting the modal close with stale state.
  final StreamController<AuthUser?> _authStateController =
      StreamController<AuthUser?>.broadcast();
  Stream<AuthUser?> get authStateChanges => _authStateController.stream;

  AuthUser? get currentUser => _currentUser;
  bool get isAuthenticated => _currentUser != null;
  Uint8List? get encryptionKey => _encryptionKey;

  void _setCurrentUser(AuthUser? user) {
    _currentUser = user;
    if (!_authStateController.isClosed) {
      _authStateController.add(user);
    }
  }

  /// Quickly verify if we have stored credentials (doesn't initialize services)
  /// This is useful for UI checks when isAuthenticated might return false
  /// due to async initialization not completing
  Future<bool> hasStoredCredentials() async {
    if (_currentUser != null) return true;
    try {
      final userJson = await SecureStorageService.instance.readJson(
        SecureStorageKeys.userCredentials,
      ).timeout(const Duration(seconds: 2));
      return userJson != null;
    } catch (e) {
      debugPrint('hasStoredCredentials check failed: $e');
      return false;
    }
  }

  /// Ensure auth state is restored if we have stored credentials
  /// Call this before showing auth-dependent UI if isAuthenticated returns false
  Future<void> ensureAuthRestored() async {
    if (_currentUser != null) return;
    try {
      await checkExistingSession().timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('ensureAuthRestored failed: $e');
    }
  }

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
    } else {
      // Desktop (Windows/macOS/Linux): use server client ID for browser-based OAuth
      clientId = _googleServerClientId.isNotEmpty ? _googleServerClientId : null;
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
    // Desktop: use server client ID
    return _googleServerClientId.isNotEmpty;
  }

  Future<bool> checkExistingSession({bool skipHeavyOperations = false}) async {
    debugPrint('AuthService: checkExistingSession called');
    try {
      final userJson = await SecureStorageService.instance.readJson(
        SecureStorageKeys.userCredentials,
      );

      debugPrint('AuthService: userJson = ${userJson != null ? "found" : "null"}');

      if (userJson != null) {
        _setCurrentUser(AuthUser.fromJson(userJson));
        debugPrint('AuthService: Restored user: ${_currentUser!.email}');
        await _deriveEncryptionKey();
        debugPrint('AuthService: After _deriveEncryptionKey, key is ${_encryptionKey == null ? "null" : "set"}');
        await _initializeFulaClient();
        // Re-link cloud mappings and restore tags for reinstall persistence (runs in background)
        if (FulaApiService.instance.isConfigured && !skipHeavyOperations) {
          CloudSyncMappingService.instance.relinkMappings();
          TagStorageService.instance.restoreFromCloud();
          WebsiteService.instance.restoreFromCloud();
          NftService.instance.restoreFromCloud();
          FolderWatchService.instance.restoreFromCloud();
        }
        return true;
      }

      // No stored session. Do NOT attempt Google's lightweight/silent auth here:
      // google_sign_in 7.x routes that through Android Credential Manager, which
      // pops the "Choose an account for FxFiles" picker even on first launch —
      // before the user has accepted ToS or chosen a sign-up mode. Sign-in must
      // be initiated explicitly from the onboarding chooser (Mode A/B/C).
      return false;
    } catch (e) {
      debugPrint('Error checking existing session: $e');
      return false;
    }
  }

  Future<AuthUser?> signInWithGoogle() async {
    try {
      if (PlatformCapabilities.isDesktop) {
        throw Exception('Google Sign-In is not available on desktop. Please use "Get API Key" to connect your account.');
      }

      await _ensureGoogleInitialized();

      if (!_googleSignIn.supportsAuthenticate()) {
        debugPrint('Google Sign-In: authenticate not supported on this platform');
        throw Exception('Google Sign-In not supported on this device');
      }

      final account = await _googleSignIn.authenticate();
      // v7 of google_sign_in exposes the OIDC ID token via the
      // synchronous `authentication` getter. We need it to exchange
      // for a JWT from /auth/google so the user can use the cloud
      // gateway in-app without bouncing through the browser /get-key
      // flow. `idToken` may still be null on devices where the SDK
      // can't reach Google's auth server; the helper tolerates that
      // and the legacy browser fallback can kick in via the setup
      // sheet's "Connect cloud storage" step.
      final idToken = account.authentication.idToken;
      await _handleGoogleSignIn(account, idToken: idToken);
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

  Future<void> _handleGoogleSignIn(
    GoogleSignInAccount account, {
    String? idToken,
  }) async {
    _setCurrentUser(AuthUser(
      id: account.id,
      email: account.email,
      displayName: account.displayName,
      photoUrl: account.photoUrl,
      provider: AuthProvider.google,
    ));

    await SecureStorageService.instance.writeJson(
      SecureStorageKeys.userCredentials,
      _currentUser!.toJson(),
    );

    await SecureStorageService.instance.write(
      SecureStorageKeys.authProvider,
      AuthProvider.google.name,
    );

    // Clear the explicit-sign-out sentinel — the user is interactively signing
    // back in, so silent re-auth on subsequent launches is desired again.
    await SecureStorageService.instance.delete(SecureStorageKeys.authSignedOut);

    // Exchange the OIDC ID token for a JWT-bearer API key in-app. The
    // pinning-service `/auth/google` endpoint mints a JWT via the same
    // `generateJwtApiKey(userId, jwtSecret)` helper that `/api/keys`
    // uses, so the result is a valid cloud-gateway credential. We
    // persist it BEFORE `_initializeFulaClient` runs so the latter
    // sees a configured access token on first sign-in (previously
    // null on Mode A mobile until the browser /get-key dance ran).
    if (idToken != null && idToken.isNotEmpty) {
      final jwt = await _exchangeOAuthIdTokenForJwt(
        path: '/auth/google',
        body: {'credential': idToken},
      );
      if (jwt != null && jwt.isNotEmpty) {
        await SecureStorageService.instance
            .write(SecureStorageKeys.jwtToken, jwt);
        // Await so the gateway/IPFS endpoint defaults are persisted BEFORE
        // _initializeFulaClient reads them below.
        await DeepLinkService.instance.notifyApiKeyConfigured(jwt);
      }
    }

    // Encryption key derivation and Fula client initialization depend on RustLib
    // If these fail (e.g., RustLib not initialized), sign-in still succeeds
    // but cloud sync features won't work until app is restarted with proper RustLib init
    try {
      await _deriveEncryptionKey();
      await _initializeFulaClient();
      // Re-link cloud mappings and restore tags for reinstall persistence (runs in background)
      if (FulaApiService.instance.isConfigured) {
        CloudSyncMappingService.instance.relinkMappings();
        TagStorageService.instance.restoreFromCloud();
        WebsiteService.instance.restoreFromCloud();
        NftService.instance.restoreFromCloud();
        FolderWatchService.instance.restoreFromCloud();
      }
    } catch (e) {
      debugPrint('Google Sign-In: Fula initialization failed (sign-in still succeeded): $e');
      // Sign-in succeeded, but Fula features won't work until RustLib is properly initialized
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
        identityToken: credential.identityToken,
        // Apple's `givenName`/`familyName` only populate on the user's
        // FIRST consent screen for the app. We forward them so the
        // server-side first-time-signup path can record the user's
        // real name on `webui_users` instead of leaving it blank.
        firstName: credential.givenName,
        lastName: credential.familyName,
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
    String? identityToken,
    String? firstName,
    String? lastName,
  }) async {
    _setCurrentUser(AuthUser(
      id: userId,
      email: email,
      displayName: displayName,
      photoUrl: null, // Apple doesn't provide profile photos
      provider: AuthProvider.apple,
    ));

    await SecureStorageService.instance.writeJson(
      SecureStorageKeys.userCredentials,
      _currentUser!.toJson(),
    );

    await SecureStorageService.instance.write(
      SecureStorageKeys.authProvider,
      AuthProvider.apple.name,
    );

    // Clear the explicit-sign-out sentinel — the user is interactively signing
    // back in, so silent re-auth on subsequent launches is desired again.
    await SecureStorageService.instance.delete(SecureStorageKeys.authSignedOut);

    // Exchange the Apple identity token for a JWT in-app, mirroring
    // the Google path. The body forwards `user.email` / `user.name`
    // only on first sign-in (when Apple provides them); the server
    // tolerates them being absent on subsequent calls.
    if (identityToken != null && identityToken.isNotEmpty) {
      final body = <String, dynamic>{'identityToken': identityToken};
      final firstSignInUser = <String, dynamic>{};
      if (email.isNotEmpty && !email.endsWith('@privaterelay.appleid.com')) {
        firstSignInUser['email'] = email;
      }
      if ((firstName != null && firstName.isNotEmpty) ||
          (lastName != null && lastName.isNotEmpty)) {
        firstSignInUser['name'] = <String, dynamic>{
          if (firstName != null && firstName.isNotEmpty) 'firstName': firstName,
          if (lastName != null && lastName.isNotEmpty) 'lastName': lastName,
        };
      }
      if (firstSignInUser.isNotEmpty) {
        body['user'] = firstSignInUser;
      }
      final jwt = await _exchangeOAuthIdTokenForJwt(
        path: '/auth/apple',
        body: body,
      );
      if (jwt != null && jwt.isNotEmpty) {
        await SecureStorageService.instance
            .write(SecureStorageKeys.jwtToken, jwt);
        // Await so the gateway/IPFS endpoint defaults are persisted BEFORE
        // _initializeFulaClient reads them below.
        await DeepLinkService.instance.notifyApiKeyConfigured(jwt);
      }
    }

    // Encryption key derivation and Fula client initialization depend on RustLib
    // If these fail (e.g., RustLib not initialized), sign-in still succeeds
    // but cloud sync features won't work until app is restarted with proper RustLib init
    try {
      await _deriveEncryptionKey();
      await _initializeFulaClient();
      // Re-link cloud mappings and restore tags for reinstall persistence (runs in background)
      if (FulaApiService.instance.isConfigured) {
        CloudSyncMappingService.instance.relinkMappings();
        TagStorageService.instance.restoreFromCloud();
        WebsiteService.instance.restoreFromCloud();
        NftService.instance.restoreFromCloud();
        FolderWatchService.instance.restoreFromCloud();
      }
    } catch (e) {
      debugPrint('Apple Sign-In: Fula initialization failed (sign-in still succeeded): $e');
      // Sign-in succeeded, but Fula features won't work until RustLib is properly initialized
    }
  }

  /// Handle sign-in via browser callback (Get API Key flow).
  /// Creates a user session from identity params passed in the redirect URL.
  Future<void> handleBrowserSignIn({
    required String id,
    required String email,
    String? displayName,
    String? photoUrl,
    required AuthProvider provider,
  }) async {
    _setCurrentUser(AuthUser(
      id: id,
      email: email,
      displayName: displayName,
      photoUrl: photoUrl,
      provider: provider,
    ));

    await SecureStorageService.instance.writeJson(
      SecureStorageKeys.userCredentials,
      _currentUser!.toJson(),
    );

    await SecureStorageService.instance.write(
      SecureStorageKeys.authProvider,
      provider.name,
    );

    // Clear the explicit-sign-out sentinel — the user is interactively signing
    // back in, so silent re-auth on subsequent launches is desired again.
    await SecureStorageService.instance.delete(SecureStorageKeys.authSignedOut);

    try {
      await _deriveEncryptionKey();
      await _initializeFulaClient();
      if (FulaApiService.instance.isConfigured) {
        CloudSyncMappingService.instance.relinkMappings();
        TagStorageService.instance.restoreFromCloud();
        WebsiteService.instance.restoreFromCloud();
        FolderWatchService.instance.restoreFromCloud();
      }
    } catch (e) {
      debugPrint('Browser sign-in post-setup error: $e');
    }
  }

  /// Track whether RustLib has been successfully initialized.
  /// Set to true in main.dart after successful init, or by lazy init here.
  static bool _rustLibInitialized = false;

  /// Mark RustLib as initialized (called from main.dart after successful init)
  static void markRustLibInitialized() => _rustLibInitialized = true;

  /// Ensure RustLib (flutter_rust_bridge) is initialized.
  /// RustLib.init() may fail at startup (e.g. timeout, linking issues) but succeed
  /// on retry. This method allows lazy re-initialization before any fula_client call.
  static Future<void> ensureRustLibInitialized() async {
    if (_rustLibInitialized) return;

    debugPrint('AuthService: RustLib not initialized, attempting lazy init...');
    try {
      if (Platform.isIOS) {
        await RustLib.init(
          externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
        );
      } else {
        await RustLib.init();
      }
      _rustLibInitialized = true;
      debugPrint('AuthService: RustLib initialized successfully on retry');
    } catch (e) {
      debugPrint('AuthService: RustLib init retry failed: $e');
      rethrow;
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

    // Ensure RustLib is initialized (may have failed at startup)
    await ensureRustLibInitialized();

    // Pin the email used for key derivation so Apple email drift doesn't
    // change the derived key on a new device (Apple may return null or a
    // different relay address after the first sign-in).
    String email;
    final storedEmail = await SecureStorageService.instance.read(
      SecureStorageKeys.derivationEmail,
    );
    if (storedEmail != null && storedEmail.isNotEmpty) {
      email = storedEmail;
    } else {
      email = _currentUser!.email;
      await SecureStorageService.instance.write(
        SecureStorageKeys.derivationEmail,
        email,
      );
    }

    // Combined input: "google:{userId}:{email}"
    final input = '${_currentUser!.provider.name}:${_currentUser!.id}:$email';

    // Use Argon2id via fula_client for cross-platform consistency and brute-force resistance
    // This produces identical keys on Flutter (native) and WebUI (WASM)
    _encryptionKey = Uint8List.fromList(
      await fula.deriveKey(context: 'fula-files-v1', input: utf8.encode(input)),
    );

    debugPrint('AuthService: Derived encryption key via Argon2id');

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

    // When the encryption key was loaded from SecureStorage (cached path),
    // _deriveEncryptionKey — the usual RustLib bootstrap site — is skipped.
    // Ensure RustLib is ready before any fula_client call.
    await ensureRustLibInitialized();

    try {
      // Get stored endpoint and token
      var endpoint = await SecureStorageService.instance.read(
        SecureStorageKeys.apiGatewayUrl,
      );
      final accessToken = await SecureStorageService.instance.read(
        SecureStorageKeys.jwtToken,
      );

      // Migration for users who signed in under the pre-fix in-app flow:
      // the JWT was persisted but the gateway/IPFS endpoint defaults
      // were never written, so this method used to bail with
      // "endpoint configured = false" on every cold launch even though
      // the user was authenticated. Seed the deep-link defaults here so
      // a single re-launch repairs the state without a sign-out.
      if ((endpoint == null || endpoint.isEmpty) &&
          accessToken != null &&
          accessToken.isNotEmpty) {
        debugPrint('AuthService: JWT present but endpoint missing — '
            'seeding default gateway/IPFS URLs');
        await DeepLinkService.instance.notifyApiKeyConfigured(accessToken);
        endpoint = await SecureStorageService.instance.read(
          SecureStorageKeys.apiGatewayUrl,
        );
      }

      debugPrint('AuthService: endpoint configured = ${endpoint != null && endpoint.isNotEmpty}');
      debugPrint('AuthService: accessToken present = ${accessToken != null && accessToken.isNotEmpty}');

      if (endpoint != null && endpoint.isNotEmpty) {
        // Read the pinned derivation email — same value used by
        // _deriveEncryptionKey above, persisted at first sign-in. The
        // FulaApiService uses it (when set) to derive a per-user
        // cold-start key so the on-chain registry resolver can locate
        // this user's anchor.
        final derivationEmail = await SecureStorageService.instance.read(
          SecureStorageKeys.derivationEmail,
        );

        // User-editable cold-start resolver overrides (Settings > Fula API
        // Configuration). Empty/null values fall back to the build-in
        // defaults inside FulaApiService.initialize.
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
        final usersIndexIpnsGateways = usersIndexIpnsGatewayRaw == null
            ? null
            : usersIndexIpnsGatewayRaw
                .split(RegExp(r'[\n,]'))
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList(growable: false);

        // E2E plan Phase 5 — derive K_index + K_entry_seed for Mode
        // B/C users so the fula-client SDK can encrypt + sign the
        // per-user bucketsIndex envelope. Mode A users skip this:
        // their KEK is derivable from public OAuth attributes so
        // encrypting under it would not be privacy-preserving — the
        // SDK falls back to today's legacy `users[]` plaintext path
        // when these keys are absent.
        Uint8List? bucketsIndexKey;
        Uint8List? userEntrySigningSeed;
        final modeVersion = await SecureStorageService.instance.read(
          SecureStorageKeys.keyDerivationVersion,
        );
        final isModeBC = modeVersion != null &&
            (modeVersion.contains('mode_B') || modeVersion.contains('mode_C'));
        if (isModeBC) {
          try {
            bucketsIndexKey = Uint8List.fromList(
              await fula.blake3DeriveKey(
                context: 'fula:user-buckets-index:v1',
                input: _encryptionKey!,
              ),
            );
            userEntrySigningSeed = Uint8List.fromList(
              await fula.blake3DeriveKey(
                context: 'fula:user-entry-signing:v1',
                input: _encryptionKey!,
              ),
            );
            // Persist for fast re-load on next cold start. Same pattern
            // as encryptionKey above.
            await SecureStorageService.instance.write(
              SecureStorageKeys.bucketsIndexKey,
              base64Encode(bucketsIndexKey),
            );
            await SecureStorageService.instance.write(
              SecureStorageKeys.userEntrySigningSeed,
              base64Encode(userEntrySigningSeed),
            );
            debugPrint('AuthService: derived K_index + K_entry_seed for Mode B/C user');
          } catch (e) {
            debugPrint('AuthService: blake3DeriveKey failed: $e; '
                'falling back to legacy users[] path');
            bucketsIndexKey = null;
            userEntrySigningSeed = null;
          }
        }

        await FulaApiService.instance.initialize(
          endpoint: endpoint,
          secretKey: _encryptionKey!,
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
        debugPrint('AuthService: FulaApiService.isConfigured = ${FulaApiService.instance.isConfigured}');

        // Start polling the SDK's Phase 19 health channel so the UI can
        // render an offline banner when the master gateway goes down.
        // No-op if already started (re-init via settings save just keeps
        // the existing poller alive against the new client handle).
        unawaited(MasterHealthService.instance.start());

        // Dump feature (R10 / Session 5): pending-auth retry hook —
        // every time the encryption key + Fula client become
        // available we ask DumpService to re-run any items the user
        // staged while signed out. Idempotent + key-gated, so it's
        // safe to call from every _initializeFulaClient site (cold
        // restore, new sign-in, gateway switch, reinit).
        unawaited(DumpService.instance.retryPending());

        // Verify public key is available (don't log key material)
        try {
          await FulaApiService.instance.getPublicKey();
          debugPrint('AuthService: Public key available');
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
    // Fast path: already configured. Nothing to do, no work to dedupe.
    if (FulaApiService.instance.isConfigured) return;

    // Dedupe concurrent callers — the work below is expensive (Argon2id
    // derivation + full FulaApiService.initialize, which clears the bucket
    // forest cache) and is destructive when run in parallel.
    final inflight = _reinitializeInFlight;
    if (inflight != null) return inflight;

    final future = _doReinitializeFulaClient();
    _reinitializeInFlight = future;
    try {
      await future;
    } finally {
      _reinitializeInFlight = null;
    }
  }

  Future<void> _doReinitializeFulaClient() async {
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

    // Restore cloud data after Fula client is configured
    if (FulaApiService.instance.isConfigured) {
      debugPrint('AuthService: Restoring cloud data after reinitialize...');
      CloudSyncMappingService.instance.relinkMappings();
      TagStorageService.instance.restoreFromCloud();
      WebsiteService.instance.restoreFromCloud();
      NftService.instance.restoreFromCloud();
      FolderWatchService.instance.restoreFromCloud();
    }
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

  /// Mode-aware view of the inputs that produced the current session's
  /// master key, PLUS the public cold-start `usersIndexUserKey` (32 hex
  /// chars) the resolver uses to locate this user's bucket-set in the
  /// on-chain users-index CBOR.
  ///
  /// Per-mode shape:
  /// - Mode A (legacy OAuth): `provider`, `oauthSub`, `email` are the
  ///   three Argon2id inputs to `_deriveEncryptionKey`; `effectiveUserId`
  ///   is null.
  /// - Mode B (OAuth + seed): the actual derivation input is
  ///   `(provider, oauth_sub, NFKC(seed))`. `_currentUser.id` is the
  ///   seed-derived `effectiveUserIdHex`, NOT the OAuth sub — so read
  ///   the real OAuth sub from `SecureStorageKeys.modeOauthSub` (and
  ///   provider from `modeOauthProvider`) where the sign-in flow
  ///   persisted them. `email` is returned for diagnostic context but
  ///   is not part of the derivation. The seed itself is never
  ///   persisted; the UI marks it redacted.
  /// - Mode C (seed only): the derivation input is `NFKC(seed)`. No
  ///   provider, no oauth_sub. Email on `_currentUser` is a synthetic
  ///   `<effectiveUserIdHex>@seed.fxfiles.local` placeholder and is
  ///   not returned (would mislead).
  ///
  /// `usersIndexUserKey` is `BLAKE3("fula:user_id:" || jwt_sub)[..16]`
  /// hex-encoded. Because the JWT `sub` is mode-aware (Mode A:
  /// oauth_sub; Mode B/C: hex(effective_user_id)), this single
  /// derivation works across all three modes without per-mode
  /// branching. It is the SAME value [`FulaApiService.initialize`]
  /// passes as `usersIndexUserKey` in `FulaConfig`. Falls back to the
  /// email-keyed derivation (Mode A only — Mode B/C synthesise emails
  /// so the fallback wouldn't match master) when the JWT can't be read.
  ///
  /// Surfaced in Settings → Security so an operator can reproduce the
  /// derivation outside the app for diagnostics. Returns no secret
  /// material — Mode A `oauthSub`, Mode B `oauthSub` (read from
  /// SecureStorage), `effectiveUserId`, and `usersIndexUserKey` are
  /// all non-confidential.
  Future<({
    String mode,
    String? provider,
    String? oauthSub,
    String? effectiveUserId,
    String? email,
    String? usersIndexUserKey,
  })?> getDerivationInputs() async {
    if (_currentUser == null) return null;

    final modeVersion = await SecureStorageService.instance.read(
      SecureStorageKeys.keyDerivationVersion,
    );
    // Legacy users (signed in before the F-A1 redesign) have no stored
    // version → treat as Mode A.
    final mode = (modeVersion != null && modeVersion.contains('mode_B'))
        ? 'B'
        : (modeVersion != null && modeVersion.contains('mode_C'))
            ? 'C'
            : 'A';

    String? usersIndexUserKey;
    try {
      final jwt = await SecureStorageService.instance.read(
        SecureStorageKeys.jwtToken,
      );
      final jwtSub = _extractJwtSubLocal(jwt);
      if (jwtSub != null && jwtSub.isNotEmpty) {
        usersIndexUserKey =
            await fula.deriveUserKeyFromJwtSub(jwtSub: jwtSub);
      }
    } catch (e) {
      debugPrint('AuthService.getDerivationInputs: JWT-sub deriveUserKey failed: $e');
    }

    if (mode == 'A') {
      final pinned = await SecureStorageService.instance.read(
        SecureStorageKeys.derivationEmail,
      );
      final email = (pinned != null && pinned.isNotEmpty)
          ? pinned
          : _currentUser!.email;

      // Email-keyed fallback only makes sense for Mode A: master keys
      // Mode A users by email-hash. Mode B/C key by the seed-derived
      // sub, so an email lookup would never match.
      if (usersIndexUserKey == null || usersIndexUserKey.isEmpty) {
        try {
          usersIndexUserKey = await fula.deriveUserKeyFromEmail(email: email);
        } catch (e) {
          debugPrint('AuthService.getDerivationInputs: email deriveUserKey failed: $e');
          usersIndexUserKey = null;
        }
      }

      return (
        mode: 'A',
        provider: _currentUser!.provider.name,
        oauthSub: _currentUser!.id,
        effectiveUserId: null,
        email: email,
        usersIndexUserKey: usersIndexUserKey,
      );
    }

    if (mode == 'B') {
      // The OAuth identity used at Mode B sign-up — persisted by
      // `_persistSeedAuthSession` so subsequent sign-ins on the same
      // device can re-derive the effective_user_id without re-running
      // OAuth.
      final provider = await SecureStorageService.instance.read(
        SecureStorageKeys.modeOauthProvider,
      );
      final oauthSub = await SecureStorageService.instance.read(
        SecureStorageKeys.modeOauthSub,
      );
      final pinned = await SecureStorageService.instance.read(
        SecureStorageKeys.derivationEmail,
      );
      return (
        mode: 'B',
        provider: provider ?? _currentUser!.provider.name,
        oauthSub: oauthSub,
        effectiveUserId: _currentUser!.id,
        email: (pinned != null && pinned.isNotEmpty)
            ? pinned
            : _currentUser!.email,
        usersIndexUserKey: usersIndexUserKey,
      );
    }

    return (
      mode: 'C',
      provider: null,
      oauthSub: null,
      effectiveUserId: _currentUser!.id,
      email: null,
      usersIndexUserKey: usersIndexUserKey,
    );
  }

  /// Local copy of the JWT-payload `sub` extractor (mirror of
  /// `FulaApiService._extractJwtSub`). Kept private here to avoid a
  /// dependency loop between `AuthService` and `FulaApiService`.
  static String? _extractJwtSubLocal(String? jwt) {
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

  String? _cachedShareId;

  Future<String?> getShareId() async {
    if (_cachedShareId != null) return _cachedShareId;
    final key = await getPublicKey();
    if (key == null) return null;
    _cachedShareId = encodeShareId(key);
    return _cachedShareId;
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

  // ==========================================================================
  // Mode B / Mode C — seed-as-identity sign-in (audit F-A1 / F-A3 redesign).
  //
  // The seed never leaves the device. We derive locally:
  //  - `effective_user_id` (16 bytes, becomes the JWT `sub`) via Rust FFI.
  //  - An Ed25519 signing keypair via Rust FFI seed + the `cryptography`
  //    package's Ed25519 implementation.
  //  - The master encryption key via the existing Argon2id FFI with a
  //    Mode-tagged context.
  //
  // The signing keypair authenticates against the issuer (pinning-service)
  // via proof-of-seed-knowledge — see server endpoints
  // `/auth/register-mode-{b,c}` and `/auth/sign-in`.
  //
  // **Mode A (legacy) is unchanged.** `signInWithGoogle` / `signInWithApple`
  // and their `_handleGoogle/AppleSignIn` callbacks continue to call
  // `_deriveEncryptionKey()` with the v1 KDF. Existing users keep working.
  // ==========================================================================

  /// Generate a fresh 24-word BIP39 recovery mnemonic (256-bit entropy).
  /// Used at Mode C sign-up so the user has a recoverable backup.
  /// The returned string is the canonical space-separated word list.
  /// Byte-compatible with any BIP39 wallet — the mnemonic can be
  /// imported into other BIP39-aware tools and vice versa.
  Future<String> generateRecoveryMnemonic() {
    return generateBip39Mnemonic(strength: 256);
  }

  /// True iff `mnemonic` is a valid BIP39 phrase (correct word count,
  /// dictionary words, checksum). Used on the recovery / sign-in path
  /// to give the user immediate feedback before we hit the issuer.
  Future<bool> isValidMnemonic(String mnemonic) {
    return validateBip39Mnemonic(mnemonic.trim());
  }

  /// Resolve the issuer base URL (the pinning-service that mints JWTs).
  /// Pulled from SecureStorage if the user customized it; otherwise the
  /// default `https://cloud.fx.land`.
  Future<String> _issuerBaseUrl() async {
    final stored = await SecureStorageService.instance.read(
      SecureStorageKeys.billingServerUrl,
    );
    if (stored != null && stored.isNotEmpty) return stored;
    return 'https://cloud.fx.land';
  }

  /// Mode A in-app JWT-bearer fetch: POST the OAuth ID token to the
  /// pinning-service `/auth/google` or `/auth/apple` endpoint and read
  /// the minted JWT from the response. Returns `null` on any transport
  /// or non-2xx error — sign-in still succeeds with the local-only
  /// encryption key, and the legacy browser /get-key fallback in the
  /// setup sheet remains available.
  ///
  /// Without this helper, Mode A on mobile relied on a browser round-trip
  /// to fetch the cloud-gateway JWT (the `/get-key` deep-link dance).
  /// Mode B/C never needed it because their `/auth/register-mode-{b,c}`
  /// endpoints return the JWT directly.
  Future<String?> _exchangeOAuthIdTokenForJwt({
    required String path,
    required Map<String, dynamic> body,
  }) async {
    try {
      final baseUrl = await _issuerBaseUrl();
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
            'AuthService: $path returned 2xx but no jwt field — server may need updating');
        return null;
      }
      debugPrint(
          'AuthService: $path failed ${res.statusCode}: ${res.body}');
      return null;
    } catch (e) {
      debugPrint('AuthService: $path exchange error: $e');
      return null;
    }
  }

  /// Build the byte sequence the client signs with its seed-derived
  /// Ed25519 private key. MUST match exactly what the issuer
  /// reconstructs in `pinning-service/server/services/seedAuth.ts`'s
  /// `buildSignedTranscript`.
  ///
  /// Layout:
  ///   "fula.seed-auth.v1\0" || purpose || 0x00 ||
  ///   effective_user_id_hex_ascii || 0x00 || challenge
  Uint8List _buildSignedTranscript(
    String purpose,
    String effectiveUserIdHex,
    Uint8List challenge,
  ) {
    final out = BytesBuilder();
    out.add(utf8.encode('fula.seed-auth.v1 '));
    out.add(utf8.encode(purpose));
    out.add([0]);
    out.add(ascii.encode(effectiveUserIdHex));
    out.add([0]);
    out.add(challenge);
    return out.toBytes();
  }

  /// Derive the Ed25519 signing keypair from the user's seed.
  /// Pure deterministic: same seed → same keypair on any device.
  Future<SimpleKeyPair> _deriveSigningKeypair(String seed) async {
    await ensureRustLibInitialized();
    // The FFI handles NFKC + domain-separation; we just consume the
    // 32-byte signing seed it returns.
    final signingSeed = await fula.deriveSigningSeed(seed: seed);
    final algorithm = Ed25519();
    return algorithm.newKeyPairFromSeed(signingSeed);
  }

  /// 16-byte effective_user_id (hex) for Mode B users.
  Future<String> _computeEffectiveUserIdModeB({
    required String provider,
    required String oauthSub,
    required String seed,
  }) async {
    await ensureRustLibInitialized();
    final bytes = await fula.computeEffectiveUserIdModeB(
      provider: provider,
      oauthSub: oauthSub,
      seed: seed,
    );
    return _toHex(bytes);
  }

  /// 16-byte effective_user_id (hex) for Mode C users.
  Future<String> _computeEffectiveUserIdModeC(String seed) async {
    await ensureRustLibInitialized();
    final bytes = await fula.computeEffectiveUserIdModeC(seed: seed);
    return _toHex(bytes);
  }

  String _toHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Mode B sign-in / sign-up (idempotent at the issuer): user supplies
  /// `(provider, oauthToken, sub, email, password)`. The seed is the
  /// password; never persisted to disk.
  ///
  /// On success: persists `keyDerivationVersion=2_mode_B`,
  /// `effectiveUserIdHex`, `modeOauthProvider`, `modeOauthSub`,
  /// `jwtToken`, `encryptionKey` and sets `_currentUser`. Mode A users
  /// are unaffected (this is an additive code path).
  ///
  /// Throws `IssuerException` (with `code` = `PUBLIC_KEY_MISMATCH`,
  /// `SIGNATURE_INVALID`, etc.) on failure.
  Future<({AuthUser user, bool hasModeA})> signInModeB({
    required String provider, // 'google' or 'apple'
    required String oauthToken,
    required String oauthSub,
    required String email,
    required String displayName,
    String? photoUrl,
    required String password,
  }) async {
    if (password.isEmpty) {
      throw ArgumentError('Mode B password must not be empty');
    }

    // 1. Derive identity locally.
    final effectiveUserIdHex = await _computeEffectiveUserIdModeB(
      provider: provider,
      oauthSub: oauthSub,
      seed: password,
    );
    // Audit fix #3 (2026-05-18): bind the Mode B signing key to the full
    // (provider, oauth_sub, password) tuple, not just the password.
    // Without this, two Mode B users with the same password under
    // different OAuth identities would share an Ed25519 keypair —
    // either could sign in to the other's vault by reading the
    // effective_user_id from the public users-index CBOR.
    final keyPair = await _deriveSigningKeypair(
      modeBSigningInput(provider, oauthSub, password),
    );
    final pubKey = await keyPair.extractPublicKey();

    // 2. Fetch a server-issued single-use challenge for register-mode-b.
    //    Audit finding #1 (2026-05-18): the server requires a fresh
    //    server-issued nonce to defeat capture-and-replay of registration
    //    bodies. JWTs we mint have no `exp` (DT-1) so a replay would
    //    otherwise produce a perpetually-valid token.
    final issuer = IssuerClient(baseUrl: await _issuerBaseUrl());
    final challenge =
        await issuer.challenge(effectiveUserIdHex, purpose: 'register-mode-b');

    // 3. Sign the register-mode-b transcript over the server's challenge.
    final transcript = _buildSignedTranscript(
      'register-mode-b',
      effectiveUserIdHex,
      challenge,
    );
    final signature = await Ed25519().sign(transcript, keyPair: keyPair);

    // 4. POST register-mode-b. The server re-consumes the same nonce
    //    from its store and verifies the signature; replay returns 401
    //    CHALLENGE_INVALID.
    final result = await issuer.registerModeB(
      provider: provider,
      oauthToken: oauthToken,
      effectiveUserIdHex: effectiveUserIdHex,
      publicKey: Uint8List.fromList(pubKey.bytes),
      challenge: challenge,
      signature: Uint8List.fromList(signature.bytes),
    );

    // 4. Derive the master encryption key (Argon2id, Mode B context).
    final kekInput = canonicalKekInputModeB(provider, oauthSub, password);
    final kekBytes = await fula.deriveKey(
      context: 'fula-files-v2-mode-b',
      input: kekInput,
    );

    // 5. Persist the new session.
    await _persistSeedAuthSession(
      result: result,
      kek: kekBytes,
      provider: provider,
      oauthSub: oauthSub,
      email: email,
      displayName: displayName,
      photoUrl: photoUrl,
    );

    // Audit fix #4: surface `has_mode_a` so the UI can warn the user
    // that their new Mode B vault is separate from any existing Mode A
    // account on the same Google/Apple identity. `false` is the safe
    // default when the issuer can't determine it (e.g., Apple's
    // private-relay flow that doesn't return email after first
    // sign-in).
    return (user: _currentUser!, hasModeA: result.hasModeA ?? false);
  }

  /// Mode C sign-in / sign-up (idempotent at the issuer). No OAuth.
  /// The user supplies the seed (typically a 24-word BIP39 mnemonic).
  /// Two callers with the same seed reach the same vault — that is
  /// the "seed IS the user" design.
  Future<AuthUser> signInModeC({
    required String seed,
    String? displayName,
  }) async {
    if (seed.trim().isEmpty) {
      throw ArgumentError('Mode C seed must not be empty');
    }

    final effectiveUserIdHex = await _computeEffectiveUserIdModeC(seed);
    final keyPair = await _deriveSigningKeypair(seed);
    final pubKey = await keyPair.extractPublicKey();

    // Audit finding #1 fix — server-issued single-use challenge before
    // registration. See the matching block in `signInModeB` for rationale.
    final issuer = IssuerClient(baseUrl: await _issuerBaseUrl());
    final challenge =
        await issuer.challenge(effectiveUserIdHex, purpose: 'register-mode-c');

    final transcript = _buildSignedTranscript(
      'register-mode-c',
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

    // Master KEK from the seed. Mode C context.
    final kekInput = canonicalKekInputModeC(seed);
    final kekBytes = await fula.deriveKey(
      context: 'fula-files-v2-mode-c',
      input: kekInput,
    );

    // Mode C has no OAuth identity; persist with synthetic fields.
    await _persistSeedAuthSession(
      result: result,
      kek: kekBytes,
      provider: null,
      oauthSub: null,
      email: '$effectiveUserIdHex@seed.fxfiles.local',
      displayName: displayName ?? 'Passphrase Vault',
      photoUrl: null,
    );

    return _currentUser!;
  }

  /// Persist the seed-auth session state. Sets `_currentUser`, caches
  /// the master KEK in SecureStorage, stores the JWT, persists the
  /// mode flag.
  Future<void> _persistSeedAuthSession({
    required SeedAuthResult result,
    required List<int> kek,
    required String? provider,
    required String? oauthSub,
    required String email,
    required String displayName,
    String? photoUrl,
  }) async {
    final modeTag = result.mode == SeedAuthMode.b ? '2_mode_B' : '2_mode_C';

    // SecureStorage writes.
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
    // Tell home_screen / setup_unlock_sheet that the JWT is now in
    // place so they auto-complete the "Connect cloud storage" step
    // instead of pushing the user through a now-redundant browser
    // /get-key dance (which ends with a "switch account?" prompt
    // because that JWT differs in `jti` from the one written above).
    // Mode B/C JWTs are already valid storage-gateway API keys — the
    // server signs both `/auth/register-mode-{b,c}` and
    // `/api/keys/active` outputs with the same secret + sub.
    // Await so the gateway/IPFS endpoint defaults are seeded BEFORE the
    // subsequent _initializeFulaClient call reads them; without this, the
    // app stays authenticated-but-offline ("endpoint configured = false").
    await DeepLinkService.instance.notifyApiKeyConfigured(result.jwt);
    await SecureStorageService.instance.write(
      SecureStorageKeys.encryptionKey,
      base64Encode(kek),
    );
    await SecureStorageService.instance.write(
      SecureStorageKeys.derivationEmail,
      email,
    );

    // Update in-memory user.
    _setCurrentUser(AuthUser(
      // The `id` field is the JWT sub for routing the gateway's
      // namespace lookups; matches what fula-cli sees as `claims.sub`.
      id: result.effectiveUserIdHex,
      email: email,
      displayName: displayName,
      photoUrl: photoUrl,
      // The `provider` enum still distinguishes Google vs Apple for
      // Mode B users; Mode C clients are reported as Google for
      // backward compat with existing AuthUser consumers (they never
      // see an OAuth identity anyway). Refine later if the UI needs
      // to distinguish vault types.
      provider: provider == 'apple' ? AuthProvider.apple : AuthProvider.google,
    ));
    await SecureStorageService.instance.writeJson(
      SecureStorageKeys.userCredentials,
      _currentUser!.toJson(),
    );

    // Cache the master encryption key in memory so the rest of the
    // app can use it without re-deriving.
    _encryptionKey = Uint8List.fromList(kek);

    // Clear the sign-out sentinel.
    await SecureStorageService.instance.delete(SecureStorageKeys.authSignedOut);

    debugPrint(
      'AuthService: persisted Mode ${result.mode.name.toUpperCase()} session '
      '(effective_user_id=${result.effectiveUserIdHex.substring(0, 8)}…, '
      'created=${result.created})',
    );
  }

  /// True if the currently-stored session is Mode B or Mode C.
  /// UI flows check this before showing the mode-chooser screen.
  Future<bool> hasSeedAuthSession() async {
    final v = await SecureStorageService.instance.read(
      SecureStorageKeys.keyDerivationVersion,
    );
    return v == '2_mode_B' || v == '2_mode_C';
  }

  /// The persisted mode tag (`'1_mode_A'`, `'2_mode_B'`, `'2_mode_C'`,
  /// or `null` if none yet). Used to decide which sign-in flow to
  /// present on a returning device.
  Future<String?> readKeyDerivationVersion() async {
    return SecureStorageService.instance.read(
      SecureStorageKeys.keyDerivationVersion,
    );
  }

  /// Mode B convenience: run Google OAuth, capture the ID token, then
  /// call `signInModeB`. Returns `(user: AuthUser, hasModeA: bool)`.
  /// `hasModeA` is true when the same Google identity already has an
  /// existing Mode A vault — surfaces so the UI can warn that the new
  /// vault is independent (audit fix #4). The seed/password is NEVER
  /// persisted to disk — it's used once for KDF + signing, then dropped.
  ///
  /// On `GoogleSignInExceptionCode.canceled`, returns `null`.
  Future<({AuthUser user, bool hasModeA})?> signInGoogleModeB({required String password}) async {
    if (PlatformCapabilities.isDesktop) {
      throw Exception(
        'Google Sign-In is not available on desktop. '
        'Use "Get API Key" or pick "Passphrase only (Mode C)".',
      );
    }
    await _ensureGoogleInitialized();
    if (!_googleSignIn.supportsAuthenticate()) {
      throw Exception('Google Sign-In not supported on this device');
    }
    try {
      final account = await _googleSignIn.authenticate();
      final auth = account.authentication;
      final idToken = auth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw Exception(
          'Google did not return an ID token. Ensure serverClientId is '
          'configured in google-services.json / GoogleService-Info.plist.',
        );
      }
      return await signInModeB(
        provider: 'google',
        oauthToken: idToken,
        oauthSub: account.id,
        email: account.email,
        displayName: account.displayName ?? '',
        photoUrl: account.photoUrl,
        password: password,
      );
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  /// Mode B convenience for Apple Sign-In. Returns
  /// `(user: AuthUser, hasModeA: bool)` on success, `null` on user cancel.
  Future<({AuthUser user, bool hasModeA})?> signInAppleModeB({required String password}) async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      final identityToken = credential.identityToken;
      if (identityToken == null || identityToken.isEmpty) {
        throw Exception('Apple did not return an identity token');
      }
      final sub = credential.userIdentifier;
      if (sub == null) {
        throw Exception('Apple Sign-In failed: no user identifier');
      }
      // Apple only sends email on first sign-in.
      String? email = credential.email;
      String displayName = '';
      if (credential.givenName != null || credential.familyName != null) {
        displayName = [credential.givenName, credential.familyName]
            .where((n) => n != null && n.isNotEmpty)
            .join(' ');
      }
      email ??= '$sub@privaterelay.appleid.com';
      return await signInModeB(
        provider: 'apple',
        oauthToken: identityToken,
        oauthSub: sub,
        email: email,
        displayName: displayName,
        photoUrl: null,
        password: password,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      rethrow;
    }
  }

  Future<void> signOut() async {
    try {
      final provider = await SecureStorageService.instance.read(
        SecureStorageKeys.authProvider,
      );

      // Handle provider-specific sign out
      if (provider == AuthProvider.google.name) {
        try {
          await _ensureGoogleInitialized();
          // signOut() clears the cached account so attemptLightweightAuthentication
          // won't return the same user on the next launch. disconnect() additionally
          // revokes the OAuth grant. Run both — disconnect alone is not enough on
          // every platform/SDK version, and cached-account state is what drives
          // lightweight re-auth.
          try {
            await _googleSignIn.signOut();
          } catch (e) {
            debugPrint('Google signOut() failed (continuing): $e');
          }
          await _googleSignIn.disconnect();
        } catch (e) {
          // Google disconnect may fail if not properly initialized or user already disconnected
          // Continue with local sign out
          debugPrint('Google disconnect failed (continuing): $e');
        }
      }
      // Note: Apple Sign-In doesn't have a disconnect API - credentials are managed by the system
      // Users can revoke access from their Apple ID settings

      // Clear all stored credentials - do this regardless of provider disconnect success
      await SecureStorageService.instance.delete(SecureStorageKeys.userCredentials);
      await SecureStorageService.instance.delete(SecureStorageKeys.authProvider);
      await SecureStorageService.instance.delete(SecureStorageKeys.encryptionKey);
      await SecureStorageService.instance.delete(SecureStorageKeys.derivationEmail);
      await SecureStorageService.instance.delete(SecureStorageKeys.userPublicKey);
      await SecureStorageService.instance.delete(SecureStorageKeys.userPrivateKey);

      // Clear API key and tokens (tied to user account)
      await SecureStorageService.instance.delete(SecureStorageKeys.jwtToken);
      await SecureStorageService.instance.delete(SecureStorageKeys.refreshToken);

      // Clear Mode B / Mode C session state (audit F-A1 / F-A3 redesign).
      // Safe to delete even for Mode A users — the keys are absent in their
      // SecureStorage and `delete` is idempotent.
      await SecureStorageService.instance.delete(SecureStorageKeys.keyDerivationVersion);
      await SecureStorageService.instance.delete(SecureStorageKeys.effectiveUserIdHex);
      await SecureStorageService.instance.delete(SecureStorageKeys.modeOauthProvider);
      await SecureStorageService.instance.delete(SecureStorageKeys.modeOauthSub);

      // Clear sync queues and cached data for the old user
      await SyncService.instance.clearAll();

      // Clear cached sync mappings
      CloudSyncMappingService.instance.clear();

      // Drop the cached bucket-list snapshot — it's keyed by derivationEmail
      // and would otherwise leak bucket names to a different user signing in.
      await BucketCacheService.clear();

      // Stop the health-event poll loop; resumes on next sign-in.
      await MasterHealthService.instance.stop();

      // Clear NFT wallet state and secure storage key
      NftWalletService.instance.clear();
      await SecureStorageService.instance.delete(SecureStorageKeys.nftWalletPrivateKey);

      // Clear NFT collections, received NFTs, and tags (user-specific data)
      await NftService.instance.clearAll();
      await TagStorageService.instance.clearAll();

      // Clear shares and collaborations (user-specific data)
      await SharingService.instance.clearAll();
      await CollaborationService.instance.clearAll();

      // Stop collab folder syncs
      CollabFolderSyncService.instance.dispose();

      // Reset FulaApiService
      FulaApiService.instance.reset();

      // Always clear internal state last
      _setCurrentUser(null);
      _encryptionKey = null;
      _cachedShareId = null;

      // Mark the user as explicitly signed-out so checkExistingSession won't
      // silently restore them via Google's lightweight auth on the next launch.
      // Cleared on the next successful interactive sign-in.
      try {
        await SecureStorageService.instance.write(
          SecureStorageKeys.authSignedOut,
          'true',
        );
      } catch (e) {
        debugPrint('Failed to set auth_signed_out sentinel: $e');
      }
    } catch (e) {
      debugPrint('Sign out error: $e');
      // Still clear internal state even on error to ensure UI updates
      _setCurrentUser(null);
      _encryptionKey = null;
      _cachedShareId = null;
      // Best-effort sentinel write so the next launch still respects sign-out.
      try {
        await SecureStorageService.instance.write(
          SecureStorageKeys.authSignedOut,
          'true',
        );
      } catch (_) {}
      rethrow;
    }
  }

  Future<bool> reauthenticate() async {
    if (PlatformCapabilities.isDesktop) return false;

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
