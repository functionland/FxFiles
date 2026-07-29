import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'package:fula_files/core/services/auth_core.dart';
import 'package:fula_files/core/services/bucket_cache_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/google_signin_bootstrap.dart';
import 'package:fula_files/core/services/master_health_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/utils/bip39_local.dart';
import 'package:fula_files/web/services/web_audio_controller.dart';
import 'package:fula_files/web/services/web_cache_sync.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';
import 'package:fula_files/web/services/web_prefetch_scheduler.dart';
import 'package:fula_files/web/services/web_recent_files_service.dart';
import 'package:fula_files/web/services/web_thumbnail_service.dart';
import 'package:fula_files/web/services/web_upload_manager.dart';
import 'package:fula_files/web/services/web_website_asset_uploader.dart';

/// Signed-in identity as the web shell sees it.
class WebUser {
  final String id; // effective_user_id hex (JWT sub)
  final String email;
  final String? displayName;
  final String? photoUrl;

  const WebUser({
    required this.id,
    required this.email,
    this.displayName,
    this.photoUrl,
  });

  /// Passphrase-only vaults (Mode C) have no OAuth identity — their
  /// stored email is the synthetic `…@seed.fxfiles.local` placeholder,
  /// so the UI shows the vault id instead of an email.
  bool get isVault =>
      email.isEmpty || email.endsWith('@seed.fxfiles.local');
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

  /// Session-scoped: the user dismissed the auto-presented login prompt on
  /// the logged-out home, so it shouldn't immediately re-open while they
  /// look around. Lives HERE (not in the home widget's State) because the
  /// home State is recreated on navigation — a State-local flag wouldn't
  /// persist the cancel. Reset on sign-out so the next logged-out session
  /// re-arms the prompt. Not part of `notifyListeners` semantics — the home
  /// reads it directly when deciding whether to auto-open.
  bool loginPromptDismissed = false;

  /// Generate a fresh 24-word BIP39 recovery mnemonic (256-bit entropy).
  Future<String> generateRecoveryMnemonic() =>
      generateBip39Mnemonic(strength: 256);

  /// True iff `mnemonic` is a valid BIP39 phrase.
  Future<bool> isValidMnemonic(String mnemonic) =>
      validateBip39Mnemonic(mnemonic.trim());

  /// Restore a persisted session (page load / refresh). Returns true if
  /// a session was restored and the Fula client is configured.
  Future<bool> restore() async {
    // Cross-tab coherence is live from boot in every tab: remote
    // invalidations drop cache entries here, and a remote sign-out
    // drops this tab's in-memory session too (its storage was already
    // cleared by the originating tab).
    WebCacheSync.onRemoteSignOut = _onRemoteSignOut;
    WebCacheSync.instance.ensureStarted();
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
      if (!init.configured) {
        // Partial/legacy storage (e.g. the browser evicted the JWT or
        // endpoint keys but kept credentials): entering the app with
        // an UNCONFIGURED client makes every screen throw
        // "FulaApiService is not configured" (real user report,
        // 2026-06-12). Show the sign-in screen instead — a fresh
        // sign-in rewrites the full set.
        debugPrint('WebSession: stored session unusable '
            '(client unconfigured) — routing to sign-in');
        return false;
      }
      unawaited(MasterHealthService.instance.start());

      _user = WebUser(
        id: (userJson['id'] as String?) ?? '',
        email: (userJson['email'] as String?) ?? '',
        displayName: userJson['displayName'] as String?,
        photoUrl: userJson['photoUrl'] as String?,
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

  Future<void>? _googleInitInFlight;

  /// Passphrase the user typed before clicking the Google button (the
  /// GIS button is the only sign-in trigger on web, so the choice has
  /// to be parked here until the credential event arrives).
  String pendingOAuthPassphrase = '';

  /// Initialize google_sign_in for web and start consuming credential
  /// events. Idempotent; call from the sign-in screen.
  ///
  /// The guard is a Future rather than a bool because the sign-in screen
  /// calls this from `initState` without awaiting it: two screens mounted
  /// in quick succession would both pass a bool guard that is only set
  /// after the await, and subscribe the credential handler twice.
  Future<void> initGoogleWeb() => _googleInitInFlight ??= _initGoogleWeb();

  Future<void> _initGoogleWeb() async {
    try {
      // Shared with AuthService — `GoogleSignIn.instance` is a process-wide
      // singleton whose initialize() may run only once, and AuthService
      // initializes it too when it asks for the Drive scope.
      await GoogleSignInBootstrap.ensureInitialized(
        clientId: AuthCore.googleWebClientId,
      );
    } catch (e) {
      // Leave the door open for a retry — e.g. the GIS script failed to load
      // on a flaky connection and the user reopens the sign-in sheet. Callers
      // are fire-and-forget, so this must not escape as an unhandled error.
      _googleInitInFlight = null;
      debugPrint('WebSession: Google Sign-In init failed: $e');
      return;
    }
    // Lifetime subscription — WebSession is a singleton that lives as
    // long as the page, so the stream is never cancelled. It sits inside
    // the guarded future above so it is registered exactly once.
    GoogleSignIn.instance.authenticationEvents.listen((event) {
      if (event is GoogleSignInAuthenticationEventSignIn) {
        unawaited(_onGoogleCredential(event.user));
      }
    });
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
            photoUrl: account.photoUrl,
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
            photoUrl: account.photoUrl,
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

  /// Sign out: clear all session storage (same key set as native
  /// sign-out, plus the persisted Mode B/C index keys), reset the Fula
  /// client + caches, and redirect to /signin.
  ///
  /// Ordering is deliberate and security-critical: the AUTHORITATIVE
  /// logout (clear persisted credentials → drop the in-memory user →
  /// notifyListeners) runs FIRST and is never gated on the best-effort
  /// teardown. Previously the listing-cache box delete ran first; on web
  /// that delete can BLOCK indefinitely (IndexedDB `deleteDatabase` fires
  /// `onblocked` while a connection is open), which stalled the whole
  /// method — credentials were never cleared (a reload restored the
  /// session) and the redirect never fired.
  Future<void> signOut() async {
    // 1) Refresh-safety: clear persisted credentials so a reload can't
    //    restore the session. Timeout-bounded so a stuck secure-storage
    //    delete can't trap the user logged in.
    try {
      await AuthCore.clearSessionStorage()
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('WebSession.signOut: clearSessionStorage: $e');
    }

    // 1b) Web-specific: reset the user-overridable API configuration to
    //     defaults on sign-out. Mobile intentionally KEEPS endpoint
    //     overrides for account-switching; on web we reset so the next
    //     user starts from the built-in defaults. Timeout-bounded so a
    //     stuck secure-storage delete can't trap the user logged in.
    try {
      await Future(() async {
        for (final k in const [
          SecureStorageKeys.apiGatewayUrl,
          SecureStorageKeys.ipfsServerUrl,
          SecureStorageKeys.billingServerUrl,
          SecureStorageKeys.aiEndpointUrl,
          SecureStorageKeys.ipfsGatewayUrl,
          SecureStorageKeys.ipfsEndpointUrl,
          SecureStorageKeys.baseRpcUrl,
          SecureStorageKeys.usersIndexAnchorAddress,
          SecureStorageKeys.usersIndexIpnsName,
          SecureStorageKeys.usersIndexIpnsGatewayUrls,
        ]) {
          await SecureStorageService.instance.delete(k);
        }
      }).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('WebSession.signOut: reset API config: $e');
    }

    // 2) In-session logout + redirect to the (logged-out) home. Re-arm the
    //    login prompt so the next session auto-presents it again.
    _user = null;
    loginPromptDismissed = false;
    notifyListeners();

    // 3) Tell other tabs, then reset in-memory services. WebUploadManager
    //    reset drops any queued/finished uploads so the next user never
    //    sees or continues this user's (an in-flight Rust call can't be
    //    cancelled on web, but no new job starts after this).
    WebCacheSync.instance.sendSignedOut();
    FulaApiService.instance.reset();
    WebPrefetchScheduler.instance.reset();
    WebUploadManager.instance.reset();
    WebWebsiteAssetUploader.instance.reset();

    // 4) Best-effort teardown — MUST NOT block sign-out. The KEK is
    //    already gone so any residual listing cache is unreadable;
    //    deleting the box is hygiene, not security. Each task is its OWN
    //    fire-and-forget so a hang in one (e.g. a blocked IndexedDB delete
    //    while another tab holds the box) can't starve the others.
    unawaited(() async {
      try {
        await MasterHealthService.instance.stop();
      } catch (_) {}
    }());
    unawaited(() async {
      try {
        await BucketCacheService.clear();
      } catch (_) {}
    }());
    unawaited(() async {
      try {
        await WebListingCache.instance.clearAll();
      } catch (_) {}
    }());
    unawaited(() async {
      try {
        await WebRecentFilesService.instance.clearAll();
      } catch (_) {}
    }());
    unawaited(() async {
      try {
        await WebThumbnailService.instance.clearAll();
      } catch (_) {}
    }());
    // Stop background audio so the previous user's track doesn't keep playing
    // into the next session (s2).
    WebAudioController.instance.stopPlayback();
  }

  /// Another tab signed out: shared storage is already cleared; this
  /// tab must stop trusting its in-memory session (cache L1 +
  /// scheduler were reset by WebCacheSync before this hook fires).
  void _onRemoteSignOut() {
    if (_user == null) return;
    FulaApiService.instance.reset();
    WebUploadManager.instance.reset();
    WebWebsiteAssetUploader.instance.reset();
    _user = null;
    loginPromptDismissed = false;
    notifyListeners(); // router redirects to the logged-out home
  }
}
