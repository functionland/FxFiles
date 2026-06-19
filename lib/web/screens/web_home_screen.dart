import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/billing/storage_info.dart';
import 'package:fula_files/core/services/billing_api_service.dart';
import 'package:fula_files/web/screens/web_settings_screen.dart' show kWebAppVersion;
import 'package:fula_files/web/services/web_prefetch_scheduler.dart';
import 'package:fula_files/web/services/web_session.dart';
import 'package:fula_files/web/widgets/web_login_bar.dart';
import 'package:fula_files/web/widgets/web_login_sheet.dart';
import 'package:fula_files/web/widgets/web_recent_files_section.dart';
import 'package:fula_files/web/widgets/web_storage_section.dart';

/// Web home — mirror of the native home screen's section layout
/// (lib/features/home/widgets/on_this_phone_section.dart,
/// create_section.dart, more_section.dart): the category hero/small
/// tiles under "On your cloud" (the web's files ARE the cloud, so the
/// header changes from the app's "On this phone"), the CREATE 2×2
/// tiles (Website / NFT / Shelf / Automate), and the MORE rows
/// (Shared / Tags / Playlists), plus the storage line and footer.
class WebHomeScreen extends StatefulWidget {
  const WebHomeScreen({super.key});

  @override
  State<WebHomeScreen> createState() => _WebHomeScreenState();
}

class _WebHomeScreenState extends State<WebHomeScreen> {
  /// Storage/credits for the signed-in user. Null while logged out (the
  /// billing API requires auth) — set by [_initSignedIn] on sign-in.
  Future<StorageInfo>? _storage;

  /// True while the login bottom sheet is on screen (suppresses the top
  /// WebLoginBar and prevents a double-open).
  bool _loginSheetOpen = false;

  @override
  void initState() {
    super.initState();
    WebSession.instance.addListener(_onSession);
    if (WebSession.instance.isSignedIn) {
      _initSignedIn();
    }
    // After first paint: when logged out, auto-present the cancelable login
    // sheet (signed-in initializers ran above via _initSignedIn).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoOpenLogin();
    });
  }

  @override
  void dispose() {
    WebSession.instance.removeListener(_onSession);
    super.dispose();
  }

  /// Initializers that must NOT run while signed out (they hit auth-required
  /// backends): the storage/credits fetch + the background cache warmer.
  /// Re-run when the session transitions to signed-in.
  void _initSignedIn() {
    _storage = BillingApiService.instance.getStorageAndCredits();
    // Self-delays per device class (§8.1), yields to foreground ops, and is
    // idempotent across home revisits.
    WebPrefetchScheduler.instance.start();
  }

  void _onSession() {
    if (!mounted) return;
    final signedIn = WebSession.instance.isSignedIn;
    if (signedIn) {
      if (_storage == null) _initSignedIn();
    } else {
      // Signed out: drop the now-unauthorized storage future so a later
      // sign-in re-fetches it.
      _storage = null;
    }
    setState(() {});
    // After sign-out (or a cross-tab sign-out) re-present the login prompt;
    // WebSession.signOut already re-armed loginPromptDismissed.
    if (!signedIn) _maybeAutoOpenLogin();
  }

  /// Auto-open the login sheet unless it's already showing, the user already
  /// dismissed it this session, or they're signed in.
  void _maybeAutoOpenLogin() {
    if (!mounted || _loginSheetOpen) return;
    if (WebSession.instance.isSignedIn) return;
    if (WebSession.instance.loginPromptDismissed) return;
    _openLoginSheet();
  }

  /// Present the login sheet. Used by auto-open, the top WebLoginBar, the
  /// logged-out profile button, and logged-out navigation ([_go]). Explicit
  /// opens ignore `loginPromptDismissed` (only auto-open respects it).
  Future<void> _openLoginSheet() async {
    if (_loginSheetOpen || WebSession.instance.isSignedIn) return;
    setState(() => _loginSheetOpen = true);
    await WebLoginSheet.show(context);
    if (!mounted) return;
    setState(() {
      _loginSheetOpen = false;
      // Closed while still signed out ⇒ the user cancelled. Remember it (on
      // WebSession, so it survives this widget being rebuilt on navigation)
      // so we don't immediately re-present it; the top WebLoginBar lets them
      // re-open it. Reset on sign-out.
      if (!WebSession.instance.isSignedIn) {
        WebSession.instance.loginPromptDismissed = true;
      }
    });
  }

  /// Navigate when signed in; otherwise present the login sheet — a logged-out
  /// tap on a cloud action is a clear "log in to continue" prompt rather than
  /// a silent bounce back home via the router gate.
  void _go(String route) {
    if (WebSession.instance.isSignedIn) {
      context.go(route);
    } else {
      _openLoginSheet();
    }
  }

  /// Same CircleAvatar rules as the native home screen: OAuth photo →
  /// image; else email initial; passphrase vaults get a person glyph.
  Widget _profileAvatar(BuildContext context, {double radius = 14}) {
    final user = WebSession.instance.user;
    final isVault = user?.isVault ?? true;
    return CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.primary,
      backgroundImage: !isVault && user?.photoUrl != null
          ? NetworkImage(user!.photoUrl!)
          : null,
      child: !isVault && user?.photoUrl != null
          ? null
          : isVault
              ? Icon(Icons.person_outline,
                  size: radius + 2, color: Colors.white)
              : Text(
                  user != null && user.email.isNotEmpty
                      ? user.email.substring(0, 1).toUpperCase()
                      : 'U',
                  style: TextStyle(
                      fontSize: radius - 3, color: Colors.white),
                ),
    );
  }

  /// Native-parity profile sheet: identity on top, sign out below.
  void _showProfileSheet() {
    final user = WebSession.instance.user;
    final isVault = user?.isVault ?? true;
    final identity = isVault
        ? 'Vault ${user != null && user.id.length >= 8 ? user.id.substring(0, 8) : '—'}…'
        : (user?.email ?? '');
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: _profileAvatar(ctx, radius: 20),
              title: Text(
                identity,
                style: isVault
                    ? const TextStyle(fontFamily: 'monospace')
                    : null,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: !isVault &&
                      (user?.displayName?.isNotEmpty ?? false)
                  ? Text(user!.displayName!)
                  : null,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign out'),
              onTap: () {
                Navigator.pop(ctx);
                WebSession.instance.signOut();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Native-parity header that survives narrow phones: profile
      // avatar (left, opens the identity/sign-out sheet), plain
      // "FxFiles" title (no logo), settings (right → cloud portal).
      appBar: AppBar(
        leading: WebSession.instance.isSignedIn
            ? IconButton(
                tooltip: 'Profile',
                onPressed: _showProfileSheet,
                icon: _profileAvatar(context),
              )
            : IconButton(
                tooltip: 'Sign in',
                onPressed: _openLoginSheet,
                icon: const Icon(Icons.account_circle_outlined),
              ),
        title: const Text('FxFiles'),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => _go('/search'),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _go('/settings'),
          ),
          const SizedBox(width: 4),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => launchUrl(
                  Uri.parse('https://fx.land'),
                  webOnlyWindowName: '_blank',
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Made with ',
                          style: Theme.of(context).textTheme.bodySmall),
                      const Icon(Icons.favorite,
                          size: 13, color: Colors.redAccent),
                      Text(' by Functionland',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('·', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: 8),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => launchUrl(
                  Uri.parse('https://github.com/functionland/FxFiles'),
                  webOnlyWindowName: '_blank',
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.github,
                          size: 13,
                          color: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.color),
                      const SizedBox(width: 4),
                      Text('GitHub',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Subtle build/version stamp next to the GitHub link.
              Text(
                kWebAppVersion,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.color
                          ?.withValues(alpha: 0.45),
                    ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          // Top "sign in" bar: logged out AND the sheet is closed (i.e. the
          // user cancelled it). Tap re-opens the sheet. Full-width, directly
          // below the AppBar — mirrors the native SetupStatusBar placement.
          if (!WebSession.instance.isSignedIn &&
              !_loginSheetOpen &&
              WebSession.instance.loginPromptDismissed)
            WebLoginBar(onTap: _openLoginSheet),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      // Recent strip (issue #17) — hides itself when empty
                      // (and is empty while logged out → renders nothing).
                      const WebRecentFilesSection(),
                      _onYourCloudSection(context),
                      _createSection(context),
                      _moreSection(context),
                      // Storage line — signed-in only (billing needs auth).
                      if (_storage != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: FutureBuilder<StorageInfo>(
                            future: _storage,
                            builder: (ctx, snap) {
                              if (snap.hasError) {
                                // Quota display is best-effort — never block home.
                                return const SizedBox.shrink();
                              }
                              if (!snap.hasData) {
                                return Text('Loading storage info…',
                                    style:
                                        Theme.of(context).textTheme.bodySmall);
                              }
                              // Storage indicator like mobile (#6): a "STORAGE"
                              // section with a Cloud progress bar (web omits Phone).
                              return WebStorageSection(info: snap.data!);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------- "On your cloud"
  // Mirror of OnThisPhoneSection: a 130px hero row (Images wider,
  // primary-tinted icon; Videos; Audio) over a small-tile row
  // (Documents / Downloads / Archives).

  Widget _onYourCloudSection(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(label: 'On your cloud'),
          const SizedBox(height: 8),
          SizedBox(
            height: 130,
            child: Row(
              children: [
                Expanded(
                  flex: 14,
                  child: _HeroTile(
                    icon: LucideIcons.image,
                    label: 'Images',
                    iconColor: AppColors.primary,
                    onTap: () => _go('/b/images'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 10,
                  child: _HeroTile(
                    icon: LucideIcons.video,
                    label: 'Videos',
                    onTap: () => _go('/b/videos'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 10,
                  child: _HeroTile(
                    icon: LucideIcons.music,
                    label: 'Audio',
                    onTap: () => _go('/b/audio'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _SmallTile(
                  icon: LucideIcons.fileText,
                  label: 'Documents',
                  onTap: () => _go('/b/documents'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SmallTile(
                  icon: LucideIcons.download,
                  label: 'Downloads',
                  onTap: () => _go('/b/downloads'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SmallTile(
                  icon: LucideIcons.archive,
                  label: 'Archives',
                  onTap: () => _go('/b/archives'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------- CREATE
  // Mirror of CreateSection's 2×2 badge tiles. On the web, Automate's
  // sends go through universal links (wa.me / t.me / mailto: / sms:).

  Widget _createSection(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(label: 'Create'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _CreateTile(
                  icon: LucideIcons.globe,
                  label: 'Website',
                  badge: 'beta',
                  onTap: () => _go('/websites'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CreateTile(
                  icon: LucideIcons.gem,
                  label: 'NFT',
                  badge: 'mint & share',
                  onTap: () => _go('/nfts'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _CreateTile(
                  icon: LucideIcons.inbox,
                  label: 'Shelf',
                  badge: 'share to FxFiles',
                  onTap: () => _go('/shelf'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CreateTile(
                  icon: LucideIcons.zap,
                  label: 'Automate',
                  badge: 'CSV → bulk send',
                  onTap: () => _go('/automate-tasks'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- MORE
  // Mirror of MoreSection's rows (Apps and Trash stay native).

  Widget _moreSection(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(label: 'More'),
          const SizedBox(height: 4),
          _MoreRow(
            icon: LucideIcons.share2,
            label: 'Shared',
            subtitle: 'Shares & collaborations',
            onTap: () => _go('/shared'),
          ),
          _MoreRow(
            icon: LucideIcons.tags,
            label: 'Tags',
            subtitle: 'Organize by label',
            onTap: () => _go('/tags'),
          ),
          _MoreRow(
            icon: LucideIcons.listMusic,
            label: 'Playlists',
            subtitle: 'Audio collections',
            onTap: () => _go('/playlists'),
          ),
        ],
      ),
    );
  }
}

// Mirrored support widgets — same metrics as the native home widgets.

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 1,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _HeroTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? iconColor;
  final VoidCallback onTap;
  const _HeroTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = iconColor ?? theme.colorScheme.onSurfaceVariant;
    return Material(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: color, size: 22),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SmallTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  color: theme.colorScheme.onSurfaceVariant, size: 18),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String badge;
  final VoidCallback onTap;

  const _CreateTile({
    required this.icon,
    required this.label,
    required this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = theme.dividerColor.withValues(alpha: 0.4);
    return Material(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(icon, color: AppColors.primary, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      badge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoreRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  const _MoreRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(icon,
                  color: theme.colorScheme.onSurfaceVariant, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(LucideIcons.chevronRight,
                size: 14, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
