/// Mode C (passphrase-only, no OAuth) sign-in / sign-up.
///
/// Three sub-flows on this screen:
///   1. **Create new vault** — generates a 24-word BIP39 mnemonic,
///      shows it to the user, runs a 3-of-24 partial verification
///      before registering with the issuer. The mnemonic IS the seed;
///      the user types it back on any new device.
///   2. **Use existing vault** — user types the mnemonic they saved.
///      Same idempotent registration path; the issuer recognizes
///      the existing public key and returns the same effective_user_id.
///   3. (Below the fold) — back link to mode chooser.
///
/// "Seed IS the user" — anyone who knows the mnemonic IS this user.
/// No password reset, no recovery via OAuth.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/issuer_client.dart';

class ModeCSignInScreen extends ConsumerStatefulWidget {
  const ModeCSignInScreen({super.key});

  @override
  ConsumerState<ModeCSignInScreen> createState() => _ModeCSignInScreenState();
}

class _ModeCSignInScreenState extends ConsumerState<ModeCSignInScreen> {
  bool _restoreMode = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Passphrase-only vault')),
      body: SafeArea(
        child: _restoreMode
            ? _RestoreVaultPanel(
                onBack: () => setState(() => _restoreMode = false),
              )
            : _CreateOrRestoreSelector(
                onCreate: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _CreateVaultFlow(),
                  ),
                ),
                onRestore: () => setState(() => _restoreMode = true),
              ),
      ),
    );
  }
}

// ============================================================================
// Selector panel (create vs restore)
// ============================================================================

class _CreateOrRestoreSelector extends StatelessWidget {
  final VoidCallback onCreate;
  final VoidCallback onRestore;

  const _CreateOrRestoreSelector({
    required this.onCreate,
    required this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Icon(Icons.key, size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            'Passphrase-only vault',
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'No Google or Apple account — the only thing tying you to '
            'your files is a 24-word recovery phrase.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),
          FilledButton(
            onPressed: onCreate,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Text('Create new vault'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onRestore,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Text('Restore from recovery phrase'),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber, color: Colors.red),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'There is no "Forgot password". If you lose your '
                    'recovery phrase, your files are gone forever — '
                    'we cannot reset it.',
                    style: TextStyle(color: theme.colorScheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// CREATE flow — multi-step wizard
// ============================================================================

class _CreateVaultFlow extends StatefulWidget {
  const _CreateVaultFlow();

  @override
  State<_CreateVaultFlow> createState() => _CreateVaultFlowState();
}

class _CreateVaultFlowState extends State<_CreateVaultFlow> {
  String? _mnemonic;
  List<String>? _words;
  int _step = 0; // -1=loading, 0=display, 1=verify, 2=register

  // Verification state.
  List<int> _verifyIndices = const [];
  final List<TextEditingController> _verifyControllers =
      List.generate(3, (_) => TextEditingController());
  String? _verifyError;
  bool _registering = false;
  String? _registerError;

  @override
  void initState() {
    super.initState();
    _generateMnemonicAsync();
  }

  Future<void> _generateMnemonicAsync() async {
    final mnemonic = await AuthService.instance.generateRecoveryMnemonic();
    if (!mounted) return;
    setState(() {
      _mnemonic = mnemonic;
      _words = mnemonic.split(RegExp(r'\s+'));
      // Pick 3 distinct random positions for partial verification.
      final positions =
          List<int>.generate(_words!.length, (i) => i)..shuffle();
      _verifyIndices = positions.take(3).toList()..sort();
    });
  }

  @override
  void dispose() {
    for (final c in _verifyControllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _doRegister() async {
    final mnemonic = _mnemonic;
    if (mnemonic == null) return;
    setState(() {
      _registering = true;
      _registerError = null;
    });
    try {
      await AuthService.instance.signInModeC(seed: mnemonic);
      if (!mounted) return;
      // Navigate home; AuthService set _currentUser + persisted state.
      Navigator.of(context).popUntil((r) => r.isFirst);
      GoRouter.of(context).go('/');
    } on IssuerException catch (e) {
      if (!mounted) return;
      setState(() {
        _registering = false;
        _registerError = e.code == 'PUBLIC_KEY_MISMATCH'
            ? 'A vault for this phrase already exists with a different '
                'key. This should be impossible — please report it.'
            : 'Server error: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _registering = false;
        _registerError = 'Failed to create vault: $e';
      });
    }
  }

  void _checkVerification() {
    final words = _words;
    if (words == null) return;
    for (var i = 0; i < 3; i++) {
      final expected = words[_verifyIndices[i]].trim().toLowerCase();
      final got = _verifyControllers[i].text.trim().toLowerCase();
      if (got != expected) {
        setState(() => _verifyError =
            'Word ${_verifyIndices[i] + 1} doesn\'t match. Re-check your '
            'recorded phrase.');
        return;
      }
    }
    setState(() {
      _verifyError = null;
      _step = 2;
    });
    _doRegister();
  }

  @override
  Widget build(BuildContext context) {
    if (_words == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Generating phrase…')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text([
          'Save your phrase',
          'Verify your phrase',
          'Creating vault…',
        ][_step]),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: switch (_step) {
            0 => _buildDisplayStep(context),
            1 => _buildVerifyStep(context),
            _ => _buildRegisterStep(context),
          },
        ),
      ),
    );
  }

  Widget _buildDisplayStep(BuildContext context) {
    final theme = Theme.of(context);
    final words = _words!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber, color: Colors.red, size: 28),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Write these 24 words down on paper IN ORDER. '
                  'Anyone who has them has your files. We cannot show '
                  'them to you again.',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 4.5,
              crossAxisSpacing: 8,
              mainAxisSpacing: 4,
            ),
            itemCount: words.length,
            itemBuilder: (_, i) => Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    '${i + 1}.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    words[i],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => setState(() => _step = 1),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: const Text('I\'ve saved it — verify'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildVerifyStep(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Type 3 of the 24 words from your recovery phrase.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        for (var i = 0; i < 3; i++) ...[
          TextField(
            controller: _verifyControllers[i],
            enabled: !_registering,
            decoration: InputDecoration(
              labelText: 'Word #${_verifyIndices[i] + 1}',
              border: const OutlineInputBorder(),
            ),
            textInputAction:
                i == 2 ? TextInputAction.done : TextInputAction.next,
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: 12),
        ],
        if (_verifyError != null) ...[
          const SizedBox(height: 4),
          Text(_verifyError!, style: const TextStyle(color: Colors.red)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _registering ? null : _checkVerification,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: const Text('Continue'),
        ),
        TextButton(
          onPressed: _registering ? null : () => setState(() => _step = 0),
          child: const Text('Back — show phrase again'),
        ),
      ],
    );
  }

  Widget _buildRegisterStep(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 64),
        if (_registerError == null) ...[
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 24),
          const Center(child: Text('Creating your vault…')),
        ] else ...[
          const Icon(Icons.error_outline, size: 56, color: Colors.red),
          const SizedBox(height: 16),
          Text(
            _registerError!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.red),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () {
              setState(() {
                _step = 1;
                _registerError = null;
              });
            },
            child: const Text('Try again'),
          ),
        ],
      ],
    );
  }
}

// ============================================================================
// RESTORE flow — user types their saved mnemonic
// ============================================================================

class _RestoreVaultPanel extends StatefulWidget {
  final VoidCallback onBack;
  const _RestoreVaultPanel({required this.onBack});

  @override
  State<_RestoreVaultPanel> createState() => _RestoreVaultPanelState();
}

class _RestoreVaultPanelState extends State<_RestoreVaultPanel> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _doRestore() async {
    final mnemonic = _controller.text.trim();
    if (mnemonic.isEmpty) {
      setState(() => _error = 'Enter your recovery phrase.');
      return;
    }
    final valid = await AuthService.instance.isValidMnemonic(mnemonic);
    if (!valid) {
      if (!mounted) return;
      setState(() => _error =
          'That doesn\'t look like a valid 12 / 18 / 24-word BIP39 phrase. '
          'Check for typos.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.instance.signInModeC(seed: mnemonic);
      if (!mounted) return;
      GoRouter.of(context).go('/');
    } on IssuerException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.code == 'PUBLIC_KEY_MISMATCH'
            ? 'A vault exists for this phrase with a different key. '
                'This shouldn\'t happen for a passphrase-only vault.'
            : 'Server error: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Restore failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Icon(Icons.key, size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            'Restore your vault',
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Text(
            'Type your 24-word recovery phrase, separated by spaces. '
            'Order matters.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            enabled: !_busy,
            maxLines: 4,
            minLines: 3,
            decoration: const InputDecoration(
              hintText: 'word1 word2 word3 …',
              border: OutlineInputBorder(),
            ),
            autocorrect: false,
            enableSuggestions: false,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _doRestore,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Restore vault'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : widget.onBack,
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }
}
