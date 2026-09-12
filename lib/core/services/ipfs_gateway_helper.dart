import 'package:fula_files/core/services/secure_storage_service.dart';

/// Resolves the user's IPFS gateway template into concrete URLs and exposes
/// a sync cache so callers in non-async contexts (model getters, widgets)
/// don't have to await SecureStorage on every CID render.
///
/// Two template formats are accepted:
///   * `https://{cid}.ipfs.dweb.link/` — `{cid}` is substituted in place
///     (subdomain-style gateways like dweb.link, w3s.link).
///   * `https://my-host/ipfs/`        — CID is appended to the end
///     (path-style gateways and legacy custom installs).
class IpfsGatewayHelper {
  IpfsGatewayHelper._();

  /// Subdomain-style dweb.link template, used as the app-wide default.
  static const String defaultTemplate = 'https://{cid}.ipfs.dweb.link/';

  /// Pre-v0.4 default. Anyone still on this exact value is upgraded to
  /// [defaultTemplate] on the next [init].
  static const String legacyDefault = 'https://ipfs.cloud.fx.land/gateway/';

  /// Path-style Filebase gateway. Offered as a preset because dweb.link
  /// rate-limits (HTTP 429) once a site gets any real traffic — measured
  /// 2026-09-12, a freshly generated site returned 429 from dweb.link and
  /// 200 from Filebase at the same moment.
  static const String filebaseTemplate = 'https://ipfs.filebase.io/ipfs/';

  /// The presets the settings picker offers, in display order. Anything
  /// else the user types is "Custom" — [buildUrl] accepts any template in
  /// either of the two supported shapes.
  static const Map<String, String> presets = <String, String>{
    'dweb.link': defaultTemplate,
    'Filebase': filebaseTemplate,
  };

  /// Preset label for [template], or null when it is a custom value.
  static String? presetLabelFor(String template) {
    final t = template.trim();
    for (final entry in presets.entries) {
      if (entry.value == t) return entry.key;
    }
    return null;
  }

  /// `?gw=` key the fxfiles.top resolver understands for the active template,
  /// or null when the link should just use the resolver's default.
  ///
  /// The resolver only accepts a fixed allowlist — it is a link anyone can
  /// share, so honouring an arbitrary template there would make it an open
  /// redirector. A CUSTOM gateway therefore returns null: it still governs the
  /// asset URLs written into the site (client-side, no such risk), while the
  /// stable link falls back to the resolver's default.
  static const Map<String, String> _frontDoorKeys = <String, String>{
    defaultTemplate: 'dweb',
    filebaseTemplate: 'filebase',
  };

  static String? frontDoorGatewayKey([String? template]) =>
      _frontDoorKeys[(template ?? _cachedTemplate).trim()];

  /// Decorate a stored `https://fxfiles.top/w/<name>` link with the active
  /// gateway.
  ///
  /// Applied when the link is READ, never baked in when it is minted: the
  /// pointer is written once and lives for the life of the website, so baking
  /// it would freeze the gateway at whatever was configured that day — the
  /// exact staleness that made the setting look inert for asset URLs.
  ///
  /// A preset emits its key even when it matches the resolver's own default,
  /// rather than leaving the link bare. Omitting it would read as "no
  /// opinion", and the resolver is then free to send the link somewhere else
  /// if its default ever moves — but a user who picked dweb.link in Settings
  /// HAS an opinion, and it should survive that. Bare links stay reserved for
  /// callers that genuinely have none (custom gateways, which the resolver
  /// cannot honour anyway).
  static String decorateFrontDoorUrl(String frontDoorUrl, {String? template}) {
    final key = frontDoorGatewayKey(template);
    if (key == null || frontDoorUrl.isEmpty) return frontDoorUrl;
    final sep = frontDoorUrl.contains('?') ? '&' : '?';
    return '$frontDoorUrl${sep}gw=$key';
  }

  static String _cachedTemplate = defaultTemplate;

  /// Synchronous read of the active template. Populated by [init] at app
  /// startup and refreshed by [updateCache] when settings save.
  static String get cachedTemplate => _cachedTemplate;

  /// Run after [SecureStorageService.init] and before any consumer reads
  /// the gateway. Performs the one-time replacement of the legacy default
  /// — match-and-replace is naturally idempotent, so no migration flag.
  static Future<void> init() async {
    final stored = await SecureStorageService.instance
        .read(SecureStorageKeys.ipfsGatewayUrl);

    if (stored == null || stored.isEmpty || stored == legacyDefault) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.ipfsGatewayUrl,
        defaultTemplate,
      );
      _cachedTemplate = defaultTemplate;
    } else {
      _cachedTemplate = stored;
    }
  }

  /// Refresh the in-memory cache after the user saves a new value in
  /// settings — without this, sync callers (model getters) would keep
  /// returning the old URL until the next app launch.
  static void updateCache(String newTemplate) {
    final trimmed = newTemplate.trim();
    _cachedTemplate = trimmed.isEmpty ? defaultTemplate : trimmed;
  }

  /// Sync URL builder using the cached template.
  static String buildUrlForCid(String cid) => buildUrl(_cachedTemplate, cid);

  /// Pure helper. Subdomain templates carry `{cid}`; path-style templates
  /// receive the CID appended after a single trailing slash.
  static String buildUrl(String template, String cid) {
    if (template.contains('{cid}')) {
      return template.replaceAll('{cid}', cid);
    }
    final base = template.endsWith('/') ? template : '$template/';
    return '$base$cid';
  }
}
