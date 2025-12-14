import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/file_service.dart';
import 'package:fula_files/app/theme/app_theme.dart';

final storageInfoProvider = FutureProvider<List<_StorageInfo>>((ref) async {
  final roots = await FileService.instance.getStorageRoots();
  final result = <_StorageInfo>[];
  
  for (final root in roots) {
    try {
      final stat = await root.stat();
      result.add(_StorageInfo(
        name: root.path.contains('emulated/0') ? 'Internal Storage' : 
              root.path.contains('sdcard') ? 'SD Card' : root.path,
        path: root.path,
        icon: root.path.contains('sdcard') ? LucideIcons.usb : LucideIcons.hardDrive,
        isAvailable: stat.type != FileSystemEntityType.notFound,
      ));
    } catch (_) {
      result.add(_StorageInfo(
        name: root.path,
        path: root.path,
        icon: LucideIcons.hardDrive,
        isAvailable: false,
      ));
    }
  }
  
  return result;
});

class _StorageInfo {
  final String name;
  final String path;
  final IconData icon;
  final bool isAvailable;

  _StorageInfo({
    required this.name,
    required this.path,
    required this.icon,
    required this.isAvailable,
  });
}

class StorageSection extends ConsumerWidget {
  const StorageSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storageAsync = ref.watch(storageInfoProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacing20, vertical: AppTheme.spacing12),
          child: Text(
            'Storage',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        storageAsync.when(
          data: (storages) => Column(
            children: storages.map((storage) => _StorageTile(storage: storage)).toList(),
          ),
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Error loading storage: $e'),
          ),
        ),
        // Trash tile
        ListTile(
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(LucideIcons.trash2, color: Colors.red),
          ),
          title: const Text('Trash'),
          subtitle: const Text('Deleted files'),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () => context.push('/trash'),
        ),
      ],
    );
  }
}

class _StorageTile extends StatelessWidget {
  final _StorageInfo storage;

  const _StorageTile({required this.storage});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(storage.icon, color: Colors.blue),
      ),
      title: Text(storage.name),
      subtitle: Text(storage.path),
      trailing: const Icon(LucideIcons.chevronRight),
      enabled: storage.isAvailable,
      onTap: storage.isAvailable 
        ? () => context.push('/browser', extra: {'path': storage.path})
        : null,
    );
  }
}
