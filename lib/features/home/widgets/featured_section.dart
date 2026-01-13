import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/app/theme/app_theme.dart';
import 'package:fula_files/core/services/tutorial_service.dart';

class FeaturedSection extends StatelessWidget {
  const FeaturedSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacing20, vertical: AppTheme.spacing12),
          child: Text(
            'Featured',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: TutorialShowcase(
                  showcaseKey: TutorialService.instance.starredKey,
                  stepIndex: 3,
                  targetBorderRadius: BorderRadius.circular(12),
                  child: _FeaturedCard(
                    icon: LucideIcons.star,
                    label: 'Starred',
                    color: Colors.amber,
                    onTap: () => context.push('/browser', extra: {'category': 'starred'}),
                  ),
                ),
              ),
              Expanded(
                child: TutorialShowcase(
                  showcaseKey: TutorialService.instance.cloudKey,
                  stepIndex: 4,
                  targetBorderRadius: BorderRadius.circular(12),
                  child: _FeaturedCard(
                    icon: LucideIcons.cloud,
                    label: 'Cloud',
                    color: Colors.cyan,
                    onTap: () => context.push('/fula'),
                  ),
                ),
              ),
              Expanded(
                child: TutorialShowcase(
                  showcaseKey: TutorialService.instance.sharedKey,
                  stepIndex: 5,
                  targetBorderRadius: BorderRadius.circular(12),
                  child: _FeaturedCard(
                    icon: LucideIcons.share2,
                    label: 'Shared',
                    color: Colors.teal,
                    onTap: () => context.push('/shared'),
                  ),
                ),
              ),
              Expanded(
                child: TutorialShowcase(
                  showcaseKey: TutorialService.instance.playlistsKey,
                  stepIndex: 6,
                  targetBorderRadius: BorderRadius.circular(12),
                  child: _FeaturedCard(
                    icon: LucideIcons.listMusic,
                    label: 'Playlists',
                    color: Colors.deepOrange,
                    onTap: () => context.push('/playlists'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FeaturedCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _FeaturedCard({
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
