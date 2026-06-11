import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/core/models/billing/storage_info.dart';
import 'package:fula_files/core/services/billing_api_service.dart';
import 'package:fula_files/web/services/web_session.dart';

class _Category {
  final String base;
  final String label;
  final IconData icon;
  const _Category(this.base, this.label, this.icon);
}

/// The native app's six default categories (home screen parity).
/// images/videos/audio/documents route to their -v8 buckets via
/// BucketVersionResolver; downloads/archives are unmanaged and list
/// their plain buckets.
const _categories = <_Category>[
  _Category('images', 'Images', Icons.photo_library_outlined),
  _Category('videos', 'Videos', Icons.video_library_outlined),
  _Category('audio', 'Audio', Icons.library_music_outlined),
  _Category('documents', 'Documents', Icons.description_outlined),
  _Category('downloads', 'Downloads', Icons.download_outlined),
  _Category('archives', 'Archives', Icons.archive_outlined),
];

/// Web home: the four cloud content categories + a storage/credits
/// summary from the billing API. Each tile opens the merged legacy+v8
/// listing for that base bucket.
class WebHomeScreen extends StatefulWidget {
  const WebHomeScreen({super.key});

  @override
  State<WebHomeScreen> createState() => _WebHomeScreenState();
}

class _WebHomeScreenState extends State<WebHomeScreen> {
  late final Future<StorageInfo> _storage =
      BillingApiService.instance.getStorageAndCredits();

  String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final user = WebSession.instance.user;
    final isVault = user?.isVault ?? true;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/icons/icon.png', width: 26, height: 26),
            const SizedBox(width: 8),
            const Text('FxFiles'),
          ],
        ),
        actions: [
          // Profile / settings: account management lives in the cloud
          // portal (billing, wallets, API keys), so this hands off there.
          // OAuth accounts show email + avatar (same CircleAvatar rules
          // as the native home screen); passphrase vaults have no OAuth
          // identity, so they keep the vault-id chip.
          TextButton.icon(
            onPressed: () => launchUrl(
              Uri.parse('https://cloud.fx.land'),
              webOnlyWindowName: '_blank',
            ),
            icon: isVault
                ? const Icon(Icons.manage_accounts_outlined, size: 20)
                : CircleAvatar(
                    radius: 12,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    backgroundImage: user?.photoUrl != null
                        ? NetworkImage(user!.photoUrl!)
                        : null,
                    child: user?.photoUrl == null
                        ? Text(
                            user != null && user.email.isNotEmpty
                                ? user.email.substring(0, 1).toUpperCase()
                                : 'U',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.white),
                          )
                        : null,
                  ),
            label: Text(
              isVault
                  ? 'Vault ${user != null && user.id.length >= 8 ? user.id.substring(0, 8) : '—'}…'
                  : user!.email,
              style: isVault
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
                  : const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => WebSession.instance.signOut(),
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
            ],
          ),
        ),
      ),
      // Scrollable so short (mobile) viewports can reach every tile;
      // Center keeps the tall-viewport layout identical.
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount:
                      MediaQuery.of(context).size.width > 560 ? 3 : 2,
                  padding: const EdgeInsets.all(24),
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  children: [
                  for (final c in _categories)
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => context.go('/b/${c.base}'),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(c.icon, size: 44),
                            const SizedBox(height: 12),
                            Text(c.label,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              // Feature tiles: same card shape as the category tiles,
              // at half their height and 3/4 their width (category
              // cells are ~213 px squares inside the 720 px column).
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final f in const [
                      ('/shelf', 'Shelf', Icons.inbox_outlined),
                      ('/websites', 'Websites', Icons.public),
                      ('/tags', 'Tags', Icons.sell_outlined),
                      ('/playlists', 'Playlists', Icons.queue_music),
                      ('/nfts', 'NFTs', Icons.diamond_outlined),
                    ])
                      SizedBox(
                        width: 160,
                        height: 106,
                        child: Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => context.go(f.$1),
                            child: Column(
                              mainAxisAlignment:
                                  MainAxisAlignment.center,
                              children: [
                                Icon(f.$3, size: 30),
                                const SizedBox(height: 8),
                                Text(f.$2,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              FutureBuilder<StorageInfo>(
                future: _storage,
                builder: (ctx, snap) {
                  if (snap.hasError) {
                    // Quota display is best-effort — never block the home.
                    return const SizedBox.shrink();
                  }
                  if (!snap.hasData) {
                    return Text('Loading storage info…',
                        style: Theme.of(context).textTheme.bodySmall);
                  }
                  final s = snap.data!;
                  final quota = s.freeTierBytes + s.paidStorageBytes;
                  final credits = s.totalCredits - s.usedCredits;
                  return Text(
                    '${_fmtBytes(s.currentStorageBytes)} of '
                    '${_fmtBytes(quota)} used'
                    '${credits > 0 ? '  ·  ${credits.toStringAsFixed(0)} credits' : ''}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  );
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
          ),
        ),
      ),
    );
  }
}
