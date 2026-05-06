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
