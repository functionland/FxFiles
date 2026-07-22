import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Owns the one and only `GoogleSignIn.instance.initialize()` call in the
/// process.
///
/// `GoogleSignIn.instance` is a process-wide singleton, and google_sign_in v7
/// documents that `initialize()` must be called *exactly once* — but the Dart
/// wrapper does not enforce it. The enforcement lives in the web
/// implementation, whose `init()` throws
/// `StateError('init() has already been called ...')` on the second call. The
/// Android/iOS implementations swallow a repeat init silently, so a second
/// `initialize()` is a latent bug on every platform and a hard failure only on
/// web.
///
/// The app has two natural doors into Google auth — the web shell's sign-in
/// screen ([WebSession.initGoogleWeb]) and the lazy scope request in
/// [AuthService] — and each used to keep its own private `bool` guard over the
/// shared singleton. A new web user opened both doors in one page session:
/// signing in with Google initialized it once, then publishing a website whose
/// contact form is backed by a Google Form asked for the Drive scope, which
/// initialized it again and threw. Returning users never hit it, because a
/// session restored from storage skips the sign-in screen entirely and leaves
/// the scope request as the *first* initialize.
///
/// Routing both doors through this class turns "initialize exactly once" from a
/// convention that two files have to agree on into an invariant that holds by
/// construction.
class GoogleSignInBootstrap {
  GoogleSignInBootstrap._();

  static bool _done = false;
  static Future<void>? _inFlight;
  static String? _usedClientId;
  static String? _usedServerClientId;

  /// Whether `GoogleSignIn.instance` has been initialized.
  static bool get isInitialized => _done;

  /// Initializes `GoogleSignIn.instance` unless that has already happened.
  ///
  /// Safe to call from anywhere, any number of times, including concurrently:
  /// the first caller does the work and every other caller awaits that same
  /// future. First call wins for [clientId]/[serverClientId] — the plugin has
  /// no reconfigure API, so a later, different value could not be applied even
  /// if we wanted to.
  static Future<void> ensureInitialized({
    String? clientId,
    String? serverClientId,
  }) {
    if (_done) {
      assert(() {
        if (_usedClientId != clientId ||
            _usedServerClientId != serverClientId) {
          debugPrint(
            'GoogleSignInBootstrap: ignoring a repeat initialize() with '
            'different parameters (clientId=$clientId, '
            'serverClientId=$serverClientId); the singleton is already '
            'configured with clientId=$_usedClientId, '
            'serverClientId=$_usedServerClientId. Callers on one platform '
            'are expected to agree on these.',
          );
        }
        return true;
      }());
      return Future<void>.value();
    }
    return _inFlight ??= _initialize(clientId, serverClientId);
  }

  static Future<void> _initialize(
    String? clientId,
    String? serverClientId,
  ) async {
    try {
      await GoogleSignIn.instance.initialize(
        clientId: clientId,
        serverClientId: serverClientId,
      );
    } on StateError catch (e) {
      // The double-init guard is the only StateError `initialize()` raises, so
      // arriving here means the singleton is already configured — by a code
      // path this class does not know about, or by the previous run of a hot
      // restart, which resets Dart state but not the GIS SDK already loaded
      // into the page. Either way it is initialized, which is all the caller
      // asked for. Note this is deliberately matched by TYPE, not by message:
      // the wording of that error changes between plugin versions.
      debugPrint('GoogleSignInBootstrap: initialize() reports an existing '
          'initialization; continuing. ($e)');
    } catch (e) {
      // Something transient — e.g. the GIS script failed to load. Drop the
      // cached future so the next caller retries instead of inheriting the
      // failure forever.
      _inFlight = null;
      rethrow;
    }
    _done = true;
    _usedClientId = clientId;
    _usedServerClientId = serverClientId;
  }

  /// Test-only: forget that initialization happened.
  @visibleForTesting
  static void resetForTest() {
    _done = false;
    _inFlight = null;
    _usedClientId = null;
    _usedServerClientId = null;
  }
}
