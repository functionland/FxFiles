import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/features/home/widgets/recent_files_section.dart';
import 'package:fula_files/features/home/widgets/categories_section.dart';
import 'package:fula_files/features/home/widgets/storage_section.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final isLoggedIn = AuthService.instance.isAuthenticated;
    final user = AuthService.instance.currentUser;
    
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: isLoggedIn
              ? CircleAvatar(
                  radius: 14,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  backgroundImage: user?.photoUrl != null 
                      ? NetworkImage(user!.photoUrl!) 
                      : null,
                  child: user?.photoUrl == null 
                      ? Text(
                          user?.email.substring(0, 1).toUpperCase() ?? 'U',
                          style: const TextStyle(fontSize: 12, color: Colors.white),
                        )
                      : null,
                )
              : const Icon(LucideIcons.userCircle),
          onPressed: () => _showProfileSheet(context),
        ),
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

  void _showProfileSheet(BuildContext context) {
    final isLoggedIn = AuthService.instance.isAuthenticated;
    final user = AuthService.instance.currentUser;
    
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoggedIn) ...[
                // Signed in - show user info
                CircleAvatar(
                  radius: 32,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  backgroundImage: user?.photoUrl != null 
                      ? NetworkImage(user!.photoUrl!) 
                      : null,
                  child: user?.photoUrl == null 
                      ? Text(
                          user?.email.substring(0, 1).toUpperCase() ?? 'U',
                          style: const TextStyle(fontSize: 24, color: Colors.white),
                        )
                      : null,
                ),
                const SizedBox(height: 12),
                Text(
                  user?.displayName ?? user?.email ?? 'User',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (user?.displayName != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    user!.email,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Signed in with ${user?.provider.name.toUpperCase() ?? 'Unknown'}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(LucideIcons.logOut, color: Colors.red),
                  title: const Text('Sign Out', style: TextStyle(color: Colors.red)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await AuthService.instance.signOut();
                    if (mounted) {
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Signed out')),
                      );
                    }
                  },
                ),
              ] else ...[
                // Not signed in - show sign in options
                const Icon(LucideIcons.userCircle, size: 64, color: Colors.grey),
                const SizedBox(height: 12),
                Text(
                  'Sign in to sync files',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Your files will be backed up to the cloud',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: Image.asset(
                    'assets/icons/google.png',
                    width: 24,
                    height: 24,
                    errorBuilder: (_, __, ___) => const Icon(LucideIcons.mail),
                  ),
                  title: const Text('Sign in with Google'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    try {
                      final user = await AuthService.instance.signInWithGoogle();
                      if (user != null && mounted) {
                        setState(() {});
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Signed in as ${user.email}')),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Sign in failed: $e'), backgroundColor: Colors.red),
                        );
                      }
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(LucideIcons.apple),
                  title: const Text('Sign in with Apple'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    try {
                      final user = await AuthService.instance.signInWithApple();
                      if (user != null && mounted) {
                        setState(() {});
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Signed in as ${user.email}')),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Sign in failed: $e'), backgroundColor: Colors.red),
                        );
                      }
                    }
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
