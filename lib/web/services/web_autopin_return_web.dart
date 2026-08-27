// Web (browser) implementation of the Blox auto-pin return capture. Loaded
// ONLY on web via the conditional export in `web_autopin_return.dart`; the
// native/VM build gets `web_autopin_return_io.dart`.
//
// Thin `package:web` shell — every decision (what counts as a return, the
// cleaned URL, the session encoding) lives in the browser-free
// `web_autopin_return_logic.dart`.

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/core/services/blox_pairing_links.dart';
import 'package:fula_files/web/services/web_autopin_return_logic.dart';

/// CAPTURE — call as early as possible in `main()` BEFORE `runApp`.
///
/// Reads the page location (`https://files.fx.land/app/#/autopin-complete?…`,
/// a bare `#secret=…` fragment, or a `?secret=…` query), stashes the params
/// (memory + sessionStorage), and rewrites the address bar via
/// `history.replaceState` so the secret is gone from the URL/history and the
/// hash router boots on `#/`. A no-op on a normal startup — except that a
/// return parked in sessionStorage by an earlier load (refresh mid-sign-in)
/// is restored into memory so the hand-off still happens.
void captureAutopinReturn() {
  final location = Uri.parse(web.window.location.href);
  final capture = detectAutopinReturn(location);
  if (capture == null) {
    // Refresh-safety: restore a return parked by a previous load.
    final parked = decodeAutopinReturnFromSession(_readSession());
    if (parked != null) stashPendingAutopinReturnInMemory(parked);
    return;
  }
  stashPendingAutopinReturnInMemory(capture.params);
  _writeSession(capture.params);
  try {
    web.window.history.replaceState(null, '', capture.strippedUrl);
  } catch (e) {
    // Not fatal — the params are already captured; the router's
    // /autopin-complete fallback handles the un-stripped URL.
    debugPrint('captureAutopinReturn: replaceState failed: $e');
  }
}

/// Park [params] for the post-login hand-off (router fallback path).
void stashPendingAutopinReturn(AutopinCompleteParams? params) {
  if (params == null) return;
  stashPendingAutopinReturnInMemory(params);
  _writeSession(params);
}

/// Atomic read-and-clear (memory first, then sessionStorage). Clears BOTH so
/// neither a home re-mount nor a refresh can replay the hand-off.
AutopinCompleteParams? takePendingAutopinReturn() {
  final fromMemory = takePendingAutopinReturnFromMemory();
  final fromSession = decodeAutopinReturnFromSession(_readSession());
  _clearSession();
  return fromMemory ?? fromSession;
}

String? _readSession() {
  try {
    return web.window.sessionStorage.getItem(kAutopinReturnSessionKey);
  } catch (e) {
    debugPrint('autopin return: sessionStorage read failed: $e');
    return null;
  }
}

void _writeSession(AutopinCompleteParams params) {
  try {
    web.window.sessionStorage.setItem(
      kAutopinReturnSessionKey,
      encodeAutopinReturnForSession(params),
    );
  } catch (e) {
    debugPrint('autopin return: sessionStorage write failed: $e');
  }
}

void _clearSession() {
  try {
    web.window.sessionStorage.removeItem(kAutopinReturnSessionKey);
  } catch (e) {
    debugPrint('autopin return: sessionStorage clear failed: $e');
  }
}
