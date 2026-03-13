import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/app_models.dart';
import 'package:fula_files/core/services/app_store_service.dart';
import 'package:fula_files/features/apps/providers/app_provider.dart';

class RestoreScreen extends ConsumerStatefulWidget {
  final String appId;
  final bool showCategoryPicker;

  const RestoreScreen({
    super.key,
    required this.appId,
    this.showCategoryPicker = false,
  });

  @override
  ConsumerState<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends ConsumerState<RestoreScreen> {
  final _selectedCategories = <BackupCategory>{};
  bool _started = false;

  @override
  void initState() {
    super.initState();
    if (!widget.showCategoryPicker) {
      // Auto-start full restore after password prompt
      WidgetsBinding.instance.addPostFrameCallback((_) => _startRestore());
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appProvider);
    final activated = AppStoreService.instance.getActivatedApp(widget.appId);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Restore'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // iOS banner
            if (Platform.isIOS) ...[
              Card(
                color: Colors.blue.withValues(alpha: 0.1),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(LucideIcons.info, color: Colors.blue, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Files will be restored to the FxFiles Documents folder. '
                          'Open the Files app to access them.',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Category picker
            if (widget.showCategoryPicker && !_started) ...[
              Text('Select categories to restore:', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              ...BackupCategory.values.map((cat) {
                return CheckboxListTile(
                  value: _selectedCategories.contains(cat),
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _selectedCategories.add(cat);
                      } else {
                        _selectedCategories.remove(cat);
                      }
                    });
                  },
                  title: Text(_categoryLabel(cat)),
                  secondary: Icon(_categoryIcon(cat)),
                );
              }),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _selectedCategories.isEmpty ? null : _startCategoryRestore,
                child: const Text('Start Restore'),
              ),
            ],

            // Progress
            if (_started || !widget.showCategoryPicker) ...[
              if (appState.isRestoring) ...[
                const SizedBox(height: 24),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 16),
                if (appState.progress != null) ...[
                  LinearProgressIndicator(value: appState.progress!.fraction),
                  const SizedBox(height: 8),
                  Text(
                    '${appState.progress!.completedFiles} / ${appState.progress!.totalFiles} files',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
                if (appState.statusMessage != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    appState.statusMessage!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => ref.read(appProvider.notifier).cancelRestore(),
                  child: const Text('Cancel'),
                ),
              ] else if (appState.error != null) ...[
                const SizedBox(height: 24),
                Icon(LucideIcons.alertCircle, color: Colors.red, size: 48),
                const SizedBox(height: 12),
                Text(
                  'Restore failed',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  appState.error!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ] else if (_started) ...[
                const SizedBox(height: 24),
                const Icon(LucideIcons.checkCircle, color: Colors.green, size: 48),
                const SizedBox(height: 12),
                Text(
                  'Restore complete!',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 8),
                  Text(
                    'For message restore: reinstall WhatsApp and it will detect the restored database.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _startRestore() async {
    // Ensure encryption key is available if password is set
    final unlocked = await _ensureUnlocked();
    if (!unlocked) {
      if (mounted) Navigator.pop(context);
      return;
    }

    setState(() => _started = true);
    ref.read(appProvider.notifier).startRestore(appId: widget.appId);
  }

  Future<void> _startCategoryRestore() async {
    // Ensure encryption key is available if password is set
    final unlocked = await _ensureUnlocked();
    if (!unlocked) return;

    setState(() => _started = true);

    // Restore each selected category
    for (final cat in _selectedCategories) {
      if (!mounted) break;
      await ref.read(appProvider.notifier).startRestore(
        appId: widget.appId,
        category: cat,
      );
    }
  }

  /// If password is set but session key is not cached, prompt once.
  /// Returns true if no password needed or key was successfully verified.
  Future<bool> _ensureUnlocked() async {
    final activated = AppStoreService.instance.getActivatedApp(widget.appId);
    if (activated?.hasPassword != true) return true;

    // Already have the key cached
    if (AppStoreService.instance.hasSessionKey(widget.appId)) return true;

    final password = await _promptPassword();
    if (password == null) return false;

    final valid = await AppStoreService.instance.verifyAppPassword(widget.appId, password);
    if (!valid) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Incorrect password')),
        );
      }
      return false;
    }
    // verifyAppPassword caches the derived key in _sessionKeys + SecureStorage
    return true;
  }

  Future<String?> _promptPassword() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter Password'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Backup password',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  String _categoryLabel(BackupCategory cat) {
    return switch (cat) {
      BackupCategory.messages => 'Messages',
      BackupCategory.images => 'Images',
      BackupCategory.videos => 'Videos',
      BackupCategory.audio => 'Audio',
      BackupCategory.documents => 'Documents',
      BackupCategory.voiceNotes => 'Voice Notes',
      BackupCategory.stickers => 'Stickers',
      BackupCategory.other => 'Other',
    };
  }

  IconData _categoryIcon(BackupCategory cat) {
    return switch (cat) {
      BackupCategory.messages => LucideIcons.messageSquare,
      BackupCategory.images => LucideIcons.image,
      BackupCategory.videos => LucideIcons.video,
      BackupCategory.audio => LucideIcons.music,
      BackupCategory.documents => LucideIcons.fileText,
      BackupCategory.voiceNotes => LucideIcons.mic,
      BackupCategory.stickers => LucideIcons.smile,
      BackupCategory.other => LucideIcons.file,
    };
  }
}
