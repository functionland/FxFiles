import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/face_detection_service.dart';
import 'package:fula_files/core/services/face_storage_service.dart';
import 'package:fula_files/features/settings/providers/settings_provider.dart';
import 'package:fula_files/features/settings/screens/face_management_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _apiGatewayController = TextEditingController();
  final _ipfsServerController = TextEditingController();
  final _jwtTokenController = TextEditingController();
  
  bool _isEditingApi = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  static const String _defaultApiGateway = 'https://s3.cloud.fx.land';
  static const String _defaultIpfsServer = 'https://api.cloud.fx.land';

  Future<void> _loadSettings() async {
    final apiGateway = await SecureStorageService.instance.read(SecureStorageKeys.apiGatewayUrl);
    final ipfsServer = await SecureStorageService.instance.read(SecureStorageKeys.ipfsServerUrl);
    final jwtToken = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);

    setState(() {
      _apiGatewayController.text = apiGateway ?? _defaultApiGateway;
      _ipfsServerController.text = ipfsServer ?? _defaultIpfsServer;
      _jwtTokenController.text = jwtToken ?? '';
    });
  }

  @override
  void dispose() {
    _apiGatewayController.dispose();
    _ipfsServerController.dispose();
    _jwtTokenController.dispose();
    super.dispose();
  }

  Future<void> _openCloudFxLand() async {
    final uri = Uri.parse('https://cloud.fx.land');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open cloud.fx.land: $e')),
        );
      }
    }
  }

  Future<void> _pasteJwtFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      setState(() {
        _jwtTokenController.text = data.text!.trim();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('JWT token pasted')),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clipboard is empty')),
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
              if (!_isEditingApi) ...[
                ListTile(
                  leading: const Icon(LucideIcons.server),
                  title: const Text('API Gateway URL'),
                  subtitle: Text(
                    _apiGatewayController.text.isEmpty 
                        ? 'Not configured' 
                        : _apiGatewayController.text,
                  ),
                  trailing: IconButton(
                    icon: const Icon(LucideIcons.edit),
                    onPressed: () => _startEditingApi(),
                  ),
                ),
                ListTile(
                  leading: const Icon(LucideIcons.globe),
                  title: const Text('IPFS Server'),
                  subtitle: Text(
                    _ipfsServerController.text.isEmpty 
                        ? 'Not configured' 
                        : _ipfsServerController.text,
                  ),
                ),
                ListTile(
                  leading: const Icon(LucideIcons.key),
                  title: const Text('JWT Token'),
                  subtitle: Text(
                    _jwtTokenController.text.isEmpty 
                        ? 'Not configured' 
                        : '••••••••',
                  ),
                ),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _apiGatewayController,
                        decoration: const InputDecoration(
                          labelText: 'API Gateway URL',
                          hintText: 'https://api.gateway.cloud.fx.land',
                          prefixIcon: Icon(LucideIcons.server),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _ipfsServerController,
                        decoration: const InputDecoration(
                          labelText: 'IPFS Server URL',
                          hintText: 'https://ipfs.gateway.cloud.fx.land',
                          prefixIcon: Icon(LucideIcons.globe),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _jwtTokenController,
                        decoration: InputDecoration(
                          labelText: 'JWT Token',
                          hintText: 'Your JWT token',
                          prefixIcon: const Icon(LucideIcons.key),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_jwtTokenController.text.isEmpty)
                                IconButton(
                                  icon: const Icon(LucideIcons.externalLink),
                                  tooltip: 'Get token from cloud.fx.land',
                                  onPressed: () => _openCloudFxLand(),
                                ),
                              IconButton(
                                icon: const Icon(LucideIcons.clipboard),
                                tooltip: 'Paste from clipboard',
                                onPressed: () => _pasteJwtFromClipboard(),
                              ),
                            ],
                          ),
                        ),
                        obscureText: true,
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: _cancelEditingApi,
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _isLoading ? null : _saveApiSettings,
                            child: _isLoading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Text('Save'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
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
            ],
          ),
          _buildFaceDetectionSection(),
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
              const ListTile(
                leading: Icon(LucideIcons.info),
                title: Text('Version'),
                subtitle: Text('1.1.0'),
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
        
        return _buildSection(
          title: 'Your Share ID',
          children: [
            if (!isAuthenticated)
              const ListTile(
                leading: Icon(LucideIcons.userX),
                title: Text('Sign in to get your Share ID'),
                subtitle: Text('Required for receiving shared files'),
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

  void _startEditingApi() {
    _showApiWarningDialog();
  }

  void _showApiWarningDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(LucideIcons.alertTriangle, color: Colors.orange),
            SizedBox(width: 8),
            Text('Warning'),
          ],
        ),
        content: const Text(
          'Changing API Gateway, IPFS Server, or JWT Token settings may affect '
          'accessibility of your previously uploaded data.\n\n'
          'Make sure you have the correct credentials before making changes. '
          'Data uploaded to different servers cannot be accessed after switching.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _isEditingApi = true);
            },
            child: const Text('I Understand, Continue'),
          ),
        ],
      ),
    );
  }

  void _cancelEditingApi() {
    _loadSettings();
    setState(() => _isEditingApi = false);
  }

  Future<void> _saveApiSettings() async {
    setState(() => _isLoading = true);

    try {
      await SecureStorageService.instance.write(
        SecureStorageKeys.apiGatewayUrl,
        _apiGatewayController.text,
      );
      await SecureStorageService.instance.write(
        SecureStorageKeys.ipfsServerUrl,
        _ipfsServerController.text,
      );
      await SecureStorageService.instance.write(
        SecureStorageKeys.jwtToken,
        _jwtTokenController.text,
      );

      if (_apiGatewayController.text.isNotEmpty && _jwtTokenController.text.isNotEmpty) {
        FulaApiService.instance.configure(
          endpoint: _apiGatewayController.text,
          accessKey: 'JWT:${_jwtTokenController.text}',
          secretKey: 'not-used',
          pinningService: _ipfsServerController.text.isNotEmpty ? _ipfsServerController.text : null,
          pinningToken: _jwtTokenController.text.isNotEmpty ? _jwtTokenController.text : null,
        );
      }

      setState(() {
        _isEditingApi = false;
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved')),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save settings: $e')),
        );
      }
    }
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
            ListTile(
              leading: const Icon(LucideIcons.chrome),
              title: const Text('Google'),
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
                    SnackBar(content: Text('Sign-in failed: $e'), backgroundColor: Colors.red),
                  );
                }
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _signOut() async {
    await AuthService.instance.signOut();
    setState(() {});
  }

  Future<void> _clearCache() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Cache cleared')),
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
}
