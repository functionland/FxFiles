// Native (dart:io / VM) stub for the web same-tab OAuth seam.
//
// On native, the hosted-connect flow uses the unchanged `HostedOauthClient`
// (external browser + `fxfiles://auth-callback` deep link). This stub exists
// ONLY so the shared `lib/features` graph compiles for native and under
// `flutter test` (the VM compiles THIS branch of the conditional export, never
// the `package:web` impl) — every entry is inert:
//   - START throws (the provider guards START behind `kIsWeb`, so it is never
//     reached on native; a throw is the correct fail-closed behaviour if it
//     somehow were);
//   - CAPTURE / COMPLETE are no-ops (there is no browser URL to read).
//
// It imports NOTHING web-specific, so it never drags `package:web` into the
// native compile graph.

import 'package:fula_files/features/ai_connections/services/web_hosted_oauth_logic.dart';

/// START (native stub): unreachable — the provider only calls this under
/// `kIsWeb`. Throws fail-closed if invoked.
Future<void> startWebHostedOauth({
  required String workerUrl,
  required String label,
}) {
  throw UnsupportedError(
    'startWebHostedOauth is web-only; native uses HostedOauthClient.',
  );
}

/// CAPTURE (native stub): no browser URL — nothing to capture.
void captureWebOauthRedirect() {}

/// COMPLETE (native stub): nothing pending.
Future<WebOauthCompleteOutcome> completeWebHostedOauthIfPending() async =>
    WebOauthCompleteOutcome.none;
