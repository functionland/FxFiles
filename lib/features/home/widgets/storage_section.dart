import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/billing/storage_info.dart';
import 'package:fula_files/core/services/file_service.dart';
import 'package:fula_files/core/services/tutorial_service.dart';
import 'package:fula_files/features/billing/providers/storage_provider.dart';
import 'package:fula_files/features/billing/screens/billing_screen.dart';
import 'package:fula_files/shared/utils/error_messages.dart';

final storageInfoProvider = FutureProvider<List<_LocalMount>>((ref) async {
  final roots = await FileService.instance.getStorageRoots();
  final result = <_LocalMount>[];
  for (final root in roots) {
    try {
      final stat = await root.stat();
      final isSdCard = root.path.contains('sdcard') || root.path.contains('SDCard');
      final isInternal = root.path.contains('emulated/0') || root.path.contains('Internal');
      final label = isSdCard
          ? 'SD card'
          : isInternal
              ? 'Phone'
              : _prettyLabel(root.path);
      result.add(_LocalMount(
        label: label,
        icon: isSdCard ? LucideIcons.usb : LucideIcons.hardDrive,
        path: root.path,
        isAvailable: stat.type != FileSystemEntityType.notFound,
      ));
    } catch (_) {
      result.add(_LocalMount(
        label: _prettyLabel(root.path),
        icon: LucideIcons.hardDrive,
        path: root.path,
        isAvailable: false,
      ));
    }
  }
  return result;
});

String _prettyLabel(String rawPath) {
  // Fallback: friendly name derived from the last meaningful segment, no full path.
  final segments = rawPath.split(RegExp(r'[\\/]'))
    ..removeWhere((s) => s.isEmpty);
  if (segments.isEmpty) return 'Storage';
  final last = segments.last;
  if (last.length <= 3) return 'Storage';
  return last[0].toUpperCase() + last.substring(1);
}

class _LocalMount {
  final String label;
  final IconData icon;
  final String path;
  final bool isAvailable;
  const _LocalMount({
    required this.label,
    required this.icon,
    required this.path,
    required this.isAvailable,
  });
}

class StorageSection extends ConsumerWidget {
  const StorageSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mountsAsync = ref.watch(storageInfoProvider);
    final cloudState = ref.watch(storageProvider);

    return TutorialShowcase(
      showcaseKey: TutorialService.instance.storageKey,
      stepIndex: 5,
      targetBorderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'STORAGE',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 1,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            mountsAsync.when(
              data: (mounts) => Column(
                children: mounts
                    .map((m) => _StorageBar(
                          label: m.label,
                          icon: m.icon,
                          onTap: m.isAvailable
                              ? () => context.push('/browser', extra: {'path': m.path})
                              : null,
                        ))
                    .toList(),
              ),
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(8),
                child: Text(ErrorMessages.getUserFriendlyMessage(e, context: 'load storage')),
              ),
            ),
            if (cloudState.info != null)
              _StorageBar(
                label: 'Cloud',
                icon: LucideIcons.cloud,
                tone: _StorageTone.primary,
                info: cloudState.info,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BillingScreen()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _StorageTone { neutral, primary }

class _StorageBar extends StatelessWidget {
  final String label;
  final IconData icon;
  final StorageInfo? info;
  final VoidCallback? onTap;
  final _StorageTone tone;

  const _StorageBar({
    required this.label,
    required this.icon,
    this.info,
    this.onTap,
    this.tone = _StorageTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPrimary = tone == _StorageTone.primary;
    final iconBg = isPrimary ? AppColors.primaryFaint : theme.cardColor;
    final iconColor = isPrimary ? AppColors.primary : theme.colorScheme.onSurface;
    final dividerColor = theme.dividerColor.withValues(alpha: 0.4);

    final hasBar = info != null;
    final pct = info == null ? 0.0 : info!.usagePercentage.clamp(0.0, 1.0);
    final usedStr = info == null ? null : info!.formattedCurrentStorage;
    final totalStr = info == null ? null : info!.formattedTotalStorage;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: dividerColor)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: iconColor, size: 18),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      if (usedStr != null && totalStr != null)
                        Text(
                          '$usedStr / $totalStr',
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  if (hasBar) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: pct,
                        minHeight: 4,
                        backgroundColor: theme.cardColor,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isPrimary ? AppColors.primary : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!hasBar)
              Icon(LucideIcons.chevronRight,
                  size: 14, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
