import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fula_files/core/services/issuer_client.dart';
import 'package:fula_files/web/services/web_session.dart';

/// Mode C (recovery-phrase) sign-in for the web shell: create a new
/// vault or open an existing one. Google/Apple sign-in arrive in later
/// phases (P6/P7).
class WebSignInScreen extends StatefulWidget {
  const WebSignInScreen({super.key});

  @override
  State<WebSignInScreen> createState() => _WebSignInScreenState();
}

class _WebSignInScreenState extends State<WebSignInScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  // Create-vault state
  String? _generatedPhrase;
  bool _storedConfirmed = false;
  bool _tosAccepted = false;

  // Restore state
  final _restoreController = TextEditingController();

  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _tabs.dispose();
    _restoreController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final phrase = await WebSession.instance.generateRecoveryMnemonic();
    setState(() {
      _generatedPhrase = phrase;
      _storedConfirmed = false;
    });
  }

  Future<void> _signIn(String seed) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await WebSession.instance.signInModeC(seed: seed);
      // Router redirect takes over on session change.
    } on IssuerException catch (e) {
      setState(() => _error = _issuerErrorCopy(e));
    } catch (e) {
      setState(() => _error = 'Sign-in failed: $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _issuerErrorCopy(IssuerException e) {
    switch (e.code) {
      case 'PUBLIC_KEY_MISMATCH':
        return 'This phrase does not match the vault registered under its '
            'identity. Double-check the words and their order.';
      case 'SIGNATURE_INVALID':
        return 'The phrase could not be verified. Check the words and try again.';
      case 'TIMEOUT':
      case 'TRANSPORT':
        return 'Could not reach the sign-in service. Check your connection '
            'and try again.';
      default:
        return 'Sign-in failed (${e.code ?? e.statusCode}): ${e.message}';
    }
  }

  Future<void> _restoreSubmit() async {
    final seed = _restoreController.text.trim();
    if (seed.isEmpty) {
      setState(() => _error = 'Enter your recovery phrase.');
      return;
    }
    final valid = await WebSession.instance.isValidMnemonic(seed);
    if (!valid) {
      // Non-BIP39 passphrases are allowed for Mode C (any strong seed),
      // but warn when it LOOKS like a mistyped mnemonic (24 space-
      // separated words that fail the checksum).
      final words = seed.split(RegExp(r'\s+'));
      if (words.length >= 12 && words.length <= 24) {
        setState(() => _error =
            'That looks like a recovery phrase but fails its checksum. '
            'Check each word and the order.');
        return;
      }
    }
    await _signIn(seed);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.folder_shared, size: 56),
                  const SizedBox(height: 8),
                  Text(
                    'FxFiles',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  Text(
                    'Your encrypted cloud storage, in the browser',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  TabBar(
                    controller: _tabs,
                    tabs: const [
                      Tab(text: 'Open vault'),
                      Tab(text: 'Create vault'),
                    ],
                  ),
                  SizedBox(
                    height: 340,
                    child: TabBarView(
                      controller: _tabs,
                      children: [
                        _buildRestoreTab(context),
                        _buildCreateTab(context),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error),
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

  Widget _buildRestoreTab(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter the recovery phrase of an existing vault. The same '
            'phrase opens the same vault on every device.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _restoreController,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'word1 word2 word3 …',
              labelText: 'Recovery phrase',
            ),
          ),
          const Spacer(),
          FilledButton(
            onPressed: _working ? null : _restoreSubmit,
            child: _working
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Open vault'),
          ),
        ],
      ),
    );
  }

  Widget _buildCreateTab(BuildContext context) {
    final phrase = _generatedPhrase;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (phrase == null) ...[
            Text(
              'A new vault is protected by a 24-word recovery phrase. '
              'It is the ONLY way in — there is no reset if you lose it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _generate,
              child: const Text('Generate recovery phrase'),
            ),
          ] else ...[
            Expanded(
              child: SingleChildScrollView(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: Theme.of(context).colorScheme.outline),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    phrase,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 14, height: 1.6),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: phrase));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Copied — store it somewhere safe')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy'),
                ),
                TextButton(
                  onPressed: _generate,
                  child: const Text('Regenerate'),
                ),
              ],
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _storedConfirmed,
              onChanged: (v) => setState(() => _storedConfirmed = v ?? false),
              title: const Text(
                'I stored my recovery phrase safely. I understand it cannot '
                'be recovered if lost.',
                style: TextStyle(fontSize: 13),
              ),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _tosAccepted,
              onChanged: (v) => setState(() => _tosAccepted = v ?? false),
              title: const Text(
                'I agree to the FxFiles Terms of Service.',
                style: TextStyle(fontSize: 13),
              ),
            ),
            FilledButton(
              onPressed: (_storedConfirmed && _tosAccepted && !_working)
                  ? () => _signIn(phrase)
                  : null,
              child: _working
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create vault'),
            ),
          ],
        ],
      ),
    );
  }
}
