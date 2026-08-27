/// Blox auto-pin pairing hand-off links — the FxFiles side of the contract in
/// `docs/AUTOPIN-HANDOFF.md` (v1).
///
/// This file is deliberately free of `dart:io`, `package:web` and Flutter
/// imports so it compiles in EVERY graph (native, desktop, the web shell) and
/// is unit-testable on the Dart VM.
///
/// Outbound (FxFiles → FxBlox):
///   native  `fxblox://autopin-pair?token=<t>&endpoint=<e>&returnUrl=<r>`
///   web     `https://blox.fx.land/autopin-pair?token=<t>&endpoint=<e>&returnUrl=<r>`
/// `returnUrl` is a URL-encoded TEMPLATE carrying the literal placeholders
/// `$secret`, `$hardwareId`, `$bloxPeerId`, `$bloxName`; FxBlox substitutes
/// them (each value `encodeURIComponent`-ed) and navigates to the result.
///
/// Return (FxBlox → FxFiles): the fragment form is canonical so the bearer
/// secret never reaches a server or a log:
///   `https://files.fx.land/autopin-complete#secret=…&hardwareId=…&bloxPeerId=…&bloxName=…`
/// The legacy `fxfiles://autopin-complete?secret=…` (query) form and the web
/// app's hash-route form `https://files.fx.land/app/#/autopin-complete?secret=…`
/// are still accepted by [parseAutopinCompleteParams].
library;

/// Web FxBlox pairing entry point.
const String kBloxWebPairBase = 'https://blox.fx.land/autopin-pair';

/// Native FxBlox app pairing deep link.
const String kBloxNativePairBase = 'fxblox://autopin-pair';

/// Host + path of the return forwarder (`site/autopin-complete/index.html`)
/// and of the native universal-link arm.
const String kAutopinReturnHost = 'files.fx.land';
const String kAutopinReturnPath = '/autopin-complete';

/// Default pinning/IPFS API base sent as `endpoint` when the user has not
/// overridden `SecureStorageKeys.ipfsServerUrl`.
const String kDefaultPinningEndpoint = 'https://api.cloud.fx.land';

/// The four placeholders FxBlox substitutes in the return template. Raw
/// strings: the `$` is LITERAL, never Dart interpolation.
const List<String> kAutopinReturnPlaceholders = <String>[
  r'$secret',
  r'$hardwareId',
  r'$bloxPeerId',
  r'$bloxName',
];

/// Canonical (v1) return template — fragment form. Sent URL-encoded as
/// `returnUrl`; FxBlox decodes it, substitutes the placeholders and opens it.
const String kAutopinReturnTemplate =
    r'https://files.fx.land/autopin-complete#secret=$secret&hardwareId=$hardwareId&bloxPeerId=$bloxPeerId&bloxName=$bloxName';

/// The pre-v1 custom-scheme template. No longer SENT, but documented here (and
/// still parsed by [parseAutopinCompleteParams]) because older FxBlox builds
/// and the static forwarder still produce the query form.
const String kAutopinLegacyReturnTemplate =
    r'fxfiles://autopin-complete?secret=$secret&hardwareId=$hardwareId&bloxPeerId=$bloxPeerId&bloxName=$bloxName';

/// True iff [template] carries every placeholder in [kAutopinReturnPlaceholders].
bool returnTemplateHasAllPlaceholders(String template) =>
    kAutopinReturnPlaceholders.every(template.contains);

String _pairQuery({
  required String token,
  required String endpoint,
  required String returnTemplate,
}) {
  if (token.isEmpty) {
    throw ArgumentError.value(token, 'token', 'must not be empty');
  }
  if (endpoint.isEmpty) {
    throw ArgumentError.value(endpoint, 'endpoint', 'must not be empty');
  }
  if (!returnTemplateHasAllPlaceholders(returnTemplate)) {
    throw ArgumentError.value(
      returnTemplate,
      'returnTemplate',
      'must contain all of $kAutopinReturnPlaceholders',
    );
  }
  // Uri.encodeComponent percent-encodes `$ & = # : /` so the template survives
  // as ONE query value; FxBlox `decodeURIComponent`s it back verbatim.
  return 'token=${Uri.encodeComponent(token)}'
      '&endpoint=${Uri.encodeComponent(endpoint)}'
      '&returnUrl=${Uri.encodeComponent(returnTemplate)}';
}

/// `https://blox.fx.land/autopin-pair?token=…&endpoint=…&returnUrl=…`
///
/// Throws [ArgumentError] on an empty [token]/[endpoint] or a
/// [returnTemplate] missing a placeholder (fail-closed: never hand FxBlox a
/// template it cannot complete).
Uri buildBloxWebPairUrl({
  required String token,
  required String endpoint,
  String returnTemplate = kAutopinReturnTemplate,
}) {
  final q = _pairQuery(
    token: token,
    endpoint: endpoint,
    returnTemplate: returnTemplate,
  );
  return Uri.parse('$kBloxWebPairBase?$q');
}

/// `fxblox://autopin-pair?token=…&endpoint=…&returnUrl=…` — the SAME params
/// as [buildBloxWebPairUrl], only the scheme/host differ.
Uri buildBloxNativePairUrl({
  required String token,
  required String endpoint,
  String returnTemplate = kAutopinReturnTemplate,
}) {
  final q = _pairQuery(
    token: token,
    endpoint: endpoint,
    returnTemplate: returnTemplate,
  );
  return Uri.parse('$kBloxNativePairBase?$q');
}

/// The four values FxBlox hands back after `AutoPinPair` succeeded.
///
/// [secret] is the bearer pairing secret (required); the other three are
/// optional device identity (FxBlox sends them as empty strings when unknown,
/// which [fromMap] normalizes to null).
class AutopinCompleteParams {
  const AutopinCompleteParams({
    required this.secret,
    this.hardwareId,
    this.bloxPeerId,
    this.bloxName,
  });

  final String secret;
  final String? hardwareId;
  final String? bloxPeerId;
  final String? bloxName;

  /// Upper bounds applied by [validationError]. Generous versus the real
  /// shapes (secret: a random token; hardwareId: a hex/serial string; peer id:
  /// a ~52-char base58 / CIDv1 string; name: user text) — they exist to reject
  /// obviously bogus payloads before anything is persisted.
  static const int maxSecretLength = 512;
  static const int maxHardwareIdLength = 256;
  static const int maxPeerIdLength = 128;
  static const int maxNameLength = 128;

  /// Build from a decoded `key=value` map (query or fragment). Returns null
  /// when there is no non-empty `secret` — the one required field.
  static AutopinCompleteParams? fromMap(Map<String, String> m) {
    final secret = m['secret'];
    if (secret == null || secret.isEmpty) return null;
    return AutopinCompleteParams(
      secret: secret,
      hardwareId: _nullIfEmpty(m['hardwareId']),
      bloxPeerId: _nullIfEmpty(m['bloxPeerId']),
      bloxName: _nullIfEmpty(m['bloxName']),
    );
  }

  static String? _nullIfEmpty(String? v) => (v == null || v.isEmpty) ? null : v;

  /// The `{secret, hardwareId, bloxPeerId, bloxName}` map shape the native
  /// `DeepLinkService.onBloxPairingComplete` stream and `app.dart` consume.
  Map<String, String?> toLegacyMap() => <String, String?>{
        'secret': secret,
        'hardwareId': hardwareId,
        'bloxPeerId': bloxPeerId,
        'bloxName': bloxName,
      };

  /// Non-null fields only — for re-emitting as a query/fragment.
  Map<String, String> toQueryParameters() => <String, String>{
        'secret': secret,
        if (hardwareId != null) 'hardwareId': hardwareId!,
        if (bloxPeerId != null) 'bloxPeerId': bloxPeerId!,
        if (bloxName != null) 'bloxName': bloxName!,
      };

  /// A user-safe reason this payload must NOT be persisted, or null when it
  /// passes: non-empty secret, per-field length caps, no control characters.
  String? get validationError {
    if (secret.isEmpty) return 'Pairing secret is missing.';
    if (secret.length > maxSecretLength) return 'Pairing secret is too long.';
    if (_hasControlChars(secret)) return 'Pairing secret is malformed.';
    if ((hardwareId?.length ?? 0) > maxHardwareIdLength) {
      return 'Hardware ID is too long.';
    }
    if (hardwareId != null && _hasControlChars(hardwareId!)) {
      return 'Hardware ID is malformed.';
    }
    if ((bloxPeerId?.length ?? 0) > maxPeerIdLength) {
      return 'Blox peer ID is too long.';
    }
    if (bloxPeerId != null && _hasControlChars(bloxPeerId!)) {
      return 'Blox peer ID is malformed.';
    }
    if ((bloxName?.length ?? 0) > maxNameLength) return 'Blox name is too long.';
    if (bloxName != null && _hasControlChars(bloxName!)) {
      return 'Blox name is malformed.';
    }
    return null;
  }

  bool get isValid => validationError == null;

  static bool _hasControlChars(String s) {
    for (final cu in s.codeUnits) {
      if (cu < 0x20 || cu == 0x7F) return true;
    }
    return false;
  }

  @override
  String toString() =>
      'AutopinCompleteParams(secret: <redacted ${secret.length} chars>, '
      'hardwareId: $hardwareId, bloxPeerId: $bloxPeerId, bloxName: $bloxName)';
}

/// Read the autopin-complete parameters from [uri], FRAGMENT FIRST, then the
/// query. Returns null when no non-empty `secret` is found anywhere.
///
/// Accepted shapes (in precedence order):
///   1. `…#secret=…&hardwareId=…`                 canonical fragment form
///   2. `…/app/#/autopin-complete?secret=…`        web hash-route form
///   3. `fxfiles://autopin-complete?secret=…` /
///      `https://files.fx.land/autopin-complete?secret=…`   query form
///
/// A malformed percent-encoding in one section is treated as "absent" for that
/// section (fail-soft: fall through to the next form) rather than throwing.
AutopinCompleteParams? parseAutopinCompleteParams(Uri uri) {
  final fragment = uri.fragment;
  if (fragment.isNotEmpty) {
    final fromFragment = _paramsFromFragment(fragment);
    if (fromFragment != null) return fromFragment;
  }
  final query = _safeQueryParameters(uri);
  if (query != null) return AutopinCompleteParams.fromMap(query);
  return null;
}

AutopinCompleteParams? _paramsFromFragment(String fragment) {
  if (fragment.startsWith('/')) {
    // Hash-route form: the fragment is itself a path?query.
    final routed = Uri.tryParse(fragment);
    if (routed == null) return null;
    if (routed.path != kAutopinReturnPath &&
        !routed.path.endsWith(kAutopinReturnPath)) {
      return null;
    }
    final q = _safeQueryParameters(routed);
    return q == null ? null : AutopinCompleteParams.fromMap(q);
  }
  // Plain key=value fragment.
  Map<String, String> kv;
  try {
    kv = Uri.splitQueryString(fragment);
  } catch (_) {
    return null;
  }
  return AutopinCompleteParams.fromMap(kv);
}

Map<String, String>? _safeQueryParameters(Uri uri) {
  try {
    return uri.queryParameters;
  } catch (_) {
    return null;
  }
}
