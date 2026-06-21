import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/billing/storage_info.dart';

/// Web "Storage" section (#6) — the bottom-of-home storage indicator,
/// mirroring the native `home/widgets/storage_section.dart` look. The web app
/// is cloud-only, so the native "Phone"/device rows are omitted and the section
/// is a single **Cloud Files** row: a 36×36 primary-tinted cloud icon, the
/// "Cloud Files" label with "used / total" bytes, and a thin progress bar.
/// When [onTap] is set the row is tappable (opens the raw cloud file manager)
/// and shows a chevron affordance.
class WebStorageSection extends StatelessWidget {
  final StorageInfo info;

  /// Opens the Cloud Files manager. When null the row is a plain indicator.
  final VoidCallback? onTap;

  const WebStorageSection({super.key, required this.info, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = info.usagePercentage.clamp(0.0, 1.0);
    final indicator = Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.primaryFaint,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: const Icon(LucideIcons.cloud,
              color: AppColors.primary, size: 18),
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
                      'Cloud Files',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  Text(
                    '${info.formattedCurrentStorage} / '
                    '${info.formattedTotalStorage}',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 4,
                  // The bar is otherwise invisible to screen readers.
                  semanticsLabel: 'Cloud storage usage',
                  backgroundColor: theme.cardColor,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(AppColors.primary),
                ),
              ),
            ],
          ),
        ),
        if (onTap != null) ...[
          const SizedBox(width: 8),
          Icon(Icons.chevron_right,
              size: 20, color: theme.colorScheme.onSurfaceVariant),
        ],
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'STORAGE',
          style: TextStyle(
            fontSize: 12,
            letterSpacing: 1,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        onTap == null
            ? indicator
            : InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: indicator,
                ),
              ),
      ],
    );
  }
}
