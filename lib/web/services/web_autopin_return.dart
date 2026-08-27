// Platform seam for the WEB-build side of the Blox auto-pin pairing return
// (`docs/AUTOPIN-HANDOFF.md`).
//
// `main_web.dart`, the web router and the web home reach the browser-only
// implementation through this conditional export — never by a direct
// `package:web` import — so the same files stay compilable for `flutter test`
// (VM) via the IO stub. Mirrors `web_hosted_oauth.dart`.
//
// API (identical on both branches):
//   captureAutopinReturn()          — call in main() BEFORE runApp
//   stashPendingAutopinReturn(p)    — router fallback / manual park
//   takePendingAutopinReturn()      — post-login hand-off (read-and-clear)
export 'web_autopin_return_io.dart'
    if (dart.library.js_interop) 'web_autopin_return_web.dart';
