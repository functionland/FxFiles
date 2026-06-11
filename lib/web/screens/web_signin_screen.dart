import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in_web/web_only.dart' as gsi_web;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'package:fula_files/core/services/issuer_client.dart';
import 'package:fula_files/web/services/web_session.dart';

/// Web sign-in mirroring the native onboarding flow
/// (lib/features/onboarding/): the mode-choice screen with its three
/// cards, then per-mode pages with the same titles and actions.
/// Platform difference: on web, Google sign-in can only be triggered by
/// the GIS-rendered button (google_sign_in v7 web), so Mode A/B show
/// that button where native shows its own "Continue with Google".
class WebSignInScreen extends StatefulWidget {
  const WebSignInScreen({super.key});

  @override
  State<WebSignInScreen> createState() => _WebSignInScreenState();
}

enum _Page { choice, modeA, modeB, modeC }

enum _ModeCPhase { menu, create, restore }

class _WebSignInScreenState extends State<WebSignInScreen> {
  _Page _page = _Page.choice;
  _ModeCPhase _modeCPhase = _ModeCPhase.menu;

  // Mode B
  final _passwordController = TextEditingController();

  // Mode C create
  String? _generatedPhrase;
  bool _storedConfirmed = false;
  bool _tosAccepted = false;

  // Mode C restore
  final _restoreController = TextEditingController();

  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // GIS button events are the only Google sign-in trigger on web.
    WebSession.instance.initGoogleWeb();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _restoreController.dispose();
    super.dispose();
  }

  void _goto(_Page page) {
    setState(() {
      _page = page;
      _modeCPhase = _ModeCPhase.menu;
      _error = null;
      // Park the Mode B passphrase only while ON the Mode B page.
      WebSession.instance.pendingOAuthPassphrase =
          page == _Page.modeB ? _passwordController.text : '';
    });
  }

  Future<void> _signInModeC(String seed) async {
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
      final words = seed.split(RegExp(r'\s+'));
      if (words.length >= 12 && words.length <= 24) {
        setState(() => _error =
            'That looks like a recovery phrase but fails its checksum. '
            'Check each word and the order.');
        return;
      }
    }
    await _signInModeC(seed);
  }

  Future<void> _generate() async {
    final phrase = await WebSession.instance.generateRecoveryMnemonic();
    setState(() {
      _generatedPhrase = phrase;
      _storedConfirmed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: AnimatedBuilder(
                  animation: WebSession.instance,
                  builder: (context, _) => switch (_page) {
                    _Page.choice => _buildChoice(context),
                    _Page.modeA => _buildModeA(context),
                    _Page.modeB => _buildModeB(context),
                    _Page.modeC => _buildModeC(context),
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- choice

  Widget _buildChoice(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.lock_outline, size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          'Choose how to secure your vault',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Your files are end-to-end encrypted on every option. '
          'Pick the level of protection you want.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 32),
        _ModeCard(
          title: 'Maximum Security',
          subtitle: 'Email + Password',
          badge: 'Recommended',
          badgeColor: Colors.green,
          icon: Icons.shield,
          onTap: () => _goto(_Page.modeB),
        ),
        const SizedBox(height: 16),
        _ModeCard(
          title: 'Maximum Privacy',
          subtitle: 'No email, all local',
          badge: 'Advanced',
          badgeColor: Colors.deepPurple,
          icon: Icons.key,
          onTap: () => _goto(_Page.modeC),
        ),
        const SizedBox(height: 16),
        _ModeCard(
          title: 'Maximum Ease',
          subtitle: 'Google or Apple only',
          badge: 'Easiest',
          badgeColor: Colors.blueGrey,
          icon: Icons.account_circle_outlined,
          onTap: () => _goto(_Page.modeA),
        ),
        const SizedBox(height: 24),
        Text(
          'You can\'t switch modes later without re-uploading your '
          'files — each mode is a separate vault.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------- header

  Widget _header(BuildContext context, String title) {
    return Row(
      children: [
        IconButton(
          tooltip: 'Back to mode selection',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => _goto(_Page.choice),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
      ],
    );
  }

  Widget _oauthButtons(BuildContext context) {
    final session = WebSession.instance;
    if (session.busy || _working) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // GIS-rendered button (the only Google trigger on web).
        Center(child: gsi_web.renderButton()),
        const SizedBox(height: 12),
        SignInWithAppleButton(
          text: 'Continue with Apple',
          onPressed: () => WebSession.instance.signInWithAppleWeb(),
          style: SignInWithAppleButtonStyle.whiteOutlined,
        ),
        if (session.lastError != null) ...[
          const SizedBox(height: 8),
          Text(
            session.lastError!,
            style: TextStyle(
                color: Theme.of(context).colorScheme.error, fontSize: 12),
          ),
        ],
      ],
    );
  }

  // ----------------------------------------------------------------- mode A

  Widget _buildModeA(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, 'Standard sign-in'),
        const SizedBox(height: 8),
        Text(
          'Sign in with the same Google or Apple account you use in the '
          'FxFiles app — your existing files appear here.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        _oauthButtons(context),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => _goto(_Page.choice),
          child: const Text('Back to mode selection'),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------- mode B

  Widget _buildModeB(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, 'Sign in with password'),
        const SizedBox(height: 8),
        Text(
          'Your Google or Apple account identifies you; your password '
          'protects your files. Both are required — use the same pair '
          'as in the FxFiles app.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _passwordController,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (v) => WebSession.instance.pendingOAuthPassphrase = v,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Password',
          ),
        ),
        const SizedBox(height: 16),
        _oauthButtons(context),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => _goto(_Page.choice),
          child: const Text('Back to mode selection'),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------- mode C

  Widget _buildModeC(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[
      _header(context, 'Passphrase-only vault'),
      const SizedBox(height: 8),
    ];

    switch (_modeCPhase) {
      case _ModeCPhase.menu:
        children.addAll([
          Text(
            'No account needed. A 24-word recovery phrase is the ONLY '
            'way into this vault — there is no reset if you lose it.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              setState(() => _modeCPhase = _ModeCPhase.create);
              _generate();
            },
            child: const Text('Create new vault'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () =>
                setState(() => _modeCPhase = _ModeCPhase.restore),
            child: const Text('Restore from recovery phrase'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => _goto(_Page.choice),
            child: const Text('Back to mode selection'),
          ),
        ]);
      case _ModeCPhase.create:
        final phrase = _generatedPhrase;
        children.addAll([
          if (phrase == null)
            const Center(
                child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ))
          else ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outline),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                phrase,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 14, height: 1.6),
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
                            content:
                                Text('Copied — store it somewhere safe')),
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
              onChanged: (v) =>
                  setState(() => _storedConfirmed = v ?? false),
              title: const Text(
                'I stored my recovery phrase safely. I understand it '
                'cannot be recovered if lost.',
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
                  ? () => _signInModeC(phrase)
                  : null,
              child: _working
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create new vault'),
            ),
            TextButton(
              onPressed: () =>
                  setState(() => _modeCPhase = _ModeCPhase.menu),
              child: const Text('Back'),
            ),
          ],
        ]);
      case _ModeCPhase.restore:
        children.addAll([
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
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _working ? null : _restoreSubmit,
            child: _working
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Restore vault'),
          ),
          TextButton(
            onPressed: () => setState(() => _modeCPhase = _ModeCPhase.menu),
            child: const Text('Back'),
          ),
        ]);
    }

    if (_error != null) {
      children.addAll([
        const SizedBox(height: 8),
        Text(
          _error!,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      ]);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// Mirror of the native onboarding _ModeCard
/// (lib/features/onboarding/screens/mode_choice_screen.dart).
class _ModeCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String badge;
  final Color badgeColor;
  final IconData icon;
  final VoidCallback onTap;

  const _ModeCard({
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.badgeColor,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 32, color: theme.colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(title,
                              style: theme.textTheme.titleMedium),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: badgeColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            badge,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: badgeColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
