import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/core/services/blox_pairing_links.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/web/services/web_autopin_return.dart';

/// Web "My Devices" — the dart:io-free counterpart of the native
/// `BloxPairingScreen` (which needs mDNS/NSD and the LAN gateway, neither of
/// which exists in a browser).
///
/// What it does:
///  - shows the paired state from `SecureStorageKeys.blox*`;
///  - when opened with [incoming] params (the FxBlox → FxFiles return, handed
///    off from the web home as go_router `extra`, or from the
///    `/autopin-complete` fallback route's query), VALIDATES them and writes
///    the four keys;
///  - "Pair Blox" opens `https://blox.fx.land/autopin-pair?…` in THIS tab
///    (same-tab hand-off; the page unloads and FxBlox brings the user back);
///  - "Unpair" clears the keys.
///
/// Reached via `/blox-pairing` (Settings → My Devices) and `/autopin-complete`.
class WebBloxPairingScreen extends StatefulWidget {
  const WebBloxPairingScreen({
    super.key,
    this.incoming,
    this.fromReturnUrl = false,
  });

  /// The FxBlox return payload to persist, if any.
  final AutopinCompleteParams? incoming;

  /// True when the route's URL itself carries the params (`/autopin-complete
  /// ?secret=…` fallback). After persisting, the screen navigates to
  /// `/blox-pairing` so the secret leaves the address bar.
  final bool fromReturnUrl;

  @override
  State<WebBloxPairingScreen> createState() => _WebBloxPairingScreenState();
}

class _WebBloxPairingScreenState extends State<WebBloxPairingScreen> {
  bool _loading = true;
  bool _paired = false;
  String? _secret;
  String? _hardwareId;
  String? _peerId;
  String? _name;
  bool _revealSecret = false;
  bool _launching = false;

  /// A one-line status/error shown above the sections (e.g. a rejected
  /// return payload). Null when there is nothing to say.
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final incoming = widget.incoming;
    if (incoming != null) {
      // Drain the pending holder regardless of how we were reached, so a
      // later home mount cannot replay the same hand-off.
      takePendingAutopinReturn();
      final err = incoming.validationError;
      if (err != null) {
        _notice = 'Pairing data from FxBlox was rejected: $err';
      } else {
        await _persist(incoming);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Blox paired successfully')),
        );
        if (widget.fromReturnUrl) {
          // Clean URL: REPLACE (not go/push) so the secret-carrying
          // `/autopin-complete?…` history entry is overwritten — a browser
          // Back must not land on it and re-run this persist. The fresh
          // /blox-pairing screen re-reads storage.
          context.replace('/blox-pairing');
          return;
        }
      }
    }
    await _readStored();
  }

  Future<void> _persist(AutopinCompleteParams p) async {
    final s = SecureStorageService.instance;
    await s.write(SecureStorageKeys.bloxPairingSecret, p.secret);
    // A fresh pairing replaces the whole identity — clear a field the new
    // payload does not carry rather than leaving a stale value behind.
    await _writeOrDelete(s, SecureStorageKeys.bloxHardwareId, p.hardwareId);
    await _writeOrDelete(s, SecureStorageKeys.bloxPeerId, p.bloxPeerId);
    await _writeOrDelete(s, SecureStorageKeys.bloxName, p.bloxName);
  }

  Future<void> _writeOrDelete(
      SecureStorageService s, String key, String? value) async {
    if (value == null || value.isEmpty) {
      await s.delete(key);
    } else {
      await s.write(key, value);
    }
  }

  Future<void> _readStored() async {
    final s = SecureStorageService.instance;
    final secret = await s.read(SecureStorageKeys.bloxPairingSecret);
    final hw = await s.read(SecureStorageKeys.bloxHardwareId);
    final peer = await s.read(SecureStorageKeys.bloxPeerId);
    final name = await s.read(SecureStorageKeys.bloxName);
    if (!mounted) return;
    setState(() {
      _secret = secret;
      _paired = secret != null && secret.isNotEmpty;
      _hardwareId = hw;
      _peerId = peer;
      _name = name;
      _revealSecret = false;
      _loading = false;
    });
  }

  /// Open the web FxBlox pairing page in THIS tab. FxBlox calls the Blox's
  /// AutoPinPair with our cloud JWT and brings us back through
  /// files.fx.land/autopin-complete (the fragment return template).
  Future<void> _pair() async {
    if (_launching) return;
    setState(() => _launching = true);
    try {
      final jwt = await SecureStorageService.instance
          .read(SecureStorageKeys.jwtToken);
      final endpoint = await SecureStorageService.instance
              .read(SecureStorageKeys.ipfsServerUrl) ??
          kDefaultPinningEndpoint;
      if (jwt == null || jwt.isEmpty) {
        _snack('Sign in first — your cloud API key is needed to pair a Blox.');
        return;
      }
      final url = buildBloxWebPairUrl(
        token: jwt,
        endpoint: endpoint.isEmpty ? kDefaultPinningEndpoint : endpoint,
      );
      final ok = await launchUrl(url, webOnlyWindowName: '_self');
      if (!ok) _snack('Could not open blox.fx.land.');
    } catch (e) {
      _snack('Could not start pairing: $e');
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  Future<void> _unpair() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpair Blox?'),
        content: const Text(
          'This removes the pairing credentials stored in this browser. '
          'Your Blox keeps auto-pinning until you remove FxFiles from its '
          'Auto-Pin Pairing list in FxBlox.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Unpair')),
        ],
      ),
    );
    if (confirmed != true) return;
    final s = SecureStorageService.instance;
    for (final k in const [
      SecureStorageKeys.bloxPairingSecret,
      SecureStorageKeys.bloxHardwareId,
      SecureStorageKeys.bloxPeerId,
      SecureStorageKeys.bloxName,
      SecureStorageKeys.bloxIpOverride,
      SecureStorageKeys.bloxLastKnownIp,
    ]) {
      await s.delete(k);
    }
    await _readStored();
  }

  Future<void> _confirmReveal() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reveal pairing secret?'),
        content: const Text(
          'The pairing secret lets an app read files from your Blox over your '
          'local network. Reveal it only somewhere private — for example to '
          'paste it into FxFiles desktop → My Devices → Pair → "Pairing Secret".',
        ),
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
    if (ok == true && mounted) setState(() => _revealSecret = true);
  }

  Future<void> _copy(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    _snack('$label copied');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
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
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        title: const Text('My Devices'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      if (_notice != null) _noticeBanner(context),
                      if (_paired) ...[
                        _pairedSection(context),
                        const Divider(height: 1),
                        _manageSection(context),
                      ] else
                        _unpairedSection(context),
                      const Divider(height: 1),
                      _limitationSection(context),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _noticeBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.alertTriangle, color: scheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(_notice!,
                  style: TextStyle(color: scheme.onErrorContainer)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Paired ───────────────────────────────────────────────────────────
  Widget _pairedSection(BuildContext context) {
    final mono = const TextStyle(fontFamily: 'monospace', fontSize: 12);
    return _Section(
      label: 'PAIRED BLOX',
      children: [
        ListTile(
          leading: Icon(LucideIcons.hardDrive,
              color: Theme.of(context).colorScheme.primary),
          title: Text(_name ?? 'Blox Device'),
          subtitle: const Text('Paired — auto-pinning your cloud files'),
          trailing: const Icon(LucideIcons.checkCircle2, color: Colors.green),
        ),
        if (_hardwareId != null)
          ListTile(
            leading: const Icon(LucideIcons.fingerprint),
            title: const Text('Hardware ID'),
            subtitle: SelectableText(_hardwareId!, style: mono),
          ),
        if (_peerId != null)
          ListTile(
            leading: const Icon(LucideIcons.radio),
            title: const Text('Peer ID'),
            subtitle: SelectableText(_peerId!, style: mono),
          ),
        ListTile(
          leading: const Icon(LucideIcons.key),
          title: const Text('Pairing secret'),
          subtitle: _revealSecret
              ? SelectableText(_secret ?? '', style: mono, maxLines: 2)
              : const Text('Hidden — reveal to copy into FxFiles desktop'),
          trailing: _revealSecret
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () => _copy(_secret ?? '', 'Pairing secret'),
                    ),
                    IconButton(
                      tooltip: 'Hide',
                      icon: const Icon(Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _revealSecret = false),
                    ),
                  ],
                )
              : IconButton(
                  tooltip: 'Reveal',
                  icon: const Icon(Icons.visibility_outlined),
                  onPressed: _confirmReveal,
                ),
        ),
      ],
    );
  }

  Widget _manageSection(BuildContext context) {
    return _Section(
      label: 'MANAGE',
      children: [
        ListTile(
          leading: const Icon(LucideIcons.refreshCw),
          title: const Text('Pair again'),
          subtitle: const Text('Re-run pairing on blox.fx.land (new secret)'),
          trailing: _launching
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.north_east, size: 16),
          onTap: _launching ? null : _pair,
        ),
        ListTile(
          leading: const Icon(LucideIcons.unlink, color: Colors.red),
          title: const Text('Unpair device',
              style: TextStyle(color: Colors.red)),
          subtitle: const Text('Remove the pairing stored in this browser'),
          onTap: _unpair,
        ),
      ],
    );
  }

  // ── Not paired ───────────────────────────────────────────────────────
  Widget _unpairedSection(BuildContext context) {
    return _Section(
      label: 'MY DEVICES',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.hardDrive,
                      size: 32, color: Colors.grey[500]),
                  const SizedBox(width: 12),
                  Text('No Blox paired',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Pair your Blox so it automatically pins (keeps a local copy '
                'of) the files you upload to the cloud. Pairing opens '
                'blox.fx.land in this tab; when it finishes you are brought '
                'back here.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _launching ? null : _pair,
                  icon: _launching
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(LucideIcons.link, size: 18),
                  label: const Text('Pair Blox'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Limitation (documented in README + docs/AUTOPIN-HANDOFF.md) ──────
  Widget _limitationSection(BuildContext context) {
    return _Section(
      label: 'GOOD TO KNOW',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'The web app cannot talk to your Blox over your local network '
            '(browsers block http://<lan-ip> from an https page and have no '
            'mDNS discovery), so files here always come from the cloud. '
            'Pairing still makes the Blox auto-pin your files. The pairing '
            'credentials are stored only in this browser; to get fast LAN '
            'downloads, pair in FxFiles on your phone or desktop too (desktop '
            'accepts the pairing secret above).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

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
