import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/face_detection_service.dart';
import 'package:fula_files/core/services/face_storage_service.dart';
import 'package:fula_files/features/settings/providers/settings_provider.dart';
import 'package:fula_files/features/settings/screens/face_management_screen.dart';
import 'package:fula_files/features/settings/screens/fula_api_config_screen.dart';
import 'package:fula_files/features/billing/screens/billing_screen.dart';
import 'package:fula_files/features/billing/providers/storage_provider.dart';
import 'package:fula_files/features/sharing/providers/sharing_provider.dart';
import 'package:fula_files/features/sharing/providers/collaboration_provider.dart';
import 'package:fula_files/features/settings/screens/blox_pairing_screen.dart';
import 'package:fula_files/features/settings/screens/sync_queue_screen.dart';
import 'package:fula_files/core/services/nft_wallet_service.dart';
import 'package:fula_files/core/services/deep_link_service.dart';
import 'package:fula_files/core/utils/platform_capabilities.dart';
import 'package:fula_files/shared/utils/error_messages.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _showPrivateKey = false;
  bool _showDerivationInputs = false;

  Future<void> _openProfileForDeletion() async {
    // Prefer the user's customised billing server (from secure storage) and
    // fall back to the same default the FulaApiConfigScreen uses.
    final stored = await SecureStorageService.instance
        .read(SecureStorageKeys.billingServerUrl);
    final billingServer = (stored != null && stored.isNotEmpty)
        ? stored
        : kDefaultBillingServer;
    final uri = Uri.parse('$billingServer/login?returnTo=%2Fprofile');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.getUserFriendlyMessage(e, context: 'open profile'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          _buildSection(
            title: 'Appearance',
            children: [
              ListTile(
                leading: const Icon(LucideIcons.palette),
                title: const Text('Theme'),
                subtitle: Text(_getThemeName(settings.themeMode)),
                trailing: const Icon(LucideIcons.chevronRight),
                onTap: () => _showThemeDialog(settings.themeMode),
              ),
            ],
          ),
          _buildShareIdSection(),
          _buildSection(
            title: 'Fula API Configuration',
            children: [
              ListTile(
                leading: const Icon(LucideIcons.server),
                title: const Text('Endpoints, gateways & API key'),
                subtitle: const Text(
                    'API gateway, IPFS, AI, cold-start resolver, API key'),
                trailing: const Icon(LucideIcons.chevronRight),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const FulaApiConfigScreen()),
                  );
                },
              ),
            ],
          ),
          _buildSection(
            title: 'Account',
            children: [
              ListTile(
                leading: const Icon(LucideIcons.user),
                title: Text(
                  AuthService.instance.currentUser?.displayName ??
                  AuthService.instance.currentUser?.email ??
                  'Not signed in',
                ),
                subtitle: Text(
                  AuthService.instance.isAuthenticated
                      ? 'Signed in with ${AuthService.instance.currentUser?.provider.name}'
                      : 'Sign in to enable sync',
                ),
                trailing: AuthService.instance.isAuthenticated
                    ? TextButton(
                        onPressed: _signOut,
                        child: const Text('Sign Out'),
                      )
                    : TextButton(
                        onPressed: () => _showSignInDialog(),
                        child: const Text('Sign In'),
                      ),
              ),
              if (AuthService.instance.isAuthenticated)
                ListTile(
                  leading: const Icon(LucideIcons.userX),
                  title: const Text('Delete Account'),
                  subtitle: const Text('Visit profile to delete account'),
                  trailing: const Icon(LucideIcons.externalLink),
                  onTap: _openProfileForDeletion,
                ),
            ],
          ),
          _buildSection(
            title: 'Billing',
            children: [
              ListTile(
                leading: const Icon(LucideIcons.wallet),
                title: const Text('Credits & Wallets'),
                subtitle: const Text('Manage storage credits and linked wallets'),
                trailing: const Icon(LucideIcons.chevronRight),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const BillingScreen()),
                  );
                },
              ),
            ],
          ),
          _buildNftWalletSection(),
          _buildDevicesSection(),
          _buildFaceDetectionSection(),
          _buildSyncSection(settings),
          _buildSecuritySection(),
          _buildSection(
            title: 'Display',
            children: [
              SwitchListTile(
                secondary: const Icon(LucideIcons.scrollText),
                title: const Text('Fast scroll'),
                subtitle: const Text('Show scroll indicator with section headers'),
                value: settings.thumbScrollEnabled,
                onChanged: (value) {
                  ref.read(settingsProvider.notifier).setThumbScrollEnabled(value);
                },
              ),
            ],
          ),
          _buildSection(
            title: 'Storage',
            children: [
              ListTile(
                leading: const Icon(LucideIcons.hardDrive),
                title: const Text('Clear cache'),
                subtitle: const Text('Free up space'),
                onTap: _clearCache,
              ),
            ],
          ),
          _buildSection(
            title: 'About',
            children: [
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snapshot) {
                  final version = snapshot.hasData
                      ? '${snapshot.data!.version} (${snapshot.data!.buildNumber})'
                      : 'Loading...';
                  return ListTile(
                    leading: const Icon(LucideIcons.info),
                    title: const Text('Version'),
                    subtitle: Text(version),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            title,
            style: TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
        ...children,
        const Divider(),
      ],
    );
  }

  Widget _buildShareIdSection() {
    return FutureBuilder<String?>(
      future: AuthService.instance.getShareId(),
      builder: (context, snapshot) {
        final shareId = snapshot.data;
        final isAuthenticated = AuthService.instance.isAuthenticated;
        final isDone = snapshot.connectionState == ConnectionState.done;

        return _buildSection(
          title: 'Your Share ID',
          children: [
            if (!isAuthenticated)
              const ListTile(
                leading: Icon(LucideIcons.userX),
                title: Text('Sign in to get your Share ID'),
                subtitle: Text('Required for receiving shared files'),
              )
            else if (snapshot.hasError || (isDone && shareId == null))
              ListTile(
                leading: const Icon(LucideIcons.alertTriangle, color: Colors.orange),
                title: const Text('Could not generate Share ID'),
                subtitle: const Text('Cloud service not initialized. Try configuring API Gateway in settings and restarting the app.'),
                trailing: IconButton(
                  icon: const Icon(LucideIcons.refreshCw),
                  onPressed: () => setState(() {}),
                  tooltip: 'Retry',
                ),
              )
            else if (shareId == null)
              const ListTile(
                leading: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                title: Text('Generating Share ID...'),
              )
            else ...[
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(LucideIcons.fingerprint, color: AppColors.primary, size: 20),
                        const SizedBox(width: 8),
                        const Text(
                          'Share this ID with others',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              shareId,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(LucideIcons.copy, size: 20),
                            onPressed: () => _copyShareId(shareId),
                            tooltip: 'Copy',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Others need this ID to share files with you',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  void _copyShareId(String shareId) {
    Clipboard.setData(ClipboardData(text: shareId));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Share ID copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  String _getThemeName(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'System default';
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
    }
  }

  void _showThemeDialog(ThemeMode currentMode) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Choose theme'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildThemeOption(
              dialogContext,
              'System default',
              ThemeMode.system,
              currentMode,
            ),
            _buildThemeOption(
              dialogContext,
              'Light',
              ThemeMode.light,
              currentMode,
            ),
            _buildThemeOption(
              dialogContext,
              'Dark',
              ThemeMode.dark,
              currentMode,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThemeOption(
    BuildContext dialogContext,
    String title,
    ThemeMode value,
    ThemeMode currentMode,
  ) {
    final isSelected = value == currentMode;
    return ListTile(
      title: Text(title),
      leading: Icon(
        isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: isSelected ? Theme.of(dialogContext).colorScheme.primary : null,
      ),
      onTap: () {
        ref.read(settingsProvider.notifier).setThemeMode(value);
        Navigator.pop(dialogContext);
      },
    );
  }

  void _showSignInDialog() {
    final messenger = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign In'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Sign in with Apple (iOS only)
            if (Platform.isIOS) ...[
              SignInWithAppleButton(
                onPressed: () async {
                  Navigator.pop(dialogContext);
                  try {
                    final user = await AuthService.instance.signInWithApple();
                    if (user != null) {
                      messenger.showSnackBar(
                        SnackBar(content: Text('Signed in as ${user.email}')),
                      );
                    }
                  } catch (e) {
                    messenger.showSnackBar(
                      SnackBar(content: Text(ErrorMessages.forAuth(e)), backgroundColor: Colors.red),
                    );
                  }
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(height: 12),
            ],
            if (!PlatformCapabilities.isDesktop) ...[
              ListTile(
                leading: const Icon(LucideIcons.chrome),
                title: const Text('Sign in with Google'),
                onTap: () async {
                  Navigator.pop(dialogContext);
                  try {
                    final user = await AuthService.instance.signInWithGoogle();
                    if (user != null) {
                      messenger.showSnackBar(
                        SnackBar(content: Text('Signed in as ${user.email}')),
                      );
                    }
                  } catch (e) {
                    messenger.showSnackBar(
                      SnackBar(content: Text(ErrorMessages.forAuth(e)), backgroundColor: Colors.red),
                    );
                  }
                  if (mounted) setState(() {});
                },
              ),
            ],
            if (PlatformCapabilities.isDesktop) ...[
              ListTile(
                leading: const Icon(LucideIcons.key),
                title: const Text('Get API Key'),
                subtitle: const Text('Sign in via your browser'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  DeepLinkService.instance.openGetApiKeyPage();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'You will be signed out of this device. Cloud data remains intact and can be restored by signing back in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    await AuthService.instance.signOut();
    ref.read(storageProvider.notifier).clear();
    // Invalidate sharing/collab providers so they reload from (now empty) storage
    ref.invalidate(sharesProvider);
    ref.invalidate(collaborationProvider);
    if (mounted) setState(() {});
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear cache?'),
        content: const Text(
          'Removes temporary files and thumbnails. Your synced files, login, and settings are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    int bytesFreed = 0;
    try {
      final tempDir = await getTemporaryDirectory();
      bytesFreed += await _clearDirectory(tempDir);
      try {
        final cacheDir = await getApplicationCacheDirectory();
        if (cacheDir.path != tempDir.path) {
          bytesFreed += await _clearDirectory(cacheDir);
        }
      } catch (_) {
        // getApplicationCacheDirectory may be unsupported on some platforms
      }
    } catch (e) {
      debugPrint('_clearCache: failed to clear temp/cache: $e');
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    final freedKb = (bytesFreed / 1024).toStringAsFixed(bytesFreed > 1024 * 1024 ? 0 : 1);
    final freedText = bytesFreed > 1024 * 1024
        ? '${(bytesFreed / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '$freedKb KB';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Cache cleared ($freedText freed)')),
    );
  }

  Future<int> _clearDirectory(Directory dir) async {
    var freed = 0;
    if (!await dir.exists()) return 0;
    await for (final entity in dir.list(followLinks: false)) {
      try {
        if (entity is File) {
          freed += await entity.length();
          await entity.delete();
        } else if (entity is Directory) {
          freed += await _directorySize(entity);
          await entity.delete(recursive: true);
        }
      } catch (e) {
        // Skip files/dirs that are in use or otherwise locked.
        debugPrint('_clearCache: could not remove ${entity.path}: $e');
      }
    }
    return freed;
  }

  Future<int> _directorySize(Directory dir) async {
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  Widget _buildNftWalletSection() {
    if (!AuthService.instance.isAuthenticated) {
      return _buildSection(
        title: 'NFT Wallet',
        children: [
          const ListTile(
            leading: Icon(LucideIcons.wallet),
            title: Text('Internal Wallet'),
            subtitle: Text('Sign in to derive your NFT wallet'),
          ),
        ],
      );
    }

    return FutureBuilder<String?>(
      future: NftWalletService.instance.getAddress(),
      builder: (context, snapshot) {
        final address = snapshot.data;

        return _buildSection(
          title: 'NFT Wallet',
          children: [
            ListTile(
              leading: const Icon(LucideIcons.wallet),
              title: const Text('Internal Wallet'),
              subtitle: Text(
                address != null
                    ? 'Auto-derived from your sign-in credentials'
                    : 'Deriving...',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ),
            if (address != null)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        address,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(LucideIcons.copy, size: 20),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: address));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Wallet address copied')),
                        );
                      },
                      tooltip: 'Copy',
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(LucideIcons.alertTriangle, size: 14, color: Colors.orange[700]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This wallet must not be used for token transfers and is only for internal app NFTs.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDevicesSection() {
    return _buildSection(
      title: 'Devices',
      children: [
        ListTile(
          leading: const Icon(LucideIcons.hardDrive),
          title: const Text('My Devices'),
          subtitle: const Text('Pair a Blox for local-first file access'),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BloxPairingScreen()),
            );
          },
        ),
      ],
    );
  }

  Widget _buildFaceDetectionSection() {
    final isEnabled = LocalStorageService.instance.getSetting<bool>('faceDetectionEnabled', defaultValue: true) ?? true;
    
    return _buildSection(
      title: 'Face Recognition',
      children: [
        SwitchListTile(
          secondary: const Icon(LucideIcons.scan),
          title: const Text('Enable Face Detection'),
          subtitle: const Text('Automatically detect faces in photos'),
          value: isEnabled,
          onChanged: (value) async {
            await LocalStorageService.instance.saveSetting('faceDetectionEnabled', value);
            setState(() {});
            if (!value) {
              FaceDetectionService.instance.clearQueue();
            }
          },
        ),
        ListTile(
          leading: const Icon(LucideIcons.users),
          title: const Text('Manage People'),
          subtitle: FutureBuilder<int>(
            future: FaceStorageService.instance.getTotalPersonCount(),
            builder: (context, snapshot) {
              final count = snapshot.data ?? 0;
              return Text('$count ${count == 1 ? 'person' : 'people'} detected');
            },
          ),
          trailing: const Icon(LucideIcons.chevronRight),
          enabled: isEnabled,
          onTap: isEnabled ? () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FaceManagementScreen()),
            );
          } : null,
        ),
        if (FaceDetectionService.instance.isProcessing)
          ListTile(
            leading: const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: const Text('Processing images...'),
            subtitle: Text('${FaceDetectionService.instance.queueLength} images in queue'),
          ),
      ],
    );
  }

  Widget _buildSyncSection(AppSettings settings) {
    final pendingCount = LocalStorageService.instance.pendingSyncTaskCount;

    return _buildSection(
      title: 'Sync',
      children: [
        SwitchListTile(
          secondary: const Icon(LucideIcons.wifi),
          title: const Text('WiFi only'),
          subtitle: const Text('Only sync when connected to WiFi'),
          value: settings.wifiOnly,
          onChanged: (value) {
            ref.read(settingsProvider.notifier).setWifiOnly(value);
          },
        ),
        ListTile(
          leading: const Icon(LucideIcons.listTodo),
          title: const Text('Sync Queue'),
          subtitle: Text(pendingCount > 0
              ? '$pendingCount pending'
              : 'No pending uploads'),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SyncQueueScreen()),
            );
          },
        ),
      ],
    );
  }

  Widget _buildSecuritySection() {
    if (!AuthService.instance.isAuthenticated) {
      return _buildSection(
        title: 'Security',
        children: [
          const ListTile(
            leading: Icon(LucideIcons.keyRound),
            title: Text('Encryption Key'),
            subtitle: Text('Sign in to view your encryption key'),
          ),
        ],
      );
    }

    return FutureBuilder<String?>(
      future: AuthService.instance.getEncryptionKeyBase64(),
      builder: (context, snapshot) {
        final encryptionKey = snapshot.data;

        return _buildSection(
          title: 'Security',
          children: [
            ListTile(
              leading: const Icon(LucideIcons.keyRound),
              title: const Text('Encryption Key'),
              subtitle: const Text('Your private key for encrypting files'),
            ),
            if (encryptionKey != null)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(LucideIcons.alertTriangle, color: Colors.orange, size: 20),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Keep this key safe! You need it to decrypt your files.',
                            style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () => setState(() => _showPrivateKey = !_showPrivateKey),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _showPrivateKey ? encryptionKey : '••••••••••••••••••••••••••••••••••••••••••••',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(context).colorScheme.onSurface,
                                ),
                                maxLines: _showPrivateKey ? null : 1,
                                overflow: _showPrivateKey ? null : TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: Icon(
                                _showPrivateKey ? LucideIcons.eyeOff : LucideIcons.eye,
                                size: 20,
                              ),
                              onPressed: () => setState(() => _showPrivateKey = !_showPrivateKey),
                              tooltip: _showPrivateKey ? 'Hide' : 'Reveal',
                            ),
                            IconButton(
                              icon: const Icon(LucideIcons.copy, size: 20),
                              onPressed: () => _copyEncryptionKey(encryptionKey),
                              tooltip: 'Copy',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tap to ${_showPrivateKey ? 'hide' : 'reveal'} your encryption key',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
            _buildDerivationInputsCard(),
          ],
        );
      },
    );
  }

  /// Diagnostic card showing the three inputs (`provider`, `userId`,
  /// `email`) that `_deriveEncryptionKey` actually feeds into Argon2id.
  /// Surfaced so an operator can reproduce the key derivation outside
  /// the app — e.g. when a `bucket_lookup_h` value on master doesn't
  /// match what a fresh re-derivation produces, this card tells you
  /// whether the OAuth `userId` or the pinned `derivationEmail` drifted.
  /// None of these values are secret: `userId` is the OAuth provider's
  /// public subject identifier, `email` is the user's address, provider
  /// is `"google"` / `"apple"`.
  Widget _buildDerivationInputsCard() {
    return FutureBuilder<({String provider, String userId, String email})?>(
      future: AuthService.instance.getDerivationInputs(),
      builder: (context, snapshot) {
        final inputs = snapshot.data;
        if (inputs == null) return const SizedBox.shrink();

        final psBlock =
            '\$env:FULA_DERIVE_PROVIDER = "${inputs.provider}"\n'
            '\$env:FULA_DERIVE_USER_ID  = "${inputs.userId}"\n'
            '\$env:FULA_DERIVE_EMAIL    = "${inputs.email}"';

        final mask = '•' * 20;

        Widget row(String label, String value) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 80,
                  child: Text(
                    label,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                Expanded(
                  child: Text(
                    _showDerivationInputs ? value : mask,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                    maxLines: _showDerivationInputs ? null : 1,
                    overflow: _showDerivationInputs ? null : TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(LucideIcons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: value));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('$label copied'),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                  tooltip: 'Copy $label',
                ),
              ],
            ),
          );
        }

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.blueGrey.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.blueGrey.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(LucideIcons.bug, color: Colors.blueGrey, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Key derivation inputs (debug)',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _showDerivationInputs ? LucideIcons.eyeOff : LucideIcons.eye,
                      size: 20,
                    ),
                    onPressed: () => setState(
                      () => _showDerivationInputs = !_showDerivationInputs,
                    ),
                    tooltip: _showDerivationInputs ? 'Hide' : 'Reveal',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Inputs to Argon2id used to derive your encryption key. '
                'Only needed for debugging master-side bucket_lookup_h mismatches.',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              row('Provider', inputs.provider),
              row('User ID', inputs.userId),
              row('Email', inputs.email),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(LucideIcons.terminal, size: 16),
                  label: const Text('Copy as PowerShell env block'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: psBlock));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('PowerShell env block copied'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _copyEncryptionKey(String key) {
    Clipboard.setData(ClipboardData(text: key));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Encryption key copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}
