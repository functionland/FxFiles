// Platform seam for the WEB same-tab OAuth 2.1 + PKCE hosted-connect flow.
//
// START is invoked from `ai_connections_provider.dart`, which lives in the
// shared `lib/features` graph (compiled for native too), so it MUST reach the
// browser-only implementation through this conditional export — never by a
// direct `package:web` import. Native builds get the IO stub (every entry
// throws / no-ops); web builds get the real `package:web` implementation.
//
// Mirrors the existing `lib/core/platform/file_length.dart` pattern.
export 'web_hosted_oauth_io.dart'
    if (dart.library.js_interop) 'web_hosted_oauth_web.dart';

// The platform-neutral result type (WebOauthCompleteOutcome) lives in the pure
// logic layer; re-export it so callers of the facade see it without importing
// the logic file directly.
export 'web_hosted_oauth_logic.dart' show WebOauthCompleteOutcome;
