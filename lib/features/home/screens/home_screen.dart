import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:showcaseview/showcaseview.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/deep_link_service.dart';
import 'package:fula_files/core/services/wallet_service.dart' show WalletService, walletNavigatorKey;
import 'package:fula_files/core/services/billing_api_service.dart';
import 'package:fula_files/core/services/tutorial_service.dart';
import 'package:fula_files/features/home/widgets/recent_files_section.dart';
import 'package:fula_files/features/home/widgets/on_this_phone_section.dart';
import 'package:fula_files/features/home/widgets/in_the_cloud_section.dart';
import 'package:fula_files/features/home/widgets/create_section.dart';
import 'package:fula_files/features/home/widgets/more_section.dart';
import 'package:fula_files/features/home/widgets/storage_section.dart';
import 'package:fula_files/features/home/widgets/setup_status_bar.dart';
import 'package:fula_files/features/home/widgets/setup_unlock_sheet.dart';
import 'package:fula_files/features/billing/providers/storage_provider.dart';
import 'package:fula_files/features/sharing/providers/sharing_provider.dart';
import 'package:fula_files/features/sharing/providers/collaboration_provider.dart';
import 'package:fula_files/features/billing/screens/billing_screen.dart';
import 'package:fula_files/features/settings/providers/settings_provider.dart';
import 'package:fula_files/shared/utils/error_messages.dart';
import 'package:fula_files/shared/utils/adaptive_ui.dart';
import 'package:fula_files/core/services/nft_wallet_service.dart';
import 'package:fula_files/core/utils/platform_capabilities.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _lowStorageWarningDismissed = false;
  String? _jwtToken;
  bool _isLoadingJwt = true;
  bool _isGettingApiKey = false;
  bool _isLinkingWallet = false;
  bool _setupSheetOpen = false;
  bool _setupSheetUserDismissed = false;
  bool _autoOpenAttempted = false;
  StreamSubscription<String>? _apiKeySubscription;
  StreamSubscription<String>? _orgNameSubscription;
  StreamSubscription? _authSubscription;

  @override
  void initState() {
    super.initState();
    _loadJwtToken();
    _setupApiKeyListener();
    _setupOrgNameListener();
    _authSubscription = AuthService.instance.authStateChanges.listen((_) {
      if (mounted) setState(() {});
    });
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

  void _setupOrgNameListener() {
    _orgNameSubscription = DeepLinkService.instance.onOrgNameReceived.listen((orgName) {
      if (mounted) {
        // Update the settings provider with the new org name
        ref.read(settingsProvider.notifier).setOrgName(orgName);
      }
    });
  }

  @override
  void dispose() {
    _apiKeySubscription?.cancel();
    _orgNameSubscription?.cancel();
    _authSubscription?.cancel();
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

      // Try to ensure auth state is restored before deciding whether to nag
      // about setup, so we don't auto-open the sheet on a stale "logged out"
      // reading right after launch.
      _scheduleAutoOpenSetupIfNeeded();
    }
  }

  Future<void> _scheduleAutoOpenSetupIfNeeded() async {
    if (_autoOpenAttempted) return;
    _autoOpenAttempted = true;
    // Brief delay so providers and AuthService can settle.
    await AuthService.instance.ensureAuthRestored();
    if (!mounted) return;
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    _maybeAutoOpenSetup();
  }

  void _maybeAutoOpenSetup() {
    if (!mounted) return;
    if (_setupSheetOpen) return;
    if (_setupSheetUserDismissed) return;
    final isLoggedIn = AuthService.instance.isAuthenticated;
    final hasJwt = _jwtToken != null && _jwtToken!.isNotEmpty;
    final mandatoryIncomplete = !isLoggedIn || !hasJwt;
    if (!mandatoryIncomplete) return;
    _openSetupUnlockSheet(context);
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
      return;
    }
    // No auto-cancel: the deep-link stream (_setupApiKeyListener) closes the
    // spinner when the browser callback arrives. Users can cancel manually.
  }

  void _cancelGettingApiKey() {
    setState(() => _isGettingApiKey = false);
  }
  
  @override
  Widget build(BuildContext context) {
    final isLoggedIn = AuthService.instance.isAuthenticated;
    final user = AuthService.instance.currentUser;

    // Watch settings provider for org name
    final settings = ref.watch(settingsProvider);
    final appTitle = settings.orgName != null && settings.orgName!.isNotEmpty
        ? 'FxFiles ${settings.orgName}'
        : 'FxFiles';

    // Watch storage provider for wallet and storage info
    final storageState = ref.watch(storageProvider);

    // Check if any setup step is incomplete
    final hasJwt = _jwtToken != null && _jwtToken!.isNotEmpty;
    final hasWallet = storageState.wallets.isNotEmpty;
    final hasAnyWallet = hasWallet || NftWalletService.instance.hasWallet;

    // Show setup banner only while a mandatory step (sign-in or cloud) is
    // incomplete. Linking a wallet is optional and shouldn't keep the bar up.
    final needsSetup = !_isLoadingJwt && (!isLoggedIn || !hasJwt);
    final isFullySetup = isLoggedIn && hasJwt && hasAnyWallet;

    final showLowStorageWarning = isLoggedIn && hasJwt &&
        storageState.isLowStorage &&
        !_lowStorageWarningDismissed &&
        storageState.info != null;

    return ShowCaseWidget(
      enableAutoScroll: true,
      onStart: (index, key) {
        TutorialService.instance.setTutorialActive(true);
      },
      onComplete: (index, key) {
        // Handled by TutorialShowcase buttons
      },
      onFinish: () {
        TutorialService.instance.setTutorialActive(false);
      },
      builder: (context) => Scaffold(
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
            tooltip: 'Profile',
            onPressed: () => _showProfileSheet(context),
          ),
          title: Text(appTitle),
          actions: [
            if (!Platform.isIOS)
              TutorialShowcase(
                showcaseKey: TutorialService.instance.searchKey,
                stepIndex: 8,
                targetShapeBorder: const CircleBorder(),
                child: IconButton(
                  icon: const Icon(LucideIcons.search),
                  tooltip: 'Search',
                  onPressed: () => context.push('/search'),
                ),
              ),
            IconButton(
              icon: Icon(
                LucideIcons.helpCircle,
                color: TutorialService.instance.isTutorialActive
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              tooltip: 'Tutorial',
              onPressed: () => _startTutorial(context),
            ),
            TutorialShowcase(
              showcaseKey: TutorialService.instance.settingsKey,
              stepIndex: 7,
              targetShapeBorder: const CircleBorder(),
              child: IconButton(
                icon: const Icon(LucideIcons.settings),
                tooltip: 'Settings',
                onPressed: () => context.push('/settings'),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            if (needsSetup)
              TutorialShowcase(
                showcaseKey: TutorialService.instance.setupBannerKey,
                stepIndex: 0,
                targetBorderRadius: BorderRadius.zero,
                child: SetupStatusBar(
                  stepsLeft: _pendingStepCount(isLoggedIn, hasJwt),
                  stepsDone: 2 - _pendingStepCount(isLoggedIn, hasJwt),
                  stepsTotal: 2,
                  onTap: () => _openSetupUnlockSheet(context),
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(recentFilesProvider);
                  ref.invalidate(storageInfoProvider);
                  await _loadJwtToken();
                  if (_jwtToken != null && _jwtToken!.isNotEmpty) {
                    ref.read(storageProvider.notifier).loadStorageInfo();
                  }
                },
                child: ListView(
                  children: [
                    if (showLowStorageWarning)
                      _buildLowStorageWarning(context, storageState),
                    TutorialShowcase(
                      showcaseKey: TutorialService.instance.recentFilesKey,
                      stepIndex: 1,
                      targetBorderRadius: BorderRadius.circular(12),
                      child: const RecentFilesSection(),
                    ),
                    const OnThisPhoneSection(),
                    CreateSection(
                      isWebsiteEnabled: isLoggedIn && hasJwt,
                      isNftEnabled: isLoggedIn && hasJwt && hasAnyWallet,
                      onLockedTap: () => _openSetupUnlockSheet(context),
                    ),
                    const InTheCloudSection(),
                    const MoreSection(),
                    const StorageSection(),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _pendingStepCount(bool isLoggedIn, bool hasJwt) {
    var n = 0;
    if (!isLoggedIn) n++;
    if (!hasJwt) n++;
    return n;
  }

  Future<void> _openSetupUnlockSheet(BuildContext context) async {
    if (_setupSheetOpen) return;
    _setupSheetOpen = true;
    final wasLoggedInBefore = AuthService.instance.isAuthenticated;
    try {
      await SetupUnlockSheet.show(
        context,
        initialHasJwt: _jwtToken != null && _jwtToken!.isNotEmpty,
        onSignInRequested: () => _showProfileSheet(context),
        onLinkWalletRequested: () async {
          await _linkWallet();
          return ref.read(storageProvider).wallets.isNotEmpty ||
              NftWalletService.instance.hasWallet;
        },
        onJwtReceived: (apiKey) {
          if (mounted) {
            setState(() {
              _jwtToken = apiKey;
              _isGettingApiKey = false;
            });
          }
        },
      );
    } finally {
      _setupSheetOpen = false;
    }

    if (!mounted) return;

    // If the user just signed in inside the sheet but cloud connect is still
    // pending, reopen automatically so the flow stays in front of them.
    final isLoggedInNow = AuthService.instance.isAuthenticated;
    final hasJwt = _jwtToken != null && _jwtToken!.isNotEmpty;
    final justSignedIn = !wasLoggedInBefore && isLoggedInNow;
    final mandatoryIncomplete = !isLoggedInNow || !hasJwt;

    if (justSignedIn && mandatoryIncomplete) {
      // Reopen — user hasn't actually finished mandatory setup yet.
      // Reset the user-dismissed flag because the dismissal was incidental
      // to the sign-in flow, not an intentional "leave me alone".
      _setupSheetUserDismissed = false;
      // Slight delay so the previous sheet's dismissal animation completes.
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) _openSetupUnlockSheet(context);
      });
    } else if (mandatoryIncomplete) {
      _setupSheetUserDismissed = true;
    }
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
    debugPrint('HomeScreen: Starting wallet linking...');

    try {
      // Use the root navigator context for wallet operations
      final navContext = walletNavigatorKey.currentContext ?? context;
      debugPrint('HomeScreen: Got nav context: ${navContext.hashCode}');

      // Initialize wallet service if needed
      if (!WalletService.instance.isInitialized) {
        debugPrint('HomeScreen: Initializing wallet service...');
        await WalletService.instance.initialize(navContext);
        debugPrint('HomeScreen: Wallet service initialized');
      }

      // Check if already connected, otherwise connect
      String? address = WalletService.instance.connectedAddress;
      if (address != null) {
        debugPrint('HomeScreen: Already connected to wallet: $address');
      } else {
        // Connect wallet
        debugPrint('HomeScreen: Connecting wallet...');
        address = await WalletService.instance.connectWallet(navContext);
        debugPrint('HomeScreen: Connect result: $address');
        if (address == null) {
          debugPrint('HomeScreen: Connection cancelled or failed');
          setState(() => _isLinkingWallet = false);
          return;
        }
      }

      // Generate and sign message
      debugPrint('HomeScreen: Generating link message...');
      final message = WalletService.instance.generateLinkMessage(address);
      debugPrint('HomeScreen: Requesting signature...');
      final signature = await WalletService.instance.signLinkMessage(message);
      debugPrint('HomeScreen: Signature received: ${signature.substring(0, 20)}...');

      // Encrypt wallet address client-side before sending
      String? encryptedAddress;
      try {
        final key = await AuthService.instance.getEncryptionKey();
        if (key != null) {
          final aesGcm = crypto.AesGcm.with256bits();
          final secretKey = crypto.SecretKey(key);
          final nonce = aesGcm.newNonce();
          final secretBox = await aesGcm.encrypt(
            utf8.encode(address.toLowerCase()),
            secretKey: secretKey,
            nonce: nonce,
          );
          final encrypted = Uint8List.fromList([
            ...nonce,
            ...secretBox.cipherText,
            ...secretBox.mac.bytes,
          ]);
          encryptedAddress = base64Encode(encrypted);
        }
      } catch (e) {
        debugPrint('HomeScreen: wallet address encryption failed (non-fatal): $e');
      }

      // Link wallet on server
      debugPrint('HomeScreen: Linking wallet on server...');
      final chainId = WalletService.instance.connectedChainId ?? 8453;
      await BillingApiService.instance.linkWallet(
        address: address,
        chainId: chainId,
        signature: signature,
        message: message,
        encryptedAddress: encryptedAddress,
      );
      debugPrint('HomeScreen: Wallet linked successfully');

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
    } catch (e, stackTrace) {
      debugPrint('HomeScreen: Error linking wallet: $e');
      debugPrint('HomeScreen: Stack trace: $stackTrace');
      if (mounted) {
        setState(() => _isLinkingWallet = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMessages.forBilling(e, operation: 'link wallet')),
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

  void _startTutorial(BuildContext context) {
    // Check if setup is complete to determine whether to include setup step
    final storageState = ref.read(storageProvider);
    final isLoggedIn = AuthService.instance.isAuthenticated;
    final hasJwt = _jwtToken != null && _jwtToken!.isNotEmpty;
    final hasAnyWallet = storageState.wallets.isNotEmpty || NftWalletService.instance.hasWallet;

    // Setup is needed if any step is incomplete (same logic as in build)
    final needsSetup = !_isLoadingJwt && (
      !isLoggedIn ||
      !hasJwt ||
      (hasJwt && !hasAnyWallet && storageState.error == null)
    );

    // Only include setup step if setup is still needed (bar visible).
    final includeSetup = needsSetup;

    // Store the include setup state for TutorialShowcase to use
    TutorialService.instance.setIncludeSetup(includeSetup);

    ShowCaseWidget.of(context).startShowCase(
      TutorialService.instance.getTutorialKeys(includeSetup: includeSetup),
    );
  }

  Future<void> _showProfileSheet(BuildContext context) {
    return showAdaptiveSheet(
      context: context,
      builder: (ctx) {
        // Read auth state inside builder to ensure we get latest state
        final isLoggedIn = AuthService.instance.isAuthenticated;
        final user = AuthService.instance.currentUser;

        return SafeArea(
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
                    // Close the modal first
                    if (ctx.mounted) Navigator.pop(ctx);

                    try {
                      await AuthService.instance.signOut();
                      // Clear storage provider state (wallet info, etc.)
                      ref.read(storageProvider.notifier).clear();
                      // Invalidate sharing/collab providers so they reload from (now empty) storage
                      ref.invalidate(sharesProvider);
                      ref.invalidate(collaborationProvider);
                      if (mounted) {
                        setState(() {
                          _jwtToken = null;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Signed out')),
                        );
                      }
                    } catch (e) {
                      // Sign out failed - still clear local state
                      ref.read(storageProvider.notifier).clear();
                      if (mounted) {
                        setState(() {
                          _jwtToken = null;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Signed out (with warning: ${e.toString()})'),
                            backgroundColor: Colors.orange,
                          ),
                        );
                      }
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
                // Sign-in entry points route through the mode chooser
                // (/onboarding → ModeChoiceScreen) so the user picks
                // A (OAuth) / B (OAuth+seed) / C (seed-only). Cached
                // Mode A users never reach this branch — they have a
                // userCredentials entry in SecureStorage and are already
                // signed in.
                if (!PlatformCapabilities.isDesktop) ...[
                  ListTile(
                    leading: const Icon(LucideIcons.logIn),
                    title: const Text('Sign in to FxFiles'),
                    subtitle: const Text('Choose how to secure your vault'),
                    onTap: () {
                      Navigator.pop(ctx);
                      // `push` (not `go`) so the system back button
                      // returns the user to HomeScreen instead of
                      // exiting the app.
                      context.push('/onboarding');
                    },
                  ),
                ],
                if (PlatformCapabilities.isDesktop) ...[
                  ListTile(
                    leading: const Icon(LucideIcons.key),
                    title: const Text('Get API Key'),
                    subtitle: const Text('Sign in via your browser'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _getApiKey(context);
                    },
                  ),
                ],
              ],
            ],
          ),
        ),
      );
      },
    );
  }
}

