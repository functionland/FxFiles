import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

class CategoriesSection extends StatelessWidget {
  const CategoriesSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                label: 'Images',
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
                label: 'Docs',
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
              Expanded(child: _CategoryCard(
                icon: LucideIcons.star,
                label: 'Starred',
                color: Colors.amber,
                onTap: () => context.push('/browser', extra: {'category': 'starred'}),
              )),
              Expanded(child: _CategoryCard(
                icon: LucideIcons.trash2,
                label: 'Trash',
                color: Colors.grey,
                onTap: () => context.push('/trash'),
              )),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(child: _CategoryCard(
                icon: LucideIcons.cloud,
                label: 'Cloud',
                color: Colors.cyan,
                onTap: () => context.push('/fula'),
              )),
              Expanded(child: _CategoryCard(
                icon: LucideIcons.share2,
                label: 'Shared',
                color: Colors.teal,
                onTap: () => context.push('/shared'),
              )),
              const Expanded(child: SizedBox()),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ],
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
      margin: const EdgeInsets.all(4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
