import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

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
    // Web extra: also drop the persisted per-user index keys so a
    // different vault on this browser can't read stale ones.
    await SecureStorageService.instance
        .delete(SecureStorageKeys.bucketsIndexKey);
    await SecureStorageService.instance
        .delete(SecureStorageKeys.userEntrySigningSeed);
    _user = null;
    notifyListeners();
  }
}
