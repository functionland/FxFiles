/// Mode B (OAuth + password) sign-in / sign-up screen. The user
/// picks Google or Apple, enters a password, and the app does the
/// OAuth dance + register-mode-b in one shot.
///
/// Idempotent at the issuer: same password + same OAuth identity →
/// same effective_user_id → same vault. So this single screen
/// handles BOTH first-time sign-up and returning-on-new-device.
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/issuer_client.dart';

class ModeBSignInScreen extends ConsumerStatefulWidget {
  const ModeBSignInScreen({super.key});

  @override
  ConsumerState<ModeBSignInScreen> createState() => _ModeBSignInScreenState();
}

class _ModeBSignInScreenState extends ConsumerState<ModeBSignInScreen> {
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _passwordVisible = false;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn(String provider) async {
    final password = _passwordController.text;
    if (password.isEmpty) {
      setState(() => _error = 'Enter a password to continue.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      ({AuthUser user, bool hasModeA})? result;
      if (provider == 'google') {
        result = await AuthService.instance.signInGoogleModeB(password: password);
      } else {
        result = await AuthService.instance.signInAppleModeB(password: password);
      }
      if (!mounted) return;
      if (result == null) {
        // User cancelled the OAuth flow.
        setState(() => _busy = false);
        return;
      }
      // Audit fix #4: warn before navigating away if the same OAuth
      // identity already has a Mode A vault — the new Mode B vault is
      // SEPARATE and the user's existing files won't appear here.
      if (result.hasModeA) {
        await _showModeAExistsDialog();
        if (!mounted) return;
      }
      context.go('/');
    } on IssuerException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _humanizeIssuerError(e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Sign-in failed: $e';
      });
    }
  }

  Future<void> _showModeAExistsDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.info_outline, size: 36, color: Colors.orange),
        title: const Text('Existing vault detected'),
        content: const Text(
          'You already have a Standard-security (Mode A) vault on this '
          'Google/Apple account. The Maximum-security vault you just '
          'created is SEPARATE — your existing files are NOT in this '
          'vault.\n\n'
          'To access your old files, sign out and sign in with Standard '
          'security (no password). To keep using the new vault, continue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('I understand'),
          ),
        ],
      ),
    );
  }

  String _humanizeIssuerError(IssuerException e) {
    switch (e.code) {
      case 'PUBLIC_KEY_MISMATCH':
        return 'A vault already exists for this account with a different '
            'password. Use the original password, or contact support.';
      case 'SIGNATURE_INVALID':
        return 'Authentication failed. This is a bug — please report it.';
      case 'VALIDATION_ERROR':
        return 'Bad input format. Please try again.';
      case 'TIMEOUT':
      case 'TRANSPORT':
        return 'Could not reach the server. Check your connection.';
      default:
        return e.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appleAvailable = Platform.isIOS || Platform.isMacOS;
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in with password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.shield, size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                'Maximum-security vault',
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Your password is mixed with your Google/Apple identity '
                'into the encryption key. Both are required to access '
                'your files.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _passwordController,
                obscureText: !_passwordVisible,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: 'Password',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_passwordVisible
                        ? Icons.visibility_off
                        : Icons.visibility),
                    onPressed: () => setState(
                        () => _passwordVisible = !_passwordVisible),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'If you forget this password, your files become '
                'unrecoverable. Pick something you\'ll remember.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.orange,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _busy ? null : () => _signIn('google'),
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.g_mobiledata, size: 28),
                label: const Text('Continue with Google'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              if (appleAvailable) ...[
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : () => _signIn('apple'),
                  icon: const Icon(Icons.apple, size: 22),
                  label: const Text('Continue with Apple'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              TextButton(
                onPressed: _busy ? null : () => context.go('/onboarding'),
                child: const Text('Back to mode selection'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
