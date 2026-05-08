import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/deep_link_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/ipfs_gateway_helper.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/shared/utils/error_messages.dart';

/// Defaults shared with [SettingsScreen]: keep these public so the parent
/// Account section can fall back to the same billing server when the user
/// hasn't customised it.
const String kDefaultApiGateway = 'https://s3.cloud.fx.land';
const String kDefaultIpfsServer = 'https://api.cloud.fx.land';
const String kDefaultBillingServer = 'https://cloud.fx.land';
const String kDefaultAiEndpoint = 'https://ai.cloud.fx.land';
const String kDefaultIpfsGateway = IpfsGatewayHelper.defaultTemplate;
const String kDefaultIpfsEndpoint = 'https://ipfs.cloud.fx.land';

/// Dedicated screen for the Fula API Configuration block. Shows the saved
/// values read-only by default; tapping the toolbar edit button confirms a
/// destructive-changes warning, then unlocks the inputs.
class FulaApiConfigScreen extends ConsumerStatefulWidget {
  const FulaApiConfigScreen({super.key});

  @override
  ConsumerState<FulaApiConfigScreen> createState() =>
      _FulaApiConfigScreenState();
}

class _FulaApiConfigScreenState extends ConsumerState<FulaApiConfigScreen> {
  final _apiGatewayController = TextEditingController();
  final _ipfsServerController = TextEditingController();
  final _billingServerController = TextEditingController();
  final _aiEndpointController = TextEditingController();
  final _ipfsGatewayController = TextEditingController();
  final _ipfsEndpointController = TextEditingController();
  final _baseRpcController = TextEditingController();
  final _usersIndexAnchorController = TextEditingController();
  final _usersIndexIpnsController = TextEditingController();
  final _usersIndexIpnsGatewaysController = TextEditingController();
  final _jwtTokenController = TextEditingController();

  bool _isEditing = false;
  bool _isLoading = false;
  StreamSubscription<String>? _apiKeySubscription;

  // Cold-start resolver defaults — match the constants in fula_api_service.dart.
  static const String _defaultBaseRpc = kUsersIndexChainRpcUrl;
  static const String _defaultUsersIndexAnchor = kUsersIndexAnchorAddress;
  static const String _defaultUsersIndexIpns = kUsersIndexIpnsName;
  static final String _defaultUsersIndexIpnsGateways =
      kUsersIndexIpnsGatewayUrls.join('\n');

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _apiKeySubscription =
        DeepLinkService.instance.onApiKeyReceived.listen((apiKey) {
      if (mounted) {
        setState(() {
          _jwtTokenController.text = apiKey;
        });
      }
    });
  }

  @override
  void dispose() {
    _apiKeySubscription?.cancel();
    _apiGatewayController.dispose();
    _ipfsServerController.dispose();
    _billingServerController.dispose();
    _aiEndpointController.dispose();
    _ipfsGatewayController.dispose();
    _ipfsEndpointController.dispose();
    _baseRpcController.dispose();
    _usersIndexAnchorController.dispose();
    _usersIndexIpnsController.dispose();
    _usersIndexIpnsGatewaysController.dispose();
    _jwtTokenController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final apiGateway =
        await SecureStorageService.instance.read(SecureStorageKeys.apiGatewayUrl);
    final ipfsServer =
        await SecureStorageService.instance.read(SecureStorageKeys.ipfsServerUrl);
    final billingServer = await SecureStorageService.instance
        .read(SecureStorageKeys.billingServerUrl);
    final aiEndpoint =
        await SecureStorageService.instance.read(SecureStorageKeys.aiEndpointUrl);
    final ipfsGateway = await SecureStorageService.instance
        .read(SecureStorageKeys.ipfsGatewayUrl);
    final ipfsEndpoint = await SecureStorageService.instance
        .read(SecureStorageKeys.ipfsEndpointUrl);
    final baseRpc =
        await SecureStorageService.instance.read(SecureStorageKeys.baseRpcUrl);
    final usersIndexAnchor = await SecureStorageService.instance
        .read(SecureStorageKeys.usersIndexAnchorAddress);
    final usersIndexIpns = await SecureStorageService.instance
        .read(SecureStorageKeys.usersIndexIpnsName);
    final usersIndexIpnsGateways = await SecureStorageService.instance
        .read(SecureStorageKeys.usersIndexIpnsGatewayUrls);
    final jwtToken =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);

    if (!mounted) return;
    setState(() {
      _apiGatewayController.text = apiGateway ?? kDefaultApiGateway;
      _ipfsServerController.text = ipfsServer ?? kDefaultIpfsServer;
      _billingServerController.text = billingServer ?? kDefaultBillingServer;
      _aiEndpointController.text = aiEndpoint ?? kDefaultAiEndpoint;
      _ipfsGatewayController.text = ipfsGateway ?? kDefaultIpfsGateway;
      _ipfsEndpointController.text = ipfsEndpoint ?? kDefaultIpfsEndpoint;
      _baseRpcController.text = baseRpc ?? _defaultBaseRpc;
      _usersIndexAnchorController.text =
          usersIndexAnchor ?? _defaultUsersIndexAnchor;
      _usersIndexIpnsController.text =
          usersIndexIpns ?? _defaultUsersIndexIpns;
      _usersIndexIpnsGatewaysController.text =
          usersIndexIpnsGateways ?? _defaultUsersIndexIpnsGateways;
      _jwtTokenController.text = jwtToken ?? '';
    });
  }

  Future<void> _openCloudFxLand() async {
    final uri = Uri.parse('https://cloud.fx.land');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMessages.getUserFriendlyMessage(e,
                context: 'open website')),
          ),
        );
      }
    }
  }

  Future<void> _pasteJwtFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    if (data?.text != null && data!.text!.isNotEmpty) {
      setState(() {
        _jwtTokenController.text = data.text!.trim();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('API Key pasted')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clipboard is empty')),
      );
    }
  }

  void _startEditing() {
    showDialog<void>(
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
          'Changing API Gateway, IPFS Server, or API Key settings may affect '
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
              setState(() => _isEditing = true);
            },
            child: const Text('I Understand, Continue'),
          ),
        ],
      ),
    );
  }

  void _cancelEditing() {
    _loadSettings();
    setState(() => _isEditing = false);
  }

  Future<void> _saveSettings() async {
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
        SecureStorageKeys.billingServerUrl,
        _billingServerController.text,
      );
      await SecureStorageService.instance.write(
        SecureStorageKeys.aiEndpointUrl,
        _aiEndpointController.text,
      );
      await SecureStorageService.instance.write(
        SecureStorageKeys.ipfsGatewayUrl,
        _ipfsGatewayController.text,
      );
      IpfsGatewayHelper.updateCache(_ipfsGatewayController.text);
      await SecureStorageService.instance.write(
        SecureStorageKeys.ipfsEndpointUrl,
        _ipfsEndpointController.text,
      );
      await SecureStorageService.instance.write(
        SecureStorageKeys.baseRpcUrl,
        _baseRpcController.text.trim(),
      );
      await SecureStorageService.instance.write(
        SecureStorageKeys.usersIndexAnchorAddress,
        _usersIndexAnchorController.text.trim(),
      );
      await SecureStorageService.instance.write(
        SecureStorageKeys.usersIndexIpnsName,
        _usersIndexIpnsController.text.trim(),
      );
      await SecureStorageService.instance.write(
        SecureStorageKeys.usersIndexIpnsGatewayUrls,
        _usersIndexIpnsGatewaysController.text.trim(),
      );
      await SecureStorageService.instance.write(
        SecureStorageKeys.jwtToken,
        _jwtTokenController.text,
      );

      // Reinitialize FulaApiService so the new endpoints/cold-start config
      // take effect without a restart.
      if (_apiGatewayController.text.isNotEmpty &&
          _jwtTokenController.text.isNotEmpty) {
        await AuthService.instance.reinitializeFulaClient();
      }

      if (!mounted) return;
      setState(() {
        _isEditing = false;
        _isLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMessages.forSettings(e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fula API Configuration'),
        actions: [
          if (!_isEditing)
            IconButton(
              icon: const Icon(LucideIcons.edit),
              tooltip: 'Edit',
              onPressed: _startEditing,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: _isEditing ? _buildEditView() : _buildReadOnlyView(),
      ),
    );
  }

  // ============================================================================
  // VIEW MODES
  // ============================================================================

  List<Widget> _buildReadOnlyView() {
    return [
      _readTile(
        icon: LucideIcons.server,
        title: 'API Gateway URL',
        value: _apiGatewayController.text,
      ),
      _readTile(
        icon: LucideIcons.globe,
        title: 'IPFS Pinning Server',
        value: _ipfsServerController.text,
      ),
      _readTile(
        icon: LucideIcons.wallet,
        title: 'Billing Server',
        value: _billingServerController.text,
      ),
      _readTile(
        icon: LucideIcons.brain,
        title: 'AI Endpoint',
        value: _aiEndpointController.text,
      ),
      _readTile(
        icon: LucideIcons.link,
        title: 'IPFS Gateway',
        value: _ipfsGatewayController.text,
      ),
      _readTile(
        icon: LucideIcons.hardDrive,
        title: 'IPFS Endpoint',
        value: _ipfsEndpointController.text,
      ),
      _readTile(
        icon: LucideIcons.network,
        title: 'Base RPC URL',
        value: _baseRpcController.text,
      ),
      _readTile(
        icon: LucideIcons.fileSignature,
        title: 'Users-Index Anchor Address',
        value: _usersIndexAnchorController.text,
      ),
      _readTile(
        icon: LucideIcons.cloudOff,
        title: 'Users-Index IPNS Name',
        value: _usersIndexIpnsController.text,
        emptyLabel: 'Not configured (cold-start disabled)',
      ),
      _readTile(
        icon: LucideIcons.globe2,
        title: 'Users-Index IPNS Gateways',
        value: _usersIndexIpnsGatewaysController.text,
        emptyLabel: 'Empty (using fula_client defaults)',
      ),
      _readTile(
        icon: LucideIcons.key,
        title: 'API Key',
        value: _jwtTokenController.text,
        masked: true,
      ),
    ];
  }

  Widget _readTile({
    required IconData icon,
    required String title,
    required String value,
    bool masked = false,
    String emptyLabel = 'Not configured',
  }) {
    final String subtitle;
    if (value.isEmpty) {
      subtitle = emptyLabel;
    } else if (masked) {
      subtitle = '••••••••';
    } else {
      subtitle = value;
    }
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }

  List<Widget> _buildEditView() {
    return [
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
                labelText: 'IPFS Pinning Server URL',
                hintText: 'https://ipfs.gateway.cloud.fx.land',
                prefixIcon: Icon(LucideIcons.globe),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _billingServerController,
              decoration: const InputDecoration(
                labelText: 'Billing Server URL',
                hintText: 'https://cloud.fx.land',
                prefixIcon: Icon(LucideIcons.wallet),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _aiEndpointController,
              decoration: const InputDecoration(
                labelText: 'AI Endpoint URL',
                hintText: 'https://ai.cloud.fx.land',
                prefixIcon: Icon(LucideIcons.brain),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ipfsGatewayController,
              decoration: const InputDecoration(
                labelText: 'IPFS Gateway URL',
                hintText: IpfsGatewayHelper.defaultTemplate,
                helperText:
                    'Use {cid} for subdomain-style gateways (e.g. dweb.link); '
                    'path-style URLs without {cid} get the CID appended.',
                helperMaxLines: 2,
                prefixIcon: Icon(LucideIcons.link),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ipfsEndpointController,
              decoration: const InputDecoration(
                labelText: 'IPFS Endpoint URL',
                hintText: 'https://ipfs.cloud.fx.land',
                prefixIcon: Icon(LucideIcons.hardDrive),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _baseRpcController,
              decoration: const InputDecoration(
                labelText: 'Base RPC URL',
                hintText: _defaultBaseRpc,
                helperText:
                    'EVM RPC the cold-start resolver reads the on-chain '
                    'users-index anchor from. Leave default unless you '
                    'host your own Base RPC.',
                helperMaxLines: 3,
                prefixIcon: Icon(LucideIcons.network),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usersIndexAnchorController,
              decoration: const InputDecoration(
                labelText: 'Users-Index Anchor Address',
                hintText: _defaultUsersIndexAnchor,
                helperText:
                    'Address of the deployed users-index anchor contract '
                    'on the chain configured above.',
                helperMaxLines: 2,
                prefixIcon: Icon(LucideIcons.fileSignature),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usersIndexIpnsController,
              decoration: const InputDecoration(
                labelText: 'Users-Index IPNS Name',
                hintText: 'k51qzi5...',
                helperText:
                    'IPNS name printed by setup-users-index-publisher.sh '
                    'on the master. Required for cold-start reads while '
                    'the master is down; leaving it blank disables '
                    'cold-start cleanly.',
                helperMaxLines: 4,
                prefixIcon: Icon(LucideIcons.cloudOff),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usersIndexIpnsGatewaysController,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: 'Users-Index IPNS Gateways',
                hintText: 'https://ipfs.filebase.io/ipns/{cid}/',
                helperText:
                    'IPNS gateways the cold-start resolver hits to fetch '
                    'the per-user anchor. One URL per line; use {cid} as '
                    'the IPNS-name placeholder. Leave empty to use the '
                    'fula_client built-in gateway list.',
                helperMaxLines: 4,
                prefixIcon: Icon(LucideIcons.globe2),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _jwtTokenController,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: 'Your API Key',
                prefixIcon: const Icon(LucideIcons.key),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_jwtTokenController.text.isEmpty)
                      IconButton(
                        icon: const Icon(LucideIcons.externalLink),
                        tooltip: 'Get token from cloud.fx.land',
                        onPressed: _openCloudFxLand,
                      ),
                    IconButton(
                      icon: const Icon(LucideIcons.clipboard),
                      tooltip: 'Paste from clipboard',
                      onPressed: _pasteJwtFromClipboard,
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
                  onPressed: _cancelEditing,
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _isLoading ? null : _saveSettings,
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
    ];
  }
}
