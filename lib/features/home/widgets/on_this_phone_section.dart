import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/services/tutorial_service.dart';
import 'package:fula_files/core/utils/platform_capabilities.dart';

class OnThisPhoneSection extends StatelessWidget {
  const OnThisPhoneSection({super.key});

  @override
  Widget build(BuildContext context) {
    return TutorialShowcase(
      showcaseKey: TutorialService.instance.categoriesKey,
      stepIndex: 2,
      targetBorderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(label: 'On this phone'),
            const SizedBox(height: 8),
            SizedBox(
              height: 130,
              child: Row(
                children: [
                  Expanded(
                    flex: 14,
                    child: _HeroTile(
                      icon: LucideIcons.image,
                      label: PlatformCapabilities.imagesLabel,
                      iconColor: AppColors.primary,
                      onTap: () => context.push('/browser', extra: {'category': 'images'}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 10,
                    child: _HeroTile(
                      icon: LucideIcons.video,
                      label: 'Videos',
                      onTap: () => context.push('/browser', extra: {'category': 'videos'}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 10,
                    child: _HeroTile(
                      icon: LucideIcons.music,
                      label: 'Audio',
                      onTap: () => context.push('/browser', extra: {'category': 'audio'}),
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
                    label: PlatformCapabilities.documentsLabel,
                    onTap: () => context.push('/browser', extra: {'category': 'documents'}),
                  ),
                ),
                if (PlatformCapabilities.hasDownloadsCategory) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SmallTile(
                      icon: LucideIcons.download,
                      label: 'Downloads',
                      onTap: () => context.push('/browser', extra: {'category': 'downloads'}),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                Expanded(
                  child: _SmallTile(
                    icon: LucideIcons.archive,
                    label: 'Archives',
                    onTap: () => context.push('/browser', extra: {'category': 'archives'}),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final Widget? trailing;
  const _SectionHeader({required this.label, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 1,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
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
              Icon(icon, color: theme.colorScheme.onSurfaceVariant, size: 18),
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
