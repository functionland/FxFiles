import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/core/models/billing/storage_info.dart';
import 'package:fula_files/core/services/auth_core.dart';
import 'package:fula_files/core/services/billing_api_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/nft_wallet_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/share_link_builder.dart';
import 'package:fula_files/web/services/web_session.dart';

/// App version label shown in About + the home footer. Kept in one place
/// so the two stay in sync (the home footer imports this).
const String kWebAppVersion = 'v1.11.16.0';

/// In-app web Settings page. Replaces the old behavior where the gear icon
/// opened cloud.fx.land in a new tab. Mirrors the mobile Settings screen's
/// sections that are meaningful on web (Account, Your Share ID, NFT Wallet,
/// Security, API Configuration, About) and falls back to cloud.fx.land via
/// the "Other settings" row for the sections that are mobile-only.
///
/// Layout: the two things people actually come here for — their profile and
/// their billing/storage — sit at the top, and everything else lives behind a
/// collapsed "More" tile so the page reads as a short list rather than a wall
/// of sections.
class WebSettingsScreen extends StatefulWidget {
  const WebSettingsScreen({super.key});

  @override
  State<WebSettingsScreen> createState() => _WebSettingsScreenState();
}

class _WebSettingsScreenState extends State<WebSettingsScreen> {
  // Share ID + NFT wallet are derived async; resolve once and cache the
  // Futures so a rebuild (e.g. reveal toggle) doesn't re-derive.
  late final Future<String> _shareId = _resolveShareId();
  late final Future<String?> _nftAddress =
      NftWalletService.instance.getAddress();
  late final Future<String?> _encryptionKey =
      SecureStorageService.instance.read(SecureStorageKeys.encryptionKey);

  /// Storage + credits for the Billing row's subtitle. Deliberately
  /// non-throwing: see [_loadStorage].
  late final Future<StorageInfo?> _storage = _loadStorage();

  bool _revealKey = false;

  Future<String> _resolveShareId() async {
    final pk = await FulaApiService.instance.getPublicKey();
    return encodeFulaShareId(pk);
  }

  /// Best-effort storage/credits fetch for the Billing subtitle.
  ///
  /// Never throws and never surfaces an error: `getStorageAndCredits()`
  /// fails fast when there is no JWT — its `_ensureConfigured` throws before
  /// any HTTP, which an `async` method surfaces as a rejected Future — and
  /// that is the normal state both when signed out and for a tokenless
  /// Mode-C vault user. An error row at the very top of the page is exactly
  /// the noise this layout exists to remove, so on any failure the row falls
  /// back to its static subtitle. Same "stay quiet until it resolves"
  /// treatment the home screen and the rank badge give this same fetch.
  Future<StorageInfo?> _loadStorage() async {
    if (WebSession.instance.user == null) return null;
    try {
      return await BillingApiService.instance.getStorageAndCredits();
    } catch (_) {
      return null;
    }
  }

  /// Opens the cloud.fx.land billing page. Routes through `/login` with a
  /// `returnTo` so a browser without an active cloud session lands on billing
  /// after signing in rather than on the dashboard (pinning-webui's Login
  /// honours any `returnTo` that starts with `/`). Uses the user's configured
  /// billing server when they have overridden it in API Configuration.
  Future<void> _openBilling() async {
    final base = await AuthCore.issuerBaseUrl();
    await launchUrl(
      Uri.parse('$base/login?returnTo=%2Fbilling'),
      webOnlyWindowName: '_blank',
    );
  }

  Future<void> _copy(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied'), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/'),
        ),
        title: const Text('Settings'),
      ),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                _accountSection(context),
                const Divider(height: 1),
                _billingSection(context),
                const Divider(height: 1),
                _moreSection(context),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // â”€â”€ Account â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _accountSection(BuildContext context) {
    final user = WebSession.instance.user;
    final isVault = user?.isVault ?? true;
    final identity = user == null
        ? 'Not signed in'
        : isVault
            ? 'Vault ${user.id.length >= 8 ? user.id.substring(0, 8) : user.id}…'
            : user.email;
    final subtitle = user == null
        ? null
        : isVault
            ? 'Passphrase vault'
            : (user.displayName?.isNotEmpty ?? false)
                ? user.displayName
                : 'Signed in';
    return _Section(
      label: 'PROFILE',
      children: [
        ListTile(
          leading: CircleAvatar(
            radius: 22,
            backgroundColor: Theme.of(context).colorScheme.primary,
            backgroundImage: !isVault && user?.photoUrl != null
                ? NetworkImage(user!.photoUrl!)
                : null,
            child: (!isVault && user?.photoUrl != null)
                ? null
                : Icon(
                    isVault ? Icons.person_outline : Icons.person,
                    color: Colors.white,
                    size: 24,
                  ),
          ),
          title: Text(
            identity,
            style: isVault ? const TextStyle(fontFamily: 'monospace') : null,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: subtitle != null ? Text(subtitle) : null,
        ),
        if (user != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.logout, size: 18),
                label: const Text('Sign out'),
                onPressed: () {
                  // Clears the session + (web-specific) resets the API
                  // config to defaults; the router redirects to /signin
                  // via WebSession's notifyListeners.
                  WebSession.instance.signOut();
                },
              ),
            ),
          ),
      ],
    );
  }

  // Billing -----------------------------------------------------------------
  // Second of the two always-visible sections. There is no in-app billing
  // screen on web, so the row hands off to cloud.fx.land; the subtitle shows
  // live usage when we can get it so the row is worth reading even when the
  // user doesn't click through.
  Widget _billingSection(BuildContext context) {
    return _Section(
      label: 'BILLING',
      children: [
        ListTile(
          leading: const Icon(Icons.account_balance_wallet_outlined),
          title: const Text('Billing & storage'),
          subtitle: _billingSubtitle(),
          trailing: const Icon(Icons.north_east, size: 16),
          onTap: _openBilling,
        ),
      ],
    );
  }

  Widget _billingSubtitle() {
    const fallback = Text('Credits, plan and payment on cloud.fx.land');
    return FutureBuilder<StorageInfo?>(
      future: _storage,
      builder: (context, snap) {
        final info = snap.data;
        // Pending and failed both fall through to the static copy -- no
        // spinner, no error row (see _loadStorage).
        if (info == null) return fallback;
        final credits = info.remainingCredits;
        return Text(
          '${info.formattedCurrentStorage} of ${info.formattedTotalStorage} '
          'used, ${_formatCredits(credits)} credits left',
        );
      },
    );
  }

  /// Credits come back as a double; show whole numbers without a trailing
  /// ".0" and fractional balances to two places.
  String _formatCredits(double credits) {
    if (credits <= 0) return '0';
    return credits == credits.roundToDouble()
        ? credits.toStringAsFixed(0)
        : credits.toStringAsFixed(2);
  }

  // More --------------------------------------------------------------------
  // Everything that isn't profile or billing, collapsed. Each child is one of
  // the original _Section widgets, unchanged -- expanding restores exactly the
  // page people had before.
  Widget _moreSection(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Icons.more_horiz),
      title: const Text('More'),
      subtitle:
          const Text('Share ID, wallet, security, integrations, advanced'),
      // ExpansionTile draws its own top/bottom rules when open, which would
      // double up with the Dividers around it. Suppressing them here rather
      // than via a transparent dividerColor, which would also erase the
      // Dividers between the sections inside.
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      // The nested _Sections bring their own horizontal padding.
      childrenPadding: EdgeInsets.zero,
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        _shareIdSection(context),
        const Divider(height: 1),
        _nftWalletSection(context),
        const Divider(height: 1),
        _securitySection(context),
        const Divider(height: 1),
        _apiConfigSection(context),
        const Divider(height: 1),
        _integrationsSection(context),
        const Divider(height: 1),
        _syncQueueSection(context),
        const Divider(height: 1),
        _otherSection(context),
        const Divider(height: 1),
        _aboutSection(context),
      ],
    );
  }

  // â”€â”€ Your Share ID â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _shareIdSection(BuildContext context) {
    return _Section(
      label: 'YOUR SHARE ID',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Share this ID with someone so they can send you files. It is your '
            'public key â€” safe to share.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        FutureBuilder<String>(
          future: _shareId,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const _LoadingRow(label: 'Generating…');
            }
            if (snap.hasError || snap.data == null) {
              return _ErrorRow(message: 'Could not generate Share ID',
                  detail: snap.error?.toString());
            }
            return _CopyableValueRow(
              value: snap.data!,
              onCopy: () => _copy(snap.data!, 'Share ID'),
            );
          },
        ),
      ],
    );
  }

  // â”€â”€ NFT Wallet â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _nftWalletSection(BuildContext context) {
    return _Section(
      label: 'NFT WALLET',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Internal wallet for app NFTs only. Do NOT send tokens or funds to '
            'this address.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        FutureBuilder<String?>(
          future: _nftAddress,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const _LoadingRow(label: 'Deriving…');
            }
            final addr = snap.data;
            if (snap.hasError || addr == null || addr.isEmpty) {
              return _ErrorRow(message: 'Wallet unavailable',
                  detail: snap.error?.toString());
            }
            return _CopyableValueRow(
              value: addr,
              onCopy: () => _copy(addr, 'Wallet address'),
            );
          },
        ),
      ],
    );
  }

  // â”€â”€ Security â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // The raw master key is NEVER shown just from opening Settings (web's
  // DOM is reachable by extensions/XSS). By default we show a SHA-256
  // fingerprint + "key is set"; the raw key is revealed only after an
  // explicit confirm.
  Widget _securitySection(BuildContext context) {
    return _Section(
      label: 'SECURITY',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Your master encryption key protects your files. Back it up to '
            'recover your account, and reveal it only somewhere private.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        FutureBuilder<String?>(
          future: _encryptionKey,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const _LoadingRow(label: 'Loading…');
            }
            final key = snap.data;
            if (snap.hasError || key == null || key.isEmpty) {
              return _ErrorRow(message: 'Encryption key unavailable',
                  detail: snap.error?.toString());
            }
            if (!_revealKey) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    leading: Icon(Icons.verified_user_outlined,
                        color: Theme.of(context).colorScheme.primary),
                    title: const Text('Encryption key is set'),
                    subtitle: Text(
                      'Fingerprint: ${_fingerprint(key)}',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.visibility_outlined, size: 18),
                        label: const Text('Reveal key'),
                        onPressed: () => _confirmReveal(context),
                      ),
                    ),
                  ),
                ],
              );
            }
            // Revealed only after the confirm dialog.
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      key,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                      maxLines: 2,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () => _copy(key, 'Encryption key'),
                  ),
                  IconButton(
                    tooltip: 'Hide',
                    icon: const Icon(Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _revealKey = false),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  /// Non-reversible identifier for the key (SHA-256 prefix) â€” safe to show
  /// so the user can confirm which key is active without exposing it.
  String _fingerprint(String base64Key) {
    try {
      final digest = sha256.convert(base64Decode(base64Key)).toString();
      final p = digest.substring(0, 16);
      return '${p.substring(0, 4)} ${p.substring(4, 8)} '
          '${p.substring(8, 12)} ${p.substring(12, 16)}';
    } catch (_) {
      return 'â€”';
    }
  }

  Future<void> _confirmReveal(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reveal encryption key?'),
        content: const Text(
            'Your raw encryption key will be shown on screen. Anyone who sees '
            'or captures it can decrypt all your files. Reveal it only somewhere '
            'private â€” not on a shared or screen-shared display.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reveal')),
        ],
      ),
    );
    if (ok == true && mounted) setState(() => _revealKey = true);
  }

  // â”€â”€ API Configuration (opens the dedicated editor) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _apiConfigSection(BuildContext context) {
    return _Section(
      label: 'API CONFIGURATION',
      children: [
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('Endpoints & cold-start'),
          subtitle: const Text(
              'Change the gateway / IPFS / resolver URLs (advanced)'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go('/settings/api'),
        ),
      ],
    );
  }

  // â”€â”€ Integrations (Buffer) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _integrationsSection(BuildContext context) {
    return _Section(
      label: 'INTEGRATIONS',
      children: [
        ListTile(
          leading: const Icon(Icons.send_outlined),
          title: const Text('Buffer'),
          subtitle: const Text(
              'Post generated social content to your channels'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go('/settings/buffer'),
        ),
      ],
    );
  }

  // â”€â”€ Sync queue (manage uploads) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _syncQueueSection(BuildContext context) {
    return _Section(
      label: 'UPLOADS',
      children: [
        ListTile(
          leading: const Icon(Icons.sync),
          title: const Text('Sync queue'),
          subtitle: const Text('Manage in-progress and queued uploads'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go('/sync-queue'),
        ),
      ],
    );
  }

  // â”€â”€ Other (everything else â†’ cloud.fx.land) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _otherSection(BuildContext context) {
    return _Section(
      label: 'OTHER',
      children: [
        ListTile(
          leading: const Icon(Icons.open_in_new),
          title: const Text('Other settings'),
          subtitle: const Text(
              'API keys, pins, referrals and profile on cloud.fx.land'),
          trailing: const Icon(Icons.north_east, size: 16),
          onTap: () => launchUrl(
            Uri.parse('https://cloud.fx.land'),
            webOnlyWindowName: '_blank',
          ),
        ),
      ],
    );
  }

  // â”€â”€ About â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _aboutSection(BuildContext context) {
    return _Section(
      label: 'ABOUT',
      children: [
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('FxFiles'),
          subtitle: Text(kWebAppVersion),
        ),
      ],
    );
  }
}

// â”€â”€ Shared little widgets â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _Section extends StatelessWidget {
  final String label;
  final List<Widget> children;
  const _Section({required this.label, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

class _CopyableValueRow extends StatelessWidget {
  final String value;
  final VoidCallback onCopy;
  const _CopyableValueRow({required this.value, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}

class _LoadingRow extends StatelessWidget {
  final String label;
  const _LoadingRow({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  final String message;
  final String? detail;
  const _ErrorRow({required this.message, this.detail});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Text(
        detail == null ? message : '$message ($detail)',
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}
