import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/deep_link_service.dart';
import 'package:fula_files/core/services/wallet_service.dart';
import 'package:fula_files/core/services/billing_api_service.dart';
import 'package:fula_files/features/home/widgets/recent_files_section.dart';
import 'package:fula_files/features/home/widgets/categories_section.dart';
import 'package:fula_files/features/home/widgets/featured_section.dart';
import 'package:fula_files/features/home/widgets/storage_section.dart';
import 'package:fula_files/features/billing/providers/storage_provider.dart';
import 'package:fula_files/features/billing/screens/billing_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _setupBannerDismissed = false;
  bool _lowStorageWarningDismissed = false;
  String? _jwtToken;
  bool _isLoadingJwt = true;
  bool _isGettingApiKey = false;
  bool _isLinkingWallet = false;
  StreamSubscription<String>? _apiKeySubscription;

  @override
  void initState() {
    super.initState();
    _loadJwtToken();
    _setupApiKeyListener();
  }

  void _setupApiKeyListener() {
    _apiKeySubscription = DeepLinkService.instance.onApiKeyReceived.listen((apiKey) {
      if (mounted) {
        setState(() {
          _jwtToken = apiKey;
          _isGettingApiKey = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('API Key configured successfully!'),
            backgroundColor: Color(0xFF06B597),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _apiKeySubscription?.cancel();
    super.dispose();
  }
  
  Future<void> _loadJwtToken() async {
    final token = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    if (mounted) {
      setState(() {
        _jwtToken = token;
        _isLoadingJwt = false;
      });

      // Load storage info if JWT is available
      if (token != null && token.isNotEmpty) {
        ref.read(storageProvider.notifier).loadStorageInfo();
      }
    }
  }

  Future<void> _getApiKey(BuildContext context) async {
    setState(() => _isGettingApiKey = true);

    final success = await DeepLinkService.instance.openGetApiKeyPage();

    if (!success && mounted) {
      setState(() => _isGettingApiKey = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open browser. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
    // Note: _isGettingApiKey will be set to false when the API key is received
    // via the deep link callback, or we can add a timeout
  }

  void _cancelGettingApiKey() {
    setState(() => _isGettingApiKey = false);
  }
  
  @override
  Widget build(BuildContext context) {
    final isLoggedIn = AuthService.instance.isAuthenticated;
    final user = AuthService.instance.currentUser;
    final needsSetup = !_isLoadingJwt && (!isLoggedIn || (_jwtToken == null || _jwtToken!.isEmpty));
    final isFullySetup = isLoggedIn && _jwtToken != null && _jwtToken!.isNotEmpty;

    // Watch storage provider for wallet and storage info
    final storageState = ref.watch(storageProvider);
    final showLowStorageWarning = isFullySetup &&
        storageState.isLowStorage &&
        !_lowStorageWarningDismissed &&
        storageState.info != null;

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
          if (_jwtToken != null && _jwtToken!.isNotEmpty) {
            ref.read(storageProvider.notifier).loadStorageInfo();
          }
        },
        child: ListView(
          children: [
            // Low storage warning banner
            if (showLowStorageWarning)
              _buildLowStorageWarning(context, storageState),
            // Setup TODO banner - only show if not fully setup and not dismissed
            if (needsSetup && !_setupBannerDismissed && !isFullySetup)
              _buildSetupBanner(context, isLoggedIn, _jwtToken, storageState),
            const RecentFilesSection(),
            const SizedBox(height: 8),
            const CategoriesSection(),
            const SizedBox(height: 8),
            const FeaturedSection(),
            const SizedBox(height: 8),
            const StorageSection(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
  
  Widget _buildSetupBanner(BuildContext context, bool isLoggedIn, String? jwtToken, StorageState storageState) {
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
        title: 'Set up API Key',
        subtitle: 'Required for cloud storage access',
        action: _isGettingApiKey ? 'Getting...' : 'Get API Key',
        onTap: _isGettingApiKey ? null : () => _getApiKey(context),
        onCancel: _isGettingApiKey ? () => _cancelGettingApiKey() : null,
        isComplete: false,
        isLoading: _isGettingApiKey,
      ));
    } else {
      steps.add(_SetupStep(
        icon: LucideIcons.checkCircle,
        title: 'API Key configured',
        subtitle: 'Cloud storage is ready',
        isComplete: true,
      ));
    }

    // Wallet linking step - only show if API key is configured and no error fetching wallets
    final hasJwt = jwtToken != null && jwtToken.isNotEmpty;
    if (hasJwt && storageState.error == null) {
      if (storageState.wallets.isEmpty) {
        steps.add(_SetupStep(
          icon: LucideIcons.wallet,
          title: 'Link your wallet',
          subtitle: 'Optional: Enable credit purchases',
          action: _isLinkingWallet ? 'Linking...' : 'Link',
          onTap: _isLinkingWallet ? null : () => _linkWallet(),
          onCancel: _isLinkingWallet ? () => _cancelLinkingWallet() : null,
          isComplete: false,
          isLoading: _isLinkingWallet,
        ));
      } else {
        steps.add(_SetupStep(
          icon: LucideIcons.checkCircle,
          title: 'Wallet linked',
          subtitle: storageState.wallets.first.shortAddress,
          isComplete: true,
        ));
      }
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
              step.isLoading
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF06B597),
                          ),
                        ),
                        if (step.onCancel != null) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(LucideIcons.x, size: 18),
                            onPressed: step.onCancel,
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Cancel',
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ],
                    )
                  : TextButton(
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

  Widget _buildLowStorageWarning(BuildContext context, StorageState storageState) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.alertTriangle, color: Colors.orange),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Low Storage',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  '${storageState.info?.formattedRemainingStorage ?? 'Less than 100MB'} remaining. Add credits to continue uploading.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _openBillingOrLinkWallet(storageState),
            child: Text(storageState.hasLinkedWallet ? 'Add Credits' : 'Link Wallet'),
          ),
          IconButton(
            icon: const Icon(LucideIcons.x, size: 18),
            onPressed: () => setState(() => _lowStorageWarningDismissed = true),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  void _openBillingOrLinkWallet(StorageState storageState) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BillingScreen()),
    );
  }

  Future<void> _linkWallet() async {
    setState(() => _isLinkingWallet = true);

    try {
      // Initialize wallet service if needed
      if (!WalletService.instance.isInitialized) {
        await WalletService.instance.initialize(context);
      }

      // Connect wallet
      final address = await WalletService.instance.connectWallet(context);
      if (address == null) {
        setState(() => _isLinkingWallet = false);
        return;
      }

      // Generate and sign message
      final message = WalletService.instance.generateLinkMessage(address);
      final signature = await WalletService.instance.signLinkMessage(message);

      // Link wallet on server
      final chainId = WalletService.instance.connectedChainId ?? 8453;
      await BillingApiService.instance.linkWallet(
        address: address,
        chainId: chainId,
        signature: signature,
        message: message,
      );

      // Refresh storage provider to update wallet list
      ref.read(storageProvider.notifier).loadStorageInfo();

      if (mounted) {
        setState(() => _isLinkingWallet = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Wallet linked successfully!'),
            backgroundColor: Color(0xFF06B597),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLinkingWallet = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to link wallet: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _cancelLinkingWallet() {
    setState(() => _isLinkingWallet = false);
    // Disconnect wallet if connection was in progress
    WalletService.instance.disconnect();
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
  final VoidCallback? onCancel;
  final bool isComplete;
  final bool isLoading;

  const _SetupStep({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
    this.onTap,
    this.onCancel,
    this.isComplete = false,
    this.isLoading = false,
  });
}
