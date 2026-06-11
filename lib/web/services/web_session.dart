import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'package:fula_files/core/services/auth_core.dart';
import 'package:fula_files/core/services/bucket_cache_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/master_health_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/utils/bip39_local.dart';

/// Signed-in identity as the web shell sees it.
class WebUser {
  final String id; // effective_user_id hex (JWT sub)
  final String email;
  final String? displayName;

  const WebUser({required this.id, required this.email, this.displayName});
}

/// Web-shell session controller. The browser counterpart of the native
/// AuthService for the cloud-only feature set: Mode C sign-in/restore
/// via [AuthCore] (identical key derivation + issuer protocol), session
/// restore from SecureStorage, sign-out.
///
/// Native-only concerns (OAuth SDKs, shelf/sync/NFT restore hooks, deep
/// links) intentionally absent.
class WebSession extends ChangeNotifier {
  WebSession._();
  static final WebSession instance = WebSession._();

  WebUser? _user;
  bool _busy = false;
  String? _lastError;

  WebUser? get user => _user;
  bool get isSignedIn => _user != null;
  bool get busy => _busy;
  String? get lastError => _lastError;

  /// Generate a fresh 24-word BIP39 recovery mnemonic (256-bit entropy).
  Future<String> generateRecoveryMnemonic() =>
      generateBip39Mnemonic(strength: 256);

  /// True iff `mnemonic` is a valid BIP39 phrase.
  Future<bool> isValidMnemonic(String mnemonic) =>
      validateBip39Mnemonic(mnemonic.trim());

  /// Restore a persisted session (page load / refresh). Returns true if
  /// a session was restored and the Fula client is configured.
  Future<bool> restore() async {
    try {
      final userJson = await SecureStorageService.instance.readJson(
        SecureStorageKeys.userCredentials,
      );
      final kekB64 = await SecureStorageService.instance.read(
        SecureStorageKeys.encryptionKey,
      );
      if (userJson == null || kekB64 == null || kekB64.isEmpty) {
        debugPrint('WebSession: no stored session');
        return false;
      }

      final kek = Uint8List.fromList(base64Decode(kekB64));
      final init = await AuthCore.initializeFulaFromStorage(kek: kek);
      if (init.configured) {
        unawaited(MasterHealthService.instance.start());
      }

      _user = WebUser(
        id: (userJson['id'] as String?) ?? '',
        email: (userJson['email'] as String?) ?? '',
        displayName: userJson['displayName'] as String?,
      );
      _lastError = null;
      notifyListeners();
      debugPrint(
          'WebSession: restored session for ${_user!.id.substring(0, 8)}… '
          '(fula configured=${init.configured})');
      return init.configured;
    } catch (e) {
      debugPrint('WebSession: restore failed: $e');
      return false;
    }
  }

  /// Mode C sign-in / sign-up with a recovery phrase. Same vault from
  /// the same seed on any platform.
  Future<void> signInModeC({required String seed, String? displayName}) async {
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      final r = await AuthCore.performModeCRegistration(
        seed: seed,
        displayName: displayName,
      );
      final init = await AuthCore.initializeFulaFromStorage(kek: r.kek);
      if (init.configured) {
        unawaited(MasterHealthService.instance.start());
      }
      _user = WebUser(
        id: r.result.effectiveUserIdHex,
        email: r.email,
        displayName: displayName ?? 'Passphrase Vault',
      );
      debugPrint(
          'WebSession: Mode C session active (created=${r.result.created}, '
          'fula configured=${init.configured})');
    } catch (e) {
      _lastError = e.toString();
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ==========================================================================
  // OAuth sign-in (web): Google via GIS button events, Apple via popup.
  // An optional passphrase set by the sign-in screen upgrades either
  // provider to Mode B (OAuth + seed); empty means legacy Mode A.
  // ==========================================================================

  bool _googleInited = false;

  /// Passphrase the user typed before clicking the Google button (the
  /// GIS button is the only sign-in trigger on web, so the choice has
  /// to be parked here until the credential event arrives).
  String pendingOAuthPassphrase = '';

  /// Initialize google_sign_in for web and start consuming credential
  /// events. Idempotent; call from the sign-in screen.
  Future<void> initGoogleWeb() async {
    if (_googleInited) return;
    await GoogleSignIn.instance.initialize(
      clientId: AuthCore.googleWebClientId,
    );
    // Lifetime subscription — WebSession is a singleton that lives as
    // long as the page, so the stream is never cancelled.
    GoogleSignIn.instance.authenticationEvents.listen((event) {
      if (event is GoogleSignInAuthenticationEventSignIn) {
        unawaited(_onGoogleCredential(event.user));
      }
    });
    _googleInited = true;
  }

  Future<void> _onGoogleCredential(GoogleSignInAccount account) async {
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw Exception('Google did not return an ID token');
      }
      final passphrase = pendingOAuthPassphrase.trim();
      if (passphrase.isNotEmpty) {
        // Mode B (Google + seed).
        final r = await AuthCore.performModeBRegistration(
          provider: 'google',
          oauthToken: idToken,
          oauthSub: account.id,
          email: account.email,
          displayName: account.displayName ?? '',
          photoUrl: account.photoUrl,
          seed: passphrase,
        );
        await _finishSignIn(
          kek: r.kek,
          user: WebUser(
            id: r.result.effectiveUserIdHex,
            email: account.email,
            displayName: account.displayName,
          ),
        );
      } else {
        // Mode A (legacy OAuth-only).
        final r = await AuthCore.performOAuthModeASignIn(
          providerName: 'google',
          userId: account.id,
          email: account.email,
          displayName: account.displayName,
          photoUrl: account.photoUrl,
          idToken: idToken,
        );
        await _finishSignIn(
          kek: r.kek,
          user: WebUser(
            id: account.id,
            email: r.pinnedEmail,
            displayName: account.displayName,
          ),
        );
      }
    } catch (e) {
      _lastError = 'Google sign-in failed: $e';
      debugPrint('WebSession: $_lastError');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Apple sign-in via the Services-ID popup flow. Same passphrase
  /// upgrade rule as Google.
  Future<void> signInWithAppleWeb() async {
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        webAuthenticationOptions: WebAuthenticationOptions(
          clientId: AuthCore.appleWebServicesId,
          redirectUri: Uri.parse(AuthCore.appleWebRedirectUri),
        ),
      );
      final identityToken = credential.identityToken;
      if (identityToken == null || identityToken.isEmpty) {
        throw Exception('Apple did not return an identity token');
      }
      final sub = credential.userIdentifier ??
          AuthCore.extractJwtSub(identityToken);
      if (sub == null || sub.isEmpty) {
        throw Exception('Apple sign-in returned no user identifier');
      }
      // Apple surfaces the email on the credential only at FIRST consent;
      // afterwards the identity token's claim still carries it. Fall back
      // to the relay-style placeholder only when both are absent (same
      // rule as native).
      final email = credential.email ??
          AuthCore.extractJwtClaim(identityToken, 'email') ??
          '$sub@privaterelay.appleid.com';
      String? displayName;
      if (credential.givenName != null || credential.familyName != null) {
        final dn = [credential.givenName, credential.familyName]
            .where((n) => n != null && n.isNotEmpty)
            .join(' ');
        displayName = dn.isEmpty ? null : dn;
      }

      final passphrase = pendingOAuthPassphrase.trim();
      if (passphrase.isNotEmpty) {
        final r = await AuthCore.performModeBRegistration(
          provider: 'apple',
          oauthToken: identityToken,
          oauthSub: sub,
          email: email,
          displayName: displayName ?? '',
          photoUrl: null,
          seed: passphrase,
        );
        await _finishSignIn(
          kek: r.kek,
          user: WebUser(
            id: r.result.effectiveUserIdHex,
            email: email,
            displayName: displayName,
          ),
        );
      } else {
        // First-consent extras for the issuer (mirrors the native body).
        final firstSignInUser = <String, dynamic>{};
        if (credential.email != null &&
            credential.email!.isNotEmpty &&
            !credential.email!.endsWith('@privaterelay.appleid.com')) {
          firstSignInUser['email'] = credential.email;
        }
        if ((credential.givenName ?? '').isNotEmpty ||
            (credential.familyName ?? '').isNotEmpty) {
          firstSignInUser['name'] = <String, dynamic>{
            if ((credential.givenName ?? '').isNotEmpty)
              'firstName': credential.givenName,
            if ((credential.familyName ?? '').isNotEmpty)
              'lastName': credential.familyName,
          };
        }
        final r = await AuthCore.performOAuthModeASignIn(
          providerName: 'apple',
          userId: sub,
          email: email,
          displayName: displayName,
          photoUrl: null,
          idToken: identityToken,
          extraExchangeBody:
              firstSignInUser.isEmpty ? null : {'user': firstSignInUser},
        );
        await _finishSignIn(
          kek: r.kek,
          user: WebUser(
            id: sub,
            email: r.pinnedEmail,
            displayName: displayName,
          ),
        );
      }
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code != AuthorizationErrorCode.canceled) {
        _lastError = 'Apple sign-in failed: ${e.message}';
      }
    } catch (e) {
      _lastError = 'Apple sign-in failed: $e';
      debugPrint('WebSession: $_lastError');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _finishSignIn({
    required Uint8List kek,
    required WebUser user,
  }) async {
    final init = await AuthCore.initializeFulaFromStorage(kek: kek);
    if (init.configured) {
      unawaited(MasterHealthService.instance.start());
    }
    _user = user;
    debugPrint('WebSession: signed in ${user.id.length >= 8 ? user.id.substring(0, 8) : user.id}… '
        '(fula configured=${init.configured})');
  }

  /// Sign out: stop pollers, reset the Fula client, clear all session
  /// storage (same key set as native sign-out, plus the persisted
  /// Mode B/C index keys).
  Future<void> signOut() async {
    try {
      await MasterHealthService.instance.stop();
    } catch (_) {}
    FulaApiService.instance.reset();
    try {
      await BucketCacheService.clear();
    } catch (_) {}
    await AuthCore.clearSessionStorage();
    _user = null;
    notifyListeners();
  }
}
