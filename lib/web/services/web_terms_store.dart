import 'package:web/web.dart' as web;

import 'package:fula_files/shared/legal/terms_content.dart';

/// localStorage keys for the web shell's Terms acceptance (the stored version
/// is parsed by [parseAcceptedTermsVersion]). Kept apart from the
/// session keys sign-out wipes: accepting the Terms belongs to the visitor on
/// this browser, not to one signed-in account.
const String webTermsVersionKey = 'fx_terms_accepted_version';
const String webTermsAcceptedAtKey = 'fx_terms_accepted_at';

/// Persistence for web Terms acceptance. SYNCHRONOUS localStorage, like the
/// view-mode store, so the gate decides on the very first frame, and fail-soft:
/// Safari private mode and blocked storage throw on access — the visitor is
/// then asked again next visit rather than locked out now.
class WebTermsStore {
  WebTermsStore._();
  static final WebTermsStore instance = WebTermsStore._();

  /// Version recorded as accepted, or null.
  int? acceptedVersion() {
    try {
      return parseAcceptedTermsVersion(
          web.window.localStorage.getItem(webTermsVersionKey));
    } catch (_) {
      return null;
    }
  }

  bool get acceptanceRequired => termsAcceptanceRequired(
        acceptedVersion: acceptedVersion(),
        legacyAccepted: false,
      );

  /// Record acceptance of the CURRENT Terms, with when (UTC).
  void recordAcceptance() {
    try {
      web.window.localStorage
          .setItem(webTermsVersionKey, kTermsVersion.toString());
      web.window.localStorage.setItem(
          webTermsAcceptedAtKey, DateTime.now().toUtc().toIso8601String());
    } catch (_) {
      // Storage denied — acceptance still holds for this visit.
    }
  }
}
