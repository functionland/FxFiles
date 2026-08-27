// PURE (browser-free) logic for the web-build side of the Blox auto-pin
// pairing return (`docs/AUTOPIN-HANDOFF.md`).
//
// This file imports nothing web-specific, so it is the ONLY layer the unit
// tests touch — `flutter test` runs on the Dart VM, which compiles the IO
// stub branch of `web_autopin_return.dart`, never the `package:web` impl.
//
// Flow (mirrors `web_hosted_oauth`):
//   CAPTURE  — `captureAutopinReturn()` (web impl) runs in `main()` BEFORE
//              `runApp`, detects the return in the page location via
//              [detectAutopinReturn], stashes the params (memory +
//              sessionStorage so a refresh mid-sign-in does not lose them),
//              and `history.replaceState`s the URL to [strippedUrl] so the
//              secret leaves the address bar / history and the hash router
//              boots on a clean `#/`.
//   HAND-OFF — the web home's post-login init calls
//              `takePendingAutopinReturn()` and navigates to `/blox-pairing`
//              with the params as go_router `extra` (never as a query, so the
//              secret does not re-enter the URL).
//   FALLBACK — if the URL somehow still reaches the router (replaceState
//              failed), the `/autopin-complete` route/redirect uses the same
//              parser and stash.

import 'dart:convert';

import 'package:fula_files/core/services/blox_pairing_links.dart';

/// `window.sessionStorage` key holding the captured return between the
/// capture and the post-login hand-off (per-tab; cleared on take).
const String kAutopinReturnSessionKey = 'fxfiles.autopinReturn.pending';

/// The result of inspecting a page location that carries an autopin return.
class AutopinReturnCapture {
  const AutopinReturnCapture({required this.params, required this.strippedUrl});

  /// The parsed (NOT yet validated) parameters.
  final AutopinCompleteParams params;

  /// The full URL to `history.replaceState` to: same origin + path, the four
  /// return keys removed from the query, and the route fragment reset to `/`
  /// when it carried the return.
  final String strippedUrl;
}

/// Inspect a full page [location] (normally `window.location.href`).
/// Returns null when it is not an autopin return (normal startup).
AutopinReturnCapture? detectAutopinReturn(Uri location) {
  final params = parseAutopinCompleteParams(location);
  if (params == null) return null;
  return AutopinReturnCapture(
    params: params,
    strippedUrl: stripAutopinReturnFromLocation(location),
  );
}

const Set<String> _returnKeys = <String>{
  'secret',
  'hardwareId',
  'bloxPeerId',
  'bloxName',
};

/// Build the cleaned address-bar URL for [location]:
///  - origin + path kept exactly (a `--base-href /app/` subpath survives);
///  - the four return keys dropped from the query, every other query param
///    kept (e.g. the E2E `?e2e=` hooks);
///  - the fragment reset to the home route `/` when it carried the return
///    (hash-route `/autopin-complete?…` or a bare `secret=…` fragment),
///    otherwise kept verbatim.
///
/// Built by string concatenation (NOT `Uri.replace`, which emits a stray `?`
/// for an empty query), mirroring `stripQueryPreservingFragment`.
String stripAutopinReturnFromLocation(Uri location) {
  String base;
  try {
    base = location.origin + location.path;
  } catch (_) {
    // Non-http(s) (never the case in a browser) — fall back to a relative URL.
    base = location.path;
  }

  Map<String, String> query;
  try {
    query = Map<String, String>.of(location.queryParameters);
  } catch (_) {
    query = <String, String>{};
  }
  query.removeWhere((k, _) => _returnKeys.contains(k));
  final queryString = query.isEmpty
      ? ''
      : '?${query.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&')}';

  final fragment = location.fragment;
  final String newFragment;
  if (fragment.isEmpty) {
    newFragment = '';
  } else if (_fragmentCarriesReturn(fragment)) {
    newFragment = '/';
  } else {
    newFragment = fragment;
  }

  return '$base$queryString${newFragment.isEmpty ? '' : '#$newFragment'}';
}

bool _fragmentCarriesReturn(String fragment) {
  if (fragment.startsWith('/')) {
    final routed = Uri.tryParse(fragment);
    return routed != null && isAutopinReturnRoutePath(routed.path);
  }
  try {
    return Uri.splitQueryString(fragment).containsKey('secret');
  } catch (_) {
    return false;
  }
}

// ── Pending holder (memory) ─────────────────────────────────────────────────
// The browser twin mirrors this into sessionStorage; the IO twin uses only the
// memory holder. Kept here so the router fallback and the tests share it.

AutopinCompleteParams? _pending;

/// Remember [params] for the post-login hand-off. Null is a no-op.
void stashPendingAutopinReturnInMemory(AutopinCompleteParams? params) {
  if (params == null) return;
  _pending = params;
}

/// Atomic read-and-clear of the memory holder.
AutopinCompleteParams? takePendingAutopinReturnFromMemory() {
  final p = _pending;
  _pending = null;
  return p;
}

/// Non-destructive peek (for tests / guards).
bool hasPendingAutopinReturnInMemory() => _pending != null;

// ── sessionStorage encoding ─────────────────────────────────────────────────

/// JSON for `sessionStorage` (only the non-null fields).
String encodeAutopinReturnForSession(AutopinCompleteParams params) =>
    jsonEncode(params.toQueryParameters());

/// Fail-closed decode: null on missing/empty/malformed JSON, a non-object, a
/// non-string value, or a payload that fails [AutopinCompleteParams.validationError].
AutopinCompleteParams? decodeAutopinReturnFromSession(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final m = <String, String>{};
  for (final entry in decoded.entries) {
    final k = entry.key;
    final v = entry.value;
    if (k is! String || v is! String) return null;
    m[k] = v;
  }
  final params = AutopinCompleteParams.fromMap(m);
  if (params == null || !params.isValid) return null;
  return params;
}
