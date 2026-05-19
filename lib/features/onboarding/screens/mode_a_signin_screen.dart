/// Mode A (OAuth-only — legacy) sign-in screen.
///
/// Existing Mode A users **never see this screen** — they have a
/// cached session in SecureStorage from before the seed-as-identity
/// redesign shipped. This route is for new users who pick "Standard
/// security" on the mode chooser.
///
/// Calls the existing `AuthService.signInWithGoogle()` /
/// `signInWithApple()` paths verbatim — no behavior change for users
/// who go through this flow vs the legacy entry points.
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fula_files/core/services/auth_service.dart';

class ModeASignInScreen extends ConsumerStatefulWidget {
  const ModeASignInScreen({super.key});

  @override
  ConsumerState<ModeASignInScreen> createState() => _ModeASignInScreenState();
}

class _ModeASignInScreenState extends ConsumerState<ModeASignInScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signInGoogle() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await AuthService.instance.signInWithGoogle();
      if (!mounted) return;
      if (user == null) {
        // User cancelled.
        setState(() => _busy = false);
        return;
      }
      // Persist the mode tag for symmetry with Mode B/C flows.
      // Future cold-starts can use this to know which sign-in screen
      // to show on a new device.
      context.go('/');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<void> _signInApple() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await AuthService.instance.signInWithApple();
      if (!mounted) return;
      if (user == null) {
        setState(() => _busy = false);
        return;
      }
      context.go('/');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appleAvailable = Platform.isIOS || Platform.isMacOS;
    return Scaffold(
      appBar: AppBar(title: const Text('Standard sign-in')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.account_circle_outlined,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Standard-security vault',
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Your encryption is tied to your Google or Apple '
                'account. Anyone who can sign in as you can read '
                'your files. For stronger protection, go back and '
                'pick the password option.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
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
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _busy ? null : _signInGoogle,
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
                  onPressed: _busy ? null : _signInApple,
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
