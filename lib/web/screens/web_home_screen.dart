import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:fula_files/core/models/billing/storage_info.dart';
import 'package:fula_files/core/services/billing_api_service.dart';
import 'package:fula_files/web/services/web_session.dart';

class _Category {
  final String base;
  final String label;
  final IconData icon;
  const _Category(this.base, this.label, this.icon);
}

const _categories = <_Category>[
  _Category('images', 'Photos', Icons.photo_library_outlined),
  _Category('videos', 'Videos', Icons.video_library_outlined),
  _Category('documents', 'Documents', Icons.description_outlined),
  _Category('audio', 'Audio', Icons.library_music_outlined),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('FxFiles'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'Vault ${user != null && user.id.length >= 8 ? user.id.substring(0, 8) : '—'}…',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => WebSession.instance.signOut(),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GridView.count(
                shrinkWrap: true,
                crossAxisCount:
                    MediaQuery.of(context).size.width > 560 ? 4 : 2,
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
            ],
          ),
        ),
      ),
    );
  }
}
