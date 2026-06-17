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
  late final Future<StorageInfo> _storage =
      BillingApiService.instance.getStorageAndCredits();

  @override
  void initState() {
    super.initState();
    // Kick the background cache warmer once home has rendered. It
    // self-delays per device class (§8.1), yields to every foreground
    // operation, and is idempotent across home revisits.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WebPrefetchScheduler.instance.start();
    });
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
        leading: IconButton(
          tooltip: 'Profile',
          onPressed: _showProfileSheet,
          icon: _profileAvatar(context),
        ),
        title: const Text('FxFiles'),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => context.go('/search'),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.go('/settings'),
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
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                // Recent strip (issue #17) — hides itself when empty.
                const WebRecentFilesSection(),
                _onYourCloudSection(context),
                _createSection(context),
                _moreSection(context),
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
                            style: Theme.of(context).textTheme.bodySmall);
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
                    onTap: () => context.go('/b/images'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 10,
                  child: _HeroTile(
                    icon: LucideIcons.video,
                    label: 'Videos',
                    onTap: () => context.go('/b/videos'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 10,
                  child: _HeroTile(
                    icon: LucideIcons.music,
                    label: 'Audio',
                    onTap: () => context.go('/b/audio'),
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
                  onTap: () => context.go('/b/documents'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SmallTile(
                  icon: LucideIcons.download,
                  label: 'Downloads',
                  onTap: () => context.go('/b/downloads'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SmallTile(
                  icon: LucideIcons.archive,
                  label: 'Archives',
                  onTap: () => context.go('/b/archives'),
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
                  onTap: () => context.go('/websites'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CreateTile(
                  icon: LucideIcons.gem,
                  label: 'NFT',
                  badge: 'mint & share',
                  onTap: () => context.go('/nfts'),
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
                  onTap: () => context.go('/shelf'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CreateTile(
                  icon: LucideIcons.zap,
                  label: 'Automate',
                  badge: 'CSV → bulk send',
                  onTap: () => context.go('/automate-tasks'),
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
            onTap: () => context.go('/shared'),
          ),
          _MoreRow(
            icon: LucideIcons.tags,
            label: 'Tags',
            subtitle: 'Organize by label',
            onTap: () => context.go('/tags'),
          ),
          _MoreRow(
            icon: LucideIcons.listMusic,
            label: 'Playlists',
            subtitle: 'Audio collections',
            onTap: () => context.go('/playlists'),
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
