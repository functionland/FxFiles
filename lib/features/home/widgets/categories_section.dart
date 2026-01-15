import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/app/theme/app_theme.dart';
import 'package:fula_files/core/services/tutorial_service.dart';
import 'package:fula_files/core/utils/platform_capabilities.dart';

class CategoriesSection extends StatelessWidget {
  const CategoriesSection({super.key});

  @override
  Widget build(BuildContext context) {
    return TutorialShowcase(
      showcaseKey: TutorialService.instance.categoriesKey,
      stepIndex: 2,
      targetBorderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacing20, vertical: AppTheme.spacing12),
            child: Text(
              'Categories',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(child: _CategoryCard(
                  icon: LucideIcons.image,
                  label: PlatformCapabilities.imagesLabel,
                  color: Colors.green,
                  onTap: () => context.push('/browser', extra: {'category': 'images'}),
                )),
                Expanded(child: _CategoryCard(
                  icon: LucideIcons.video,
                  label: 'Videos',
                  color: Colors.red,
                  onTap: () => context.push('/browser', extra: {'category': 'videos'}),
                )),
                Expanded(child: _CategoryCard(
                  icon: LucideIcons.music,
                  label: 'Audio',
                  color: Colors.orange,
                  onTap: () => context.push('/browser', extra: {'category': 'audio'}),
                )),
                Expanded(child: _CategoryCard(
                  icon: LucideIcons.fileText,
                  label: PlatformCapabilities.documentsLabel,
                  color: Colors.blue,
                  onTap: () => context.push('/browser', extra: {'category': 'documents'}),
                )),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                // Downloads only available on Android (iOS has no Downloads folder)
                if (PlatformCapabilities.hasDownloadsCategory)
                  Expanded(child: _CategoryCard(
                    icon: LucideIcons.download,
                    label: 'Downloads',
                    color: Colors.purple,
                    onTap: () => context.push('/browser', extra: {'category': 'downloads'}),
                  )),
                Expanded(child: _CategoryCard(
                  icon: LucideIcons.archive,
                  label: 'Archives',
                  color: Colors.brown,
                  onTap: () => context.push('/browser', extra: {'category': 'archives'}),
                )),
                Expanded(
                  child: TutorialShowcase(
                    showcaseKey: TutorialService.instance.trashKey,
                    stepIndex: 8,
                    targetBorderRadius: BorderRadius.circular(12),
                    child: _CategoryCard(
                      icon: LucideIcons.trash2,
                      label: 'Trash',
                      color: Colors.grey,
                      onTap: () => context.push('/trash'),
                    ),
                  ),
                ),
                // Add spacer to maintain row layout
                if (PlatformCapabilities.hasDownloadsCategory)
                  const Expanded(child: SizedBox())
                else
                  const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _CategoryCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(AppTheme.spacing4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusS),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppTheme.spacing16, horizontal: AppTheme.spacing8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(AppTheme.spacing12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppTheme.radiusM),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(height: AppTheme.spacing8),
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
