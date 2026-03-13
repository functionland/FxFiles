import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/app_models.dart';
import 'package:fula_files/core/services/app_store_service.dart';
import 'package:fula_files/features/apps/providers/app_provider.dart';

class AppStoreDialog extends ConsumerStatefulWidget {
  const AppStoreDialog({super.key});

  @override
  ConsumerState<AppStoreDialog> createState() => _AppStoreDialogState();
}

class _AppStoreDialogState extends ConsumerState<AppStoreDialog> {
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final filteredApps = AppStoreService.availableApps.where((app) {
      if (_searchQuery.isEmpty) return true;
      return app.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          app.description.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text(
                  'App Store',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search apps...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: GridView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 1.1,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: filteredApps.length,
              itemBuilder: (context, index) {
                final app = filteredApps[index];
                return _AppCard(app: app);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AppCard extends ConsumerWidget {
  final AppDefinition app;

  const _AppCard({required this.app});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActivated = AppStoreService.instance.isAppActivated(app.id);
    final isSupported = app.supportedOnCurrentPlatform;
    final color = Color(app.colorValue);
    final appState = ref.watch(appProvider);

    IconData icon;
    switch (app.iconName) {
      case 'messageCircle':
        icon = LucideIcons.messageCircle;
        break;
      case 'briefcase':
        icon = LucideIcons.briefcase;
        break;
      default:
        icon = LucideIcons.box;
    }

    return Opacity(
      opacity: isSupported ? 1.0 : 0.5,
      child: Card(
        child: InkWell(
          onTap: isSupported && !isActivated && !appState.isActivating
              ? () => _onActivate(context, ref)
              : null,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                const SizedBox(height: 8),
                Text(
                  app.name,
                  style: Theme.of(context).textTheme.labelLarge,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                if (!isSupported)
                  Text(
                    'Not available on this device',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                    ),
                    textAlign: TextAlign.center,
                  )
                else if (isActivated)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Active',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.green,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else
                  Text(
                    'Tap to activate',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onActivate(BuildContext context, WidgetRef ref) async {
    // iOS limitation dialog
    if (Platform.isIOS) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('iOS Limitation'),
          content: const Text(
            'Automatic WhatsApp backup is only available on Android. '
            'iOS does not allow any app to access WhatsApp\'s data.\n\n'
            'You can manually export chats from WhatsApp '
            '(Settings > Chats > Export Chat) and save them to a folder, '
            'then select that folder here to back it up.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Select Folder'),
            ),
          ],
        ),
      );

      if (proceed != true || !context.mounted) return;

      final dirPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select WhatsApp export folder',
      );
      if (dirPath == null || !context.mounted) return;

      await ref.read(appProvider.notifier).activateApp(app.id, iosFolderPath: dirPath);
      if (context.mounted) Navigator.pop(context);
      return;
    }

    // Android / Desktop: direct activation
    await ref.read(appProvider.notifier).activateApp(app.id);
    if (context.mounted) Navigator.pop(context);
  }
}
