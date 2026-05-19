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
      AuthUser? user;
      if (provider == 'google') {
        user = await AuthService.instance.signInGoogleModeB(password: password);
      } else {
        user = await AuthService.instance.signInAppleModeB(password: password);
      }
      if (!mounted) return;
      if (user == null) {
        // User cancelled the OAuth flow.
        setState(() => _busy = false);
        return;
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
