import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/services/auth_service.dart' show AuthService, AuthUser;
import 'package:fula_files/core/services/deep_link_service.dart';
import 'package:fula_files/core/services/nft_wallet_service.dart';
import 'package:fula_files/features/billing/providers/storage_provider.dart';
import 'package:fula_files/shared/widgets/step_row.dart';

/// Bottom sheet reached from [SetupStatusBar] or a locked Create tile.
/// Shows the three setup steps (Sign in / Connect cloud storage / Link wallet)
/// and drives the user through them without the old 180s silent timeout.
class SetupUnlockSheet extends ConsumerStatefulWidget {
  final bool initialHasJwt;
  final Future<void> Function() onSignInRequested;
  final Future<bool> Function() onLinkWalletRequested;
  final ValueChanged<String> onJwtReceived;

  const SetupUnlockSheet({
    super.key,
    required this.initialHasJwt,
    required this.onSignInRequested,
    required this.onLinkWalletRequested,
    required this.onJwtReceived,
  });

  static Future<void> show(
    BuildContext context, {
    required bool initialHasJwt,
    required Future<void> Function() onSignInRequested,
    required Future<bool> Function() onLinkWalletRequested,
    required ValueChanged<String> onJwtReceived,
    bool dismissible = true,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: dismissible,
      enableDrag: dismissible,
      backgroundColor: Colors.transparent,
      builder: (_) => SetupUnlockSheet(
        initialHasJwt: initialHasJwt,
        onSignInRequested: onSignInRequested,
        onLinkWalletRequested: onLinkWalletRequested,
        onJwtReceived: onJwtReceived,
      ),
    );
  }

  @override
  ConsumerState<SetupUnlockSheet> createState() => _SetupUnlockSheetState();
}

class _SetupUnlockSheetState extends ConsumerState<SetupUnlockSheet> {
  bool _gettingApiKey = false;
  bool _linkingWallet = false;
  bool _hasJwt = false;
  StreamSubscription<String>? _apiKeySub;
  StreamSubscription<AuthUser?>? _authSub;

  @override
  void initState() {
    super.initState();
    _hasJwt = widget.initialHasJwt;
    _apiKeySub = DeepLinkService.instance.onApiKeyReceived.listen((apiKey) {
      if (!mounted) return;
      setState(() {
        _gettingApiKey = false;
        _hasJwt = true;
      });
      widget.onJwtReceived(apiKey);
    });
    // Rebuild when sign-in completes — the profile sheet pops before awaiting
    // the actual sign-in, so awaiting onSignInRequested() returns too early.
    _authSub = AuthService.instance.authStateChanges.listen((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _apiKeySub?.cancel();
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _startGetApiKey() async {
    setState(() => _gettingApiKey = true);
    final ok = await DeepLinkService.instance.openGetApiKeyPage();
    if (!ok && mounted) {
      setState(() => _gettingApiKey = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open browser. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
    // No 180s auto-cancel — the user has as long as they need. The deep-link
    // stream (above) closes the spinner when cloud access is granted.
  }

  void _cancelGetApiKey() {
    setState(() => _gettingApiKey = false);
  }

  Future<void> _startLinkWallet() async {
    setState(() => _linkingWallet = true);
    await widget.onLinkWalletRequested();
    if (mounted) setState(() => _linkingWallet = false);
  }

  Future<void> _startSignIn() async {
    await widget.onSignInRequested();
    // After the profile sheet returns, rebuild so the auth state refreshes
    // (AuthService is read directly in build, not via a stream).
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLoggedIn = AuthService.instance.isAuthenticated;
    final storageState = ref.watch(storageProvider);

    final hasJwt = _hasJwt; // first-known via initial check below
    final hasAnyWallet =
        storageState.wallets.isNotEmpty || NftWalletService.instance.hasWallet;

    // Determine step states. The first incomplete step becomes "active".
    StepRowState signInState;
    StepRowState cloudState;
    StepRowState walletState;

    if (isLoggedIn) {
      signInState = StepRowState.done;
    } else {
      signInState = StepRowState.active;
    }

    if (hasJwt) {
      cloudState = StepRowState.done;
    } else if (signInState == StepRowState.done) {
      cloudState = StepRowState.active;
    } else {
      cloudState = StepRowState.pending;
    }

    if (hasAnyWallet) {
      walletState = StepRowState.done;
    } else if (cloudState == StepRowState.done) {
      walletState = StepRowState.active;
    } else {
      walletState = StepRowState.pending;
    }

    // Only Sign in + Connect cloud are required; wallet is optional.
    final mandatoryRemaining = [signInState, cloudState]
        .where((s) => s != StepRowState.done)
        .length;

    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (ctx, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Drag handle
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _header(context, mandatoryRemaining),
                  const SizedBox(height: 16),
                  StepRow(
                    state: signInState,
                    number: '1',
                    title: 'Sign in to your account',
                    subtitle: isLoggedIn
                        ? (AuthService.instance.currentUser?.email ??
                            'Signed in')
                        : 'So cloud sync and sharing know who you are.',
                    ctaLabel:
                        signInState == StepRowState.active ? 'Sign in' : null,
                    onCta: signInState == StepRowState.active
                        ? _startSignIn
                        : null,
                  ),
                  const SizedBox(height: 10),
                  StepRow(
                    state: cloudState,
                    number: '2',
                    title: 'Connect cloud storage',
                    subtitle: hasJwt
                        ? 'Cloud access is ready.'
                        : 'We\'ll open your browser so you can grant cloud access.',
                    ctaLabel: cloudState == StepRowState.active && !_gettingApiKey
                        ? 'Connect'
                        : null,
                    onCta: cloudState == StepRowState.active && !_gettingApiKey
                        ? _startGetApiKey
                        : null,
                    expanded: _gettingApiKey ? _waitingForCloud() : null,
                  ),
                  const SizedBox(height: 10),
                  StepRow(
                    state: walletState,
                    optional: true,
                    title: 'Link a wallet',
                    subtitle: hasAnyWallet
                        ? (storageState.wallets.isNotEmpty
                            ? storageState.wallets.first.shortAddress
                            : 'Wallet connected')
                        : 'Unlocks NFTs and adds storage credits.',
                    ctaLabel:
                        walletState == StepRowState.active && !_linkingWallet
                            ? 'Link'
                            : null,
                    onCta: walletState == StepRowState.active && !_linkingWallet
                        ? _startLinkWallet
                        : null,
                    expanded: _linkingWallet
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.primary,
                                  ),
                                ),
                                SizedBox(width: 10),
                                Text(
                                  'Approve the request in your wallet app…',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Close anytime — the "Finish setup" bar at the top brings this back.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, int mandatoryRemaining) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.primaryFaint,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: const Icon(LucideIcons.gem, color: AppColors.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Power up your private cloud',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                mandatoryRemaining == 0
                    ? 'You\'re all set. Linking a wallet is optional.'
                    : '$mandatoryRemaining required ${mandatoryRemaining == 1 ? "step" : "steps"} left.',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(LucideIcons.x, size: 18),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: 'Close',
        ),
      ],
    );
  }

  Widget _waitingForCloud() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Waiting for you to finish signing in…',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'No timer. Take your time — switch apps and come back.',
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _startGetApiKey,
              icon: const Icon(LucideIcons.externalLink, size: 14),
              label: const Text('Re-open browser'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: BorderSide(
                  color: AppColors.primary.withValues(alpha: 0.4),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _cancelGetApiKey,
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurfaceVariant,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                textStyle: const TextStyle(fontSize: 12),
              ),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }
}
