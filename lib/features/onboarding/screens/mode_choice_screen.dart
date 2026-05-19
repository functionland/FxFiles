/// First-time-sign-in screen. The user picks one of three vault modes.
/// Audit F-A1 / F-A3 redesign (2026-05-18). See:
///  - https://github.com/functionland/fula-api/issues/14
///  - https://github.com/functionland/pinning-service/commit/25280a1
///
/// **Existing Mode A users never see this screen** — they're already
/// signed in and have `userCredentials` in SecureStorage from before
/// this feature shipped. The screen surfaces only when a NEW user
/// (or one on a NEW device with no cached session) opens FxFiles and
/// taps a sign-in entry point.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class ModeChoiceScreen extends ConsumerWidget {
  const ModeChoiceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in to FxFiles'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Icon(
                Icons.lock_outline,
                size: 56,
                color: theme.colorScheme.primary,
              ),
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
                title: 'Maximum security',
                subtitle: 'Sign in with Google or Apple AND a password.\n'
                    'A leak of your Google account alone does NOT '
                    'expose your files.',
                badge: 'Recommended',
                badgeColor: Colors.green,
                icon: Icons.shield,
                onTap: () => context.go('/onboarding/mode-b'),
              ),
              const SizedBox(height: 16),
              _ModeCard(
                title: 'Standard security',
                subtitle: 'Sign in with Google or Apple only.\n'
                    'Easiest. Your encryption is tied to your '
                    'Google / Apple account.',
                badge: 'Easiest',
                badgeColor: Colors.blueGrey,
                icon: Icons.account_circle_outlined,
                onTap: () => context.go('/onboarding/mode-a'),
              ),
              const SizedBox(height: 16),
              _ModeCard(
                title: 'Passphrase only',
                subtitle: 'No Google or Apple required.\n'
                    'You\'ll get a 24-word recovery phrase. '
                    'Lose it = lose your data forever.',
                badge: 'Advanced',
                badgeColor: Colors.deepPurple,
                icon: Icons.key,
                onTap: () => context.go('/onboarding/mode-c'),
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
          ),
        ),
      ),
    );
  }
}

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
                          child: Text(title, style: theme.textTheme.titleMedium),
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
