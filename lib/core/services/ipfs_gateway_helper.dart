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

  /// Subdomain-style dweb.link template — the app-wide default until
  /// 2026-09-12, now retired: the IPFS Foundation shuts it down on 2026-09-21
  /// (gatewaychanges.ipfs.io), and the HTTP 429s seen beforehand were its
  /// escalating pauses rather than load. Kept only so [retiredTemplates] can
  /// recognise and migrate anyone still holding it.
  static const String dwebTemplate = 'https://{cid}.ipfs.dweb.link/';

  /// dweb.link's successor: a SERVICE-WORKER gateway. dweb.link already
  /// redirects here, so this is where that traffic ends up either way.
  ///
  /// Three things make it different from every other option, all measured
  /// 2026-09-12:
  ///  * It is BROWSER-ONLY. A request without a browser User-Agent gets 403
  ///    (pointing at the self-hosting guide). So social-preview crawlers,
  ///    indexers and any programmatic fetch are refused — a link shared here
  ///    renders for a human but shows no preview card.
  ///  * The page it returns is an ~11KB bootstrap, not the content; a service
  ///    worker fetches the real bytes client-side.
  ///  * It is SUBDOMAIN-style, so a site's relative asset references cannot
  ///    reach the assets (they live on another host). The published fallback
  ///    chain recovers them from an absolute gateway instead — the site is
  ///    fine, but the gateway choice moves only the page, not its images.
  static const String inbrowserTemplate = 'https://{cid}.ipfs.inbrowser.link/';

  /// Path-style Filebase gateway, and the app-wide default since dweb's
  /// retirement — measured 2026-09-12, a site that returned 429 from dweb.link
  /// returned 200 from Filebase for the same CID at the same moment.
  static const String filebaseTemplate = 'https://ipfs.filebase.io/ipfs/';

  /// fx's own gateway.
  ///
  /// NOT offered in the picker: it serves an interstitial "content withheld"
  /// page before HTML (measured 2026-09-12 in a browser — curl bypasses it),
  /// which is a poor thing to put in front of someone opening a shared
  /// website, and is almost certainly why it stopped being the default.
  ///
  /// It remains useful, and is kept, because raw ASSETS are served normally
  /// (correct `image/jpeg`, no interstitial): it is the second entry in the
  /// published fallback chain, so a site is never at the mercy of one third
  /// party. Also still accepted as a `?gw=fx` key on the resolver.
  static const String fxTemplate = 'https://ipfs.cloud.fx.land/gateway/';

  static const String defaultTemplate = filebaseTemplate;

  /// Templates that are dead or dying. A stored value matching one of these is
  /// replaced with [defaultTemplate] on the next [init] — deliberately
  /// overriding what looks like a user's choice, because for most people such
  /// a "choice" is just an old default. Match-and-replace is idempotent, so no
  /// migration flag.
  ///
  /// dweb is here and NOT in [presets] — that pairing is the rule. A template
  /// that is both offered and migrated away from would silently revert on the
  /// next launch, which is why the two sets must never intersect (pinned by a
  /// test). Its successor [inbrowserTemplate] is what the picker offers now.
  static const Set<String> retiredTemplates = <String>{dwebTemplate};

  /// The presets the settings picker offers, in display order. Anything else
  /// the user types is "Custom" — [buildUrl] accepts any template in either of
  /// the two supported shapes. Filebase is first because it is the default.
  static const Map<String, String> presets = <String, String>{
    'Filebase': filebaseTemplate,
    'inbrowser.link': inbrowserTemplate,
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
    inbrowserTemplate: 'inbrowser',
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
