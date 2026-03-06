import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/blox_discovery_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/shared/utils/error_messages.dart';

/// Screen for managing blox device pairing (local-first retrieval).
/// Can be launched from Settings or from a deeplink return (fxfiles://autopin-complete).
class BloxPairingScreen extends StatefulWidget {
  /// If provided, these are from the deeplink return after FxBlox completes pairing
  final String? pairingSecret;
  final String? hardwareId;
  final String? bloxPeerId;
  final String? bloxName;

  const BloxPairingScreen({
    super.key,
    this.pairingSecret,
    this.hardwareId,
    this.bloxPeerId,
    this.bloxName,
  });

  @override
  State<BloxPairingScreen> createState() => _BloxPairingScreenState();
}

class _BloxPairingScreenState extends State<BloxPairingScreen> {
  bool _isPaired = false;
  bool _isLoading = true;
  String? _pairedHardwareId;
  String? _pairedBloxName;
  Map<String, dynamic>? _autoPinStatus;
  String? _manualIpOverride;
  bool? _bloxReachable;

  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _loadPairingState();
  }

  @override
  void dispose() {
    BloxDiscoveryService.instance.stopScanning();
    super.dispose();
  }

  Future<void> _loadPairingState() async {
    // Check if we got deeplink params (completing pairing from FxBlox)
    if (widget.pairingSecret != null) {
      await _completePairing();
      return;
    }

    // Load existing pairing state
    final secret = await SecureStorageService.instance.read(SecureStorageKeys.bloxPairingSecret);
    final hwId = await SecureStorageService.instance.read(SecureStorageKeys.bloxHardwareId);
    final name = await SecureStorageService.instance.read(SecureStorageKeys.bloxName);
    final ipOverride = await SecureStorageService.instance.read(SecureStorageKeys.bloxIpOverride);

    final lastKnownIp = await SecureStorageService.instance.read(SecureStorageKeys.bloxLastKnownIp);

    setState(() {
      _isPaired = secret != null && secret.isNotEmpty;
      _pairedHardwareId = hwId;
      _pairedBloxName = name;
      _manualIpOverride = ipOverride;
      _isLoading = false;
    });

    if (_isPaired) {
      // Configure discovery service
      BloxDiscoveryService.instance.setPairedBlox(
        hardwareId: hwId,
        peerId: await SecureStorageService.instance.read(SecureStorageKeys.bloxPeerId),
        pairingSecret: secret,
      );
      if (ipOverride != null) {
        BloxDiscoveryService.instance.setManualIp(ipOverride);
      }
      if (lastKnownIp != null) {
        BloxDiscoveryService.instance.setLastKnownIp(lastKnownIp);
      }
      // Use fast healthz check instead of triggering NSD scan
      await _quickCheckBlox();
      // If quick check failed, auto-trigger NSD scan (fire-and-forget)
      if (_bloxReachable == false) {
        _handleRescan();
      }
    }
  }

  /// Fast health check using stored/manual IP — no NSD scan triggered
  Future<void> _quickCheckBlox() async {
    final reachable = await BloxDiscoveryService.instance.quickHealthCheck();
    if (mounted) {
      setState(() => _bloxReachable = reachable);
    }
    if (reachable) {
      // Save the working IP as last known for next time
      final blox = BloxDiscoveryService.instance.pairedBlox;
      if (blox != null && _manualIpOverride == null) {
        BloxDiscoveryService.instance.setLastKnownIp(blox.ip);
        await SecureStorageService.instance.write(
          SecureStorageKeys.bloxLastKnownIp,
          blox.ip,
        );
      }
      // Initialize local download client if fula is ready
      final secret = BloxDiscoveryService.instance.pairingSecret;
      if (blox != null && secret != null && FulaApiService.instance.isConfigured) {
        await FulaApiService.instance.initializeLocalClient(
          endpoint: blox.s3Url,
          accessToken: secret,
        );
      }
      _fetchAutoPinStatus();
    }
  }

  Future<void> _checkBloxReachable() async {
    final blox = BloxDiscoveryService.instance.pairedBlox;
    if (blox == null) {
      if (mounted) setState(() => _bloxReachable = false);
      return;
    }
    final reachable = await BloxDiscoveryService.instance.checkReachable(blox);
    if (mounted) {
      setState(() => _bloxReachable = reachable);
    }
    if (reachable) {
      // Persist last known IP for startup (same as _quickCheckBlox)
      if (_manualIpOverride == null) {
        BloxDiscoveryService.instance.setLastKnownIp(blox.ip);
        await SecureStorageService.instance.write(
          SecureStorageKeys.bloxLastKnownIp,
          blox.ip,
        );
      }
      // Initialize local download client if fula is ready
      final secret = BloxDiscoveryService.instance.pairingSecret;
      if (secret != null && FulaApiService.instance.isConfigured) {
        await FulaApiService.instance.initializeLocalClient(
          endpoint: blox.s3Url,
          accessToken: secret,
        );
      }
      _fetchAutoPinStatus();
    }
  }

  Future<void> _completePairing() async {
    // Save pairing credentials from deeplink
    await SecureStorageService.instance.write(
      SecureStorageKeys.bloxPairingSecret,
      widget.pairingSecret!,
    );
    if (widget.hardwareId != null) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.bloxHardwareId,
        widget.hardwareId!,
      );
    }
    if (widget.bloxPeerId != null) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.bloxPeerId,
        widget.bloxPeerId!,
      );
    }
    if (widget.bloxName != null) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.bloxName,
        widget.bloxName!,
      );
    }

    // Configure discovery service
    BloxDiscoveryService.instance.setPairedBlox(
      hardwareId: widget.hardwareId,
      peerId: widget.bloxPeerId,
      pairingSecret: widget.pairingSecret,
    );

    setState(() {
      _isPaired = true;
      _pairedHardwareId = widget.hardwareId;
      _pairedBloxName = widget.bloxName;
      _isLoading = false;
      _isScanning = true;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Blox paired successfully')),
      );
    }

    await _rescanAndRefresh();
    // mDNS/NSD may not be ready immediately after returning from another app.
    // Retry once automatically if the first scan didn't find the device.
    if (_bloxReachable != true && mounted) {
      await _rescanAndRefresh();
    }
    if (mounted) setState(() => _isScanning = false);
  }

  Future<void> _handleRescan() async {
    setState(() => _isScanning = true);
    await _rescanAndRefresh();
    if (mounted) setState(() => _isScanning = false);
  }

  Future<void> _rescanAndRefresh() async {
    // Stop and restart to force a fresh NSD scan
    BloxDiscoveryService.instance.stopScanning();
    BloxDiscoveryService.instance.startScanning(
      interval: const Duration(seconds: 30),
    );
    // Wait for the NSD scan to complete (8s scan + buffer)
    await Future.delayed(const Duration(seconds: 10));
    if (mounted) setState(() {});
    await _checkBloxReachable();

    // Persist last known IP from scan for fast reconnect next time
    final blox = BloxDiscoveryService.instance.pairedBlox;
    final lastIp = BloxDiscoveryService.instance.lastKnownIp;
    if (blox != null && lastIp != null) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.bloxLastKnownIp,
        lastIp,
      );
    }
  }

  Future<void> _fetchAutoPinStatus() async {
    final status = await BloxDiscoveryService.instance.getAutoPinStatus();
    if (mounted) {
      setState(() => _autoPinStatus = status);
    }
  }

  Future<void> _initiatePairing() async {
    // Get the JWT token for the pinning service
    final jwtToken = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    final ipfsServer = await SecureStorageService.instance.read(SecureStorageKeys.ipfsServerUrl)
        ?? 'https://api.cloud.fx.land';

    if (jwtToken == null || jwtToken.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please configure your API Key first in Settings')),
        );
      }
      return;
    }

    // Build deeplink URL to FxBlox app
    final token = Uri.encodeComponent(jwtToken);
    final endpoint = Uri.encodeComponent(ipfsServer);
    final returnUrl = Uri.encodeComponent(
      'fxfiles://autopin-complete?secret=\$secret&hardwareId=\$hardwareId&bloxPeerId=\$bloxPeerId&bloxName=\$bloxName',
    );

    final deeplinkUrl = 'fxblox://autopin-pair?token=$token&endpoint=$endpoint&returnUrl=$returnUrl';

    try {
      final uri = Uri.parse(deeplinkUrl);
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('FxBlox app not installed. Please install it from the app store.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.getUserFriendlyMessage(e, context: 'launch FxBlox'))),
        );
      }
    }
  }

  Future<void> _unpair() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpair Blox?'),
        content: const Text(
          'This will remove the pairing with your blox device. '
          'Files will only be downloaded from the cloud.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Unpair')),
        ],
      ),
    );

    if (confirmed != true) return;

    await SecureStorageService.instance.delete(SecureStorageKeys.bloxPairingSecret);
    await SecureStorageService.instance.delete(SecureStorageKeys.bloxHardwareId);
    await SecureStorageService.instance.delete(SecureStorageKeys.bloxPeerId);
    await SecureStorageService.instance.delete(SecureStorageKeys.bloxName);
    await SecureStorageService.instance.delete(SecureStorageKeys.bloxIpOverride);
    await SecureStorageService.instance.delete(SecureStorageKeys.bloxLastKnownIp);

    BloxDiscoveryService.instance.setPairedBlox();
    BloxDiscoveryService.instance.clearManualIp();
    BloxDiscoveryService.instance.setLastKnownIp(null);
    FulaApiService.instance.disposeLocalClient();

    setState(() {
      _isPaired = false;
      _pairedHardwareId = null;
      _pairedBloxName = null;
      _manualIpOverride = null;
      _autoPinStatus = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Devices')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (_isPaired) ...[
                  _buildPairedSection(),
                  if (_autoPinStatus != null) _buildStatusSection(),
                  _buildUnpairSection(),
                ] else
                  _buildUnpairedSection(),
              ],
            ),
    );
  }

  Widget _buildPairedSection() {
    final blox = BloxDiscoveryService.instance.pairedBlox;
    final isManual = _manualIpOverride != null;
    final displayIp = blox?.ip;

    // Three-state status: null = not checked, true = online, false = offline
    final Color statusColor;
    final String statusText;
    final IconData trailingIcon;
    final Color trailingColor;
    if (_bloxReachable == null) {
      statusColor = Colors.amber;
      statusText = 'Not checked';
      trailingIcon = LucideIcons.helpCircle;
      trailingColor = Colors.amber;
    } else if (_bloxReachable!) {
      statusColor = Colors.green;
      statusText = 'Online';
      trailingIcon = LucideIcons.wifi;
      trailingColor = Colors.green;
    } else {
      statusColor = Colors.grey;
      statusText = 'Offline';
      trailingIcon = LucideIcons.wifiOff;
      trailingColor = Colors.grey;
    }

    return _buildSection(
      title: 'Paired Blox',
      children: [
        ListTile(
          leading: Icon(LucideIcons.hardDrive, color: statusColor),
          title: Text(_pairedBloxName ?? 'Blox Device'),
          subtitle: Text(statusText),
          trailing: Icon(trailingIcon, color: trailingColor),
        ),
        ListTile(
          leading: const Icon(LucideIcons.network),
          title: Row(
            children: [
              Text(displayIp ?? 'Not discovered'),
              if (isManual) ...[
                const SizedBox(width: 8),
                Text(
                  '(manual)',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.orange[700],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
          subtitle: const Text('IP Address'),
          trailing: IconButton(
            icon: const Icon(LucideIcons.edit),
            onPressed: _showEditIpDialog,
            tooltip: 'Edit IP',
          ),
        ),
        if (_pairedHardwareId != null)
          ListTile(
            leading: const Icon(LucideIcons.fingerprint),
            title: const Text('Hardware ID'),
            subtitle: Text(
              _pairedHardwareId!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: OutlinedButton.icon(
            onPressed: _isScanning ? null : _handleRescan,
            icon: _isScanning
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(LucideIcons.radar),
            label: Text(_isScanning ? 'Scanning...' : 'Rescan'),
          ),
        ),
      ],
    );
  }

  Future<void> _showEditIpDialog() async {
    final blox = BloxDiscoveryService.instance.pairedBlox;
    final initialIp = _manualIpOverride ?? blox?.ip ?? '';

    // Dialog returns: null = cancelled, '' = reset to auto, otherwise the IP
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        // Controller owned by the dialog's StatefulBuilder so it is disposed
        // together with the dialog widget tree — avoids _dependents.isEmpty.
        return _EditIpDialog(initialIp: initialIp);
      },
    );

    if (!mounted || result == null) return;

    if (result.isEmpty) {
      // Reset to auto
      await SecureStorageService.instance.delete(SecureStorageKeys.bloxIpOverride);
      BloxDiscoveryService.instance.clearManualIp();
      setState(() {
        _manualIpOverride = null;
        _bloxReachable = null;
      });
      await _rescanAndRefresh();
    } else {
      // Save manual IP
      await SecureStorageService.instance.write(SecureStorageKeys.bloxIpOverride, result);
      BloxDiscoveryService.instance.setManualIp(result);
      if (mounted) {
        setState(() {
          _manualIpOverride = result;
          _bloxReachable = null; // reset while probing
        });
      }
      await _checkBloxReachable();
    }
  }

  Widget _buildStatusSection() {
    final status = _autoPinStatus!;
    final totalPinned = status['total_pinned'] ?? 0;
    final totalPending = status['total_pending'] ?? 0;
    final lastSync = status['last_sync_at'] as String?;

    return _buildSection(
      title: 'Auto-Pin Status',
      children: [
        ListTile(
          leading: const Icon(LucideIcons.pin),
          title: const Text('Pinned files'),
          trailing: Text('$totalPinned', style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        ListTile(
          leading: const Icon(LucideIcons.clock),
          title: const Text('Pending'),
          trailing: Text('$totalPending', style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        if (lastSync != null)
          ListTile(
            leading: const Icon(LucideIcons.refreshCw),
            title: const Text('Last sync'),
            subtitle: Text(lastSync),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton.icon(
            onPressed: _fetchAutoPinStatus,
            icon: const Icon(LucideIcons.refreshCw),
            label: const Text('Refresh'),
          ),
        ),
      ],
    );
  }

  Widget _buildUnpairSection() {
    return _buildSection(
      title: 'Manage',
      children: [
        ListTile(
          leading: const Icon(LucideIcons.unlink, color: Colors.red),
          title: const Text('Unpair device', style: TextStyle(color: Colors.red)),
          subtitle: const Text('Remove blox pairing and disable local downloads'),
          onTap: _unpair,
        ),
      ],
    );
  }

  Widget _buildUnpairedSection() {
    return Column(
      children: [
        const SizedBox(height: 48),
        Icon(LucideIcons.hardDrive, size: 64, color: Colors.grey[400]),
        const SizedBox(height: 16),
        Text(
          'No devices paired',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Pair with your Blox to enable local-first file access. '
            'Files will be automatically synced to your device for fast LAN downloads.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ),
        const SizedBox(height: 32),
        FilledButton.icon(
          onPressed: _initiatePairing,
          icon: const Icon(LucideIcons.link),
          label: const Text('Pair Blox'),
        ),
      ],
    );
  }

  Widget _buildSection({
    required String title,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            title,
            style: TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
        ...children,
        const Divider(),
      ],
    );
  }
}

/// Separate StatefulWidget so the TextEditingController lifecycle is tied
/// to the dialog's own State, preventing _dependents.isEmpty assertions.
class _EditIpDialog extends StatefulWidget {
  final String initialIp;
  const _EditIpDialog({required this.initialIp});

  @override
  State<_EditIpDialog> createState() => _EditIpDialogState();
}

class _EditIpDialogState extends State<_EditIpDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialIp);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit IP Address'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Manually setting the IP may cause connection issues if the '
            'address is wrong. Only change this if automatic discovery '
            "isn't finding your device.",
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              labelText: 'IP Address',
              hintText: '192.168.1.100',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            autofocus: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, ''),
          child: const Text('Reset to Auto'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final ip = _controller.text.trim();
            if (ip.isNotEmpty) Navigator.pop(context, ip);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
