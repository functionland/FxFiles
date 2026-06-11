import 'package:flutter/material.dart';

import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/web/services/web_session.dart';

/// Placeholder home for the web shell (P3). P4 replaces the body with
/// category tiles + bucket browsing.
class WebHomeScreen extends StatelessWidget {
  const WebHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = WebSession.instance;
    final user = session.user;
    return Scaffold(
      appBar: AppBar(
        title: const Text('FxFiles'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => session.signOut(),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_done, size: 64),
            const SizedBox(height: 12),
            Text(
              'Signed in',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            SelectableText(
              'Vault ${user?.id.isNotEmpty == true ? user!.id.substring(0, 8) : '????????'}…',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 4),
            Text(
              FulaApiService.instance.isConfigured
                  ? 'Cloud client configured'
                  : 'Cloud client NOT configured',
            ),
            const SizedBox(height: 16),
            Text(
              'File browsing arrives in the next update.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
