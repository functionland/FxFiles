import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:fula_files/core/services/auth_core.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/ipfs_gateway_helper.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';

/// One editable API-configuration field: a SecureStorage key + its
/// built-in default. Empty input → the key is deleted so the built-in
/// default applies (and stays in sync if the default ever changes).
class _ConfigField {
  final String label;
  final String storageKey;
  final String defaultValue;
  final String hint;
  final bool advanced;
  const _ConfigField(
      this.label, this.storageKey, this.defaultValue, this.hint,
      {this.advanced = false});
}

/// Web API-configuration editor. Mirrors the mobile FulaApiConfigScreen:
/// the user can override the gateway / IPFS / resolver endpoints; values
/// are persisted in SecureStorage and the Fula client is re-initialized
/// on save. Defaults are the same built-in constants the app ships with;
/// these reset to defaults on sign-out (see WebSession.signOut).
class WebApiConfigScreen extends StatefulWidget {
  const WebApiConfigScreen({super.key});

  @override
  State<WebApiConfigScreen> createState() => _WebApiConfigScreenState();
}

class _WebApiConfigScreenState extends State<WebApiConfigScreen> {
  // Field set + defaults mirror the mobile config screen.
  static final List<_ConfigField> _fields = [
    _ConfigField('Gateway (S3) URL', SecureStorageKeys.apiGatewayUrl,
        AuthCore.defaultS3GatewayUrl, 'https://s3.cloud.fx.land'),
    _ConfigField('IPFS API server URL', SecureStorageKeys.ipfsServerUrl,
        AuthCore.defaultIpfsServerUrl, 'https://api.cloud.fx.land'),
    _ConfigField('Account / billing server URL',
        SecureStorageKeys.billingServerUrl, AuthCore.defaultIssuerBaseUrl,
        'https://cloud.fx.land'),
    _ConfigField('AI endpoint URL', SecureStorageKeys.aiEndpointUrl,
        'https://ai.cloud.fx.land', 'https://ai.cloud.fx.land'),
    _ConfigField('IPFS gateway template', SecureStorageKeys.ipfsGatewayUrl,
        IpfsGatewayHelper.defaultTemplate, 'https://{cid}.ipfs.dweb.link/'),
    _ConfigField('IPFS upload endpoint URL', SecureStorageKeys.ipfsEndpointUrl,
        'https://ipfs.cloud.fx.land', 'https://ipfs.cloud.fx.land'),
    _ConfigField('EVM RPC URL (cold-start)', SecureStorageKeys.baseRpcUrl,
        kUsersIndexChainRpcUrl, 'https://mainnet.base.org', advanced: true),
    _ConfigField('Users-index anchor address',
        SecureStorageKeys.usersIndexAnchorAddress, kUsersIndexAnchorAddress,
        '0x…', advanced: true),
    _ConfigField('Users-index IPNS name',
        SecureStorageKeys.usersIndexIpnsName, kUsersIndexIpnsName, 'k51…',
        advanced: true),
    _ConfigField('Users-index IPNS gateways (comma-separated)',
        SecureStorageKeys.usersIndexIpnsGatewayUrls, '',
        'leave empty for built-in defaults', advanced: true),
  ];

  final Map<String, TextEditingController> _controllers = {};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    for (final f in _fields) {
      final stored = await SecureStorageService.instance.read(f.storageKey);
      _controllers[f.storageKey] = TextEditingController(
        text: (stored == null || stored.isEmpty) ? f.defaultValue : stored,
      );
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Read the master KEK and re-initialize the Fula client so the new
  /// endpoints take effect. Returns true if the client is configured.
  Future<bool> _reinitFula() async {
    final kekB64 =
        await SecureStorageService.instance.read(SecureStorageKeys.encryptionKey);
    if (kekB64 == null || kekB64.isEmpty) return false;
    final kek = Uint8List.fromList(base64Decode(kekB64));
    final init = await AuthCore.initializeFulaFromStorage(kek: kek);
    // Refresh the IPFS-gateway template cache so reads use the new value.
    await IpfsGatewayHelper.init();
    return init.configured;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      for (final f in _fields) {
        final value = _controllers[f.storageKey]!.text.trim();
        if (value.isEmpty) {
          // Empty → delete so the built-in default applies.
          await SecureStorageService.instance.delete(f.storageKey);
        } else {
          await SecureStorageService.instance.write(f.storageKey, value);
        }
      }
      final ok = await _reinitFula();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'API configuration saved'
            : 'Saved, but the client could not re-initialize — check the values'),
      ));
      if (ok && context.canPop()) context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetToDefaults() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset to defaults?'),
        content: const Text(
            'This restores all endpoints to the built-in defaults and '
            're-initializes the connection.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _saving = true);
    try {
      for (final f in _fields) {
        await SecureStorageService.instance.delete(f.storageKey);
        _controllers[f.storageKey]!.text = f.defaultValue;
      }
      await _reinitFula();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reset to defaults')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Reset failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final basic = _fields.where((f) => !f.advanced).toList();
    final advanced = _fields.where((f) => f.advanced).toList();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        title: const Text('API Configuration'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _resetToDefaults,
            child: const Text('Reset'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        margin: const EdgeInsets.all(16),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .errorContainer
                              .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Changing these points the app at different servers. '
                          'Files uploaded under one configuration may not be '
                          'reachable under another. Leave a field empty to use '
                          'its default.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      for (final f in basic) _fieldEditor(f),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text('ADVANCED (COLD-START RESOLVER)',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1)),
                      ),
                      for (final f in advanced) _fieldEditor(f),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton.icon(
                          icon: _saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.save),
                          label: Text(_saving ? 'Saving…' : 'Save & re-connect'),
                          onPressed: _saving ? null : _save,
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _fieldEditor(_ConfigField f) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: TextField(
        controller: _controllers[f.storageKey],
        decoration: InputDecoration(
          labelText: f.label,
          hintText: f.hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
      ),
    );
  }
}
