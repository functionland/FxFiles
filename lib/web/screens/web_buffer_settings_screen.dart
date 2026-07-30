import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/web/services/web_social_post_service.dart';

/// Settings → Integrations → Buffer: paste/save/test/disconnect the user's
/// personal Buffer API key. Buffer's new GraphQL API has no third-party
/// OAuth, so a personal key from publish.buffer.com/settings/api is the
/// supported connection method. The key is stored device-local in secure
/// storage and only ever sent to the AI-backend proxy.
class WebBufferSettingsScreen extends StatefulWidget {
  const WebBufferSettingsScreen({super.key});

  @override
  State<WebBufferSettingsScreen> createState() =>
      _WebBufferSettingsScreenState();
}

class _WebBufferSettingsScreenState extends State<WebBufferSettingsScreen> {
  final _keyController = TextEditingController();
  bool _hasStoredKey = false;
  bool _busy = false;
  String? _error;
  List<({String id, String name, String service})>? _testedChannels;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _loadState() async {
    final has = await WebSocialPostService.instance.hasBufferKey();
    if (mounted) setState(() => _hasStoredKey = has);
  }

  Future<void> _save() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'Paste your Buffer API key first');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await WebSocialPostService.instance.saveBufferKey(key);
    _keyController.clear();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _hasStoredKey = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Buffer API key saved')));
  }

  /// Verify a key by listing channels through the proxy — the pasted key
  /// when the field is non-empty, else the stored one.
  Future<void> _testConnection() async {
    setState(() {
      _busy = true;
      _error = null;
      _testedChannels = null;
    });
    try {
      final override = _keyController.text.trim();
      final channels = await WebSocialPostService.instance
          .fetchBufferChannels(
              overrideKey: override.isEmpty ? null : override);
      if (!mounted) return;
      setState(() => _testedChannels = channels);
    } catch (e) {
      if (!mounted) return;
      setState(
          () => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect Buffer?'),
        content: const Text(
            'The stored API key will be removed from this device. Your '
            'Buffer account itself is not affected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Disconnect')),
        ],
      ),
    );
    if (ok != true) return;
    await WebSocialPostService.instance.deleteBufferKey();
    if (!mounted) return;
    setState(() {
      _hasStoredKey = false;
      _testedChannels = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Buffer disconnected')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        title: const Text('Buffer'),
      ),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Post generated social content to your channels through '
                    'Buffer. Create a personal API key in your Buffer '
                    'account and paste it below.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Get your API key on buffer.com'),
                    onPressed: () => launchUrl(
                      Uri.parse('https://publish.buffer.com/settings/api'),
                      webOnlyWindowName: '_blank',
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_hasStoredKey)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        children: [
                          Icon(LucideIcons.checkCircle,
                              size: 16, color: Colors.green),
                          SizedBox(width: 8),
                          Text('Buffer is connected (key is set)'),
                        ],
                      ),
                    ),
                  TextField(
                    controller: _keyController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: _hasStoredKey
                          ? 'Replace API key'
                          : 'Buffer API key',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _busy ? null : _save,
                        child: const Text('Save'),
                      ),
                      OutlinedButton.icon(
                        icon: _busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                            : const Icon(LucideIcons.plugZap, size: 14),
                        label: const Text('Test connection'),
                        onPressed: (_busy ||
                                (!_hasStoredKey &&
                                    _keyController.text.trim().isEmpty))
                            ? null
                            : _testConnection,
                      ),
                      if (_hasStoredKey)
                        OutlinedButton(
                          onPressed: _busy ? null : _disconnect,
                          child: const Text('Disconnect'),
                        ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  if (_testedChannels != null) ...[
                    const SizedBox(height: 16),
                    Text(
                        _testedChannels!.isEmpty
                            ? 'Connection works, but no channels are '
                                'connected in Buffer yet.'
                            : 'Connection works — channels:',
                        style: theme.textTheme.titleSmall),
                    for (final ch in _testedChannels!)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading:
                            const Icon(LucideIcons.share2, size: 16),
                        title: Text(ch.name),
                        subtitle: Text(ch.service),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
