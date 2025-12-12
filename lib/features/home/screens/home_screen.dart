import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/features/home/widgets/recent_files_section.dart';
import 'package:fula_files/features/home/widgets/categories_section.dart';
import 'package:fula_files/features/home/widgets/storage_section.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FxFiles'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.search),
            onPressed: () => context.push('/search'),
          ),
          IconButton(
            icon: const Icon(LucideIcons.settings),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(recentFilesProvider);
          ref.invalidate(storageInfoProvider);
        },
        child: ListView(
          children: const [
            RecentFilesSection(),
            SizedBox(height: 8),
            CategoriesSection(),
            SizedBox(height: 8),
            StorageSection(),
            SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
