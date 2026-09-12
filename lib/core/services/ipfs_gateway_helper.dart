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

  /// Subdomain-style dweb.link template. The app-wide default until
  /// 2026-09-12, now RETIRED: the IPFS Foundation is shutting this gateway
  /// down for good on 2026-09-21 (gatewaychanges.ipfs.io), and the HTTP 429s
  /// seen beforehand are its announced escalating pauses, not load. Kept as a
  /// constant ONLY so [init] can recognise and migrate anyone still on it.
  static const String dwebTemplate = 'https://{cid}.ipfs.dweb.link/';

  /// Path-style Filebase gateway, and the app-wide default since dweb's
  /// retirement — measured 2026-09-12, a site that returned 429 from dweb.link
  /// returned 200 from Filebase for the same CID at the same moment.
  static const String filebaseTemplate = 'https://ipfs.filebase.io/ipfs/';

  /// fx's own gateway. This was the pre-v0.4 default, and [init] used to
  /// migrate people AWAY from it and onto dweb — that migration is gone,
  /// because the destination is now the thing that is dying. It is offered as
  /// a first-class preset again: it serves these CIDs with correct content
  /// types (verified 2026-09-12) and, unlike any third party, it is ours.
  static const String fxTemplate = 'https://ipfs.cloud.fx.land/gateway/';

  static const String defaultTemplate = filebaseTemplate;

  /// Templates that are dead or dying. A stored value matching one of these is
  /// replaced with [defaultTemplate] on the next [init] — deliberately
  /// overriding what looks like a user's choice, because for most people the
  /// "choice" was just the old default, and leaving it would hand them a
  /// broken site. Match-and-replace is idempotent, so no migration flag.
  static const Set<String> retiredTemplates = <String>{dwebTemplate};

  /// The presets the settings picker offers, in display order. Anything
  /// else the user types is "Custom" — [buildUrl] accepts any template in
  /// either of the two supported shapes. dweb is deliberately ABSENT: offering
  /// a gateway that [init] would migrate away from on next launch is a trap.
  static const Map<String, String> presets = <String, String>{
    'Filebase': filebaseTemplate,
    'fx.land': fxTemplate,
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
    filebaseTemplate: 'filebase',
    fxTemplate: 'fx',
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
  /// rather than leaving the link bare, so that an explicit choice survives a
  /// later change of that default. Bare links stay reserved for callers that
  /// genuinely have no opinion (custom gateways, which the resolver cannot
  /// honour anyway).
  ///
  /// CAVEAT, learned the hard way when dweb.link was retired: freezing the
  /// gateway into a copied link cuts both ways. Every link copied while dweb
  /// was the default carries `?gw=dweb`, and that key had to be dropped from
  /// the resolver's allowlist so those links would fall back instead of
  /// pointing at a dead host. Decorating is right while the set of live
  /// gateways is stable; once a per-site preference exists, prefer bare links
  /// so they keep following the owner's current choice.
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
  /// the gateway.
  ///
  /// Note this WRITES on first run, which is why retiring a default is not
  /// just a matter of changing the constant: every user who has ever launched
  /// the app has the then-current default persisted, so a new [defaultTemplate]
  /// would reach new installs only. [retiredTemplates] is what actually moves
  /// existing users off a dead gateway.
  static Future<void> init() async {
    final stored = await SecureStorageService.instance
        .read(SecureStorageKeys.ipfsGatewayUrl);

    final resolved = resolveStoredTemplate(stored);
    if (resolved != stored) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.ipfsGatewayUrl,
        resolved,
      );
    }
    _cachedTemplate = resolved;
  }

  /// The template [init] should end up with, given what is currently stored.
  ///
  /// Split out as a pure function so the migration is testable without a
  /// storage backend — it is the part that decides whether a user keeps
  /// working after a gateway is retired, which is worth covering directly.
  static String resolveStoredTemplate(String? stored) {
    if (stored == null || stored.trim().isEmpty) return defaultTemplate;
    final trimmed = stored.trim();
    if (retiredTemplates.contains(trimmed)) return defaultTemplate;
    return trimmed;
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
