import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/app_models.dart';
import 'package:fula_files/core/services/app_store_service.dart';
import 'package:fula_files/features/apps/providers/app_provider.dart';
import 'package:fula_files/features/apps/widgets/app_store_dialog.dart';
import 'package:fula_files/shared/utils/adaptive_ui.dart';

class AppsBrowserScreen extends ConsumerWidget {
  const AppsBrowserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appsAsync = ref.watch(activatedAppsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Apps'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAppStore(context, ref),
        child: const Icon(Icons.add),
      ),
      body: appsAsync.when(
        data: (apps) {
          if (apps.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.layoutGrid, size: 64, color: Colors.grey[600]),
                  const SizedBox(height: 16),
                  Text(
                    'No apps activated',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.grey[500],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap + to browse the app store',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: apps.length,
            itemBuilder: (context, index) {
              final activated = apps[index];
              final appDef = AppStoreService.getAppDefinition(activated.appId);
              if (appDef == null) return const SizedBox.shrink();

              final icon = _getIcon(appDef.iconName);
              final color = Color(appDef.colorValue);
              final subtitle = activated.lastBackupAt != null
                  ? 'Last backup: ${_formatTimeAgo(activated.lastBackupAt!)}'
                  : 'No backups yet';

              return ListTile(
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color),
                ),
                title: Text(appDef.name),
                subtitle: Text(subtitle),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'disable') {
                      _confirmDisable(context, ref, activated.appId, appDef.name);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'disable', child: Text('Disable')),
                  ],
                ),
                onTap: () => context.push('/apps/${activated.appId}'),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }

  void _showAppStore(BuildContext context, WidgetRef ref) {
    showAdaptiveSheet(
      context: context,
      builder: (ctx) => const AppStoreDialog(),
    );
  }

  void _confirmDisable(BuildContext context, WidgetRef ref, String appId, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Disable $name?'),
        content: const Text('This will stop automatic backups. Your existing backup data will be preserved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(appProvider.notifier).deactivateApp(appId);
            },
            child: const Text('Disable'),
          ),
        ],
      ),
    );
  }

  IconData _getIcon(String iconName) {
    switch (iconName) {
      case 'messageCircle':
        return LucideIcons.messageCircle;
      case 'briefcase':
        return LucideIcons.briefcase;
      default:
        return LucideIcons.box;
    }
  }

  String _formatTimeAgo(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dateTime.month}/${dateTime.day}/${dateTime.year}';
  }
}
