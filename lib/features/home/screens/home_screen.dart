import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/features/home/widgets/recent_files_section.dart';
import 'package:fula_files/features/home/widgets/categories_section.dart';
import 'package:fula_files/features/home/widgets/storage_section.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _setupBannerDismissed = false;
  String? _jwtToken;
  bool _isLoadingJwt = true;
  
  @override
  void initState() {
    super.initState();
    _loadJwtToken();
  }
  
  Future<void> _loadJwtToken() async {
    final token = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    if (mounted) {
      setState(() {
        _jwtToken = token;
        _isLoadingJwt = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final isLoggedIn = AuthService.instance.isAuthenticated;
    final user = AuthService.instance.currentUser;
    final needsSetup = !_isLoadingJwt && (!isLoggedIn || (_jwtToken == null || _jwtToken!.isEmpty));
    final isFullySetup = isLoggedIn && _jwtToken != null && _jwtToken!.isNotEmpty;
    
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
          await _loadJwtToken(); // Refresh JWT token state
        },
        child: ListView(
          children: [
            // Setup TODO banner - only show if not fully setup and not dismissed
            if (needsSetup && !_setupBannerDismissed && !isFullySetup)
              _buildSetupBanner(context, isLoggedIn, _jwtToken),
            const RecentFilesSection(),
            const SizedBox(height: 8),
            const CategoriesSection(),
            const SizedBox(height: 8),
            const StorageSection(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
  
  Widget _buildSetupBanner(BuildContext context, bool isLoggedIn, String? jwtToken) {
    final steps = <_SetupStep>[];
    
    if (!isLoggedIn) {
      steps.add(_SetupStep(
        icon: LucideIcons.userCircle,
        title: 'Sign in to your account',
        subtitle: 'Required for cloud sync and sharing',
        action: 'Sign In',
        onTap: () => _showProfileSheet(context),
        isComplete: false,
      ));
    } else {
      steps.add(_SetupStep(
        icon: LucideIcons.checkCircle,
        title: 'Signed in',
        subtitle: AuthService.instance.currentUser?.email ?? '',
        isComplete: true,
      ));
    }
    
    if (jwtToken == null || jwtToken.isEmpty) {
      steps.add(_SetupStep(
        icon: LucideIcons.key,
        title: 'Set up JWT Token',
        subtitle: 'Required for cloud storage access',
        action: 'Go to Settings',
        onTap: () => context.push('/settings'),
        isComplete: false,
      ));
    } else {
      steps.add(_SetupStep(
        icon: LucideIcons.checkCircle,
        title: 'JWT Token configured',
        subtitle: 'Cloud storage is ready',
        isComplete: true,
      ));
    }
    
    final pendingSteps = steps.where((s) => !s.isComplete).toList();
    
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF06B597).withValues(alpha: 0.15),
            const Color(0xFF049B8F).withValues(alpha: 0.08),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF06B597).withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Icon(
                  LucideIcons.listTodo,
                  color: const Color(0xFF06B597),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Complete Setup (${pendingSteps.length} remaining)',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(LucideIcons.x, size: 18),
                  onPressed: () => setState(() => _setupBannerDismissed = true),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Dismiss',
                ),
              ],
            ),
          ),
          ...steps.map((step) => _buildSetupStepTile(context, step)),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
  
  Widget _buildSetupStepTile(BuildContext context, _SetupStep step) {
    return InkWell(
      onTap: step.onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              step.icon,
              size: 20,
              color: step.isComplete 
                  ? const Color(0xFF06B597) 
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.title,
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      decoration: step.isComplete ? TextDecoration.lineThrough : null,
                      color: step.isComplete 
                          ? Theme.of(context).colorScheme.onSurfaceVariant 
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    step.subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (step.action != null && !step.isComplete)
              TextButton(
                onPressed: step.onTap,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF06B597),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: Text(step.action!),
              ),
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

class _SetupStep {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? action;
  final VoidCallback? onTap;
  final bool isComplete;
  
  const _SetupStep({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
    this.onTap,
    this.isComplete = false,
  });
}
