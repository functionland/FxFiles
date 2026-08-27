import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/services/blox_pairing_links.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/blox_discovery_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/utils/platform_capabilities.dart';
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
    await _maybePickDiscoveredDevice();
    if (mounted) setState(() => _isScanning = false);
  }

  /// On desktop, if NSD found devices but pairedBlox is null (no hwId/peerId match),
  /// show a picker so the user can select their Blox from the discovered list.
  Future<void> _maybePickDiscoveredDevice() async {
    if (!PlatformCapabilities.isDesktop || !mounted) return;

    final discovery = BloxDiscoveryService.instance;
    // Already matched — nothing to do
    if (discovery.pairedBlox != null) return;

    final devices = discovery.devices;
    if (devices.isEmpty) return;

    // Auto-select if only one device found
    final BloxDevice selected;
    if (devices.length == 1) {
      selected = devices.first;
    } else {
      final picked = await showDialog<BloxDevice>(
        context: context,
        builder: (ctx) => _DevicePickerDialog(devices: devices),
      );
      if (picked == null || !mounted) return;
      selected = picked;
    }

    // Save selected device's identity so pairedBlox matches it
    discovery.setPairedBlox(
      hardwareId: selected.hardwareId,
      peerId: selected.peerId,
      pairingSecret: discovery.pairingSecret,
    );

    if (selected.hardwareId != null) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.bloxHardwareId,
        selected.hardwareId!,
      );
    }
    if (selected.peerId != null) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.bloxPeerId,
        selected.peerId!,
      );
    }
    if (selected.name != null) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.bloxName,
        selected.name!,
      );
    }

    // Persist the discovered IP
    discovery.setLastKnownIp(selected.ip);
    await SecureStorageService.instance.write(
      SecureStorageKeys.bloxLastKnownIp,
      selected.ip,
    );

    if (mounted) {
      setState(() {
        _pairedHardwareId = selected.hardwareId;
        _pairedBloxName = selected.name ?? _pairedBloxName;
      });
    }

    // Now that pairedBlox will resolve, do health check
    await _checkBloxReachable();
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
    if (PlatformCapabilities.isDesktop) {
      await _showManualPairingDialog();
      return;
    }

    // Get the JWT token for the pinning service
    final jwtToken = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    final ipfsServer = await SecureStorageService.instance.read(SecureStorageKeys.ipfsServerUrl)
        ?? kDefaultPinningEndpoint;

    if (jwtToken == null || jwtToken.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please configure your API Key first in Settings')),
        );
      }
      return;
    }

    // Outbound hand-off links (docs/AUTOPIN-HANDOFF.md): the SAME
    // token/endpoint/returnUrl-template params on two carriers — the FxBlox
    // app deep link and the web FxBlox at blox.fx.land. The return template
    // (kAutopinReturnTemplate) is the https FRAGMENT form, so the pairing
    // secret FxBlox hands back never reaches a server; the four
    // `$placeholders` are literal and substituted by FxBlox.
    final webUrl = buildBloxWebPairUrl(token: jwtToken, endpoint: ipfsServer);

    if (kIsWeb) {
      // The web shell has its own dart:io-free screen (web_blox_pairing_screen)
      // so this branch is not reached today; keep the contract explicit: in a
      // browser the web FxBlox is the only target.
      await _openInBrowser(webUrl);
      return;
    }

    // Native: try the FxBlox app first …
    final deeplinkUrl = buildBloxNativePairUrl(token: jwtToken, endpoint: ipfsServer);
    var launched = false;
    try {
      launched = await launchUrl(deeplinkUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      // url_launcher throws (Android: no activity for the scheme) or returns
      // false (iOS: canOpenURL false) when FxBlox is not installed — both mean
      // the same thing here.
      debugPrint('BloxPairing: fxblox:// launch failed: $e');
    }
    if (launched || !mounted) return;

    // … and fall back to pairing in the browser.
    await _offerPairInBrowser(webUrl);
  }

  /// FxBlox app not available → let the user pair through blox.fx.land
  /// instead (replaces the old "app not installed" dead-end snackbar).
  Future<void> _offerPairInBrowser(Uri webUrl) async {
    final choice = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('FxBlox app not found'),
        content: const Text(
          'Install the FxBlox app from the app store, or pair in your browser '
          'at blox.fx.land instead. Your browser brings you back to FxFiles '
          'when pairing is done.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(LucideIcons.globe, size: 18),
            label: const Text('Pair in browser'),
          ),
        ],
      ),
    );
    if (choice == true && mounted) await _openInBrowser(webUrl);
  }

  Future<void> _openInBrowser(Uri webUrl) async {
    try {
      final ok = await launchUrl(
        webUrl,
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_self',
      );
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open blox.fx.land.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.getUserFriendlyMessage(e, context: 'open blox.fx.land'))),
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

  Future<void> _showManualPairingDialog() async {
    final jwtToken = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    final ipfsEndpoint = await SecureStorageService.instance.read(SecureStorageKeys.ipfsServerUrl)
        ?? kDefaultPinningEndpoint;

    if (!mounted) return;

    final result = await showDialog<_ManualPairingResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ManualPairingDialog(
        jwtToken: jwtToken,
        ipfsEndpoint: ipfsEndpoint,
      ),
    );

    if (result == null || !mounted) return;
    await _completeManualPairing(result);
  }

  Future<void> _completeManualPairing(_ManualPairingResult result) async {
    // Save pairing credentials
    await SecureStorageService.instance.write(
      SecureStorageKeys.bloxPairingSecret,
      result.pairingSecret,
    );
    if (result.hardwareId.isNotEmpty) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.bloxHardwareId,
        result.hardwareId,
      );
    }
    if (result.peerId.isNotEmpty) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.bloxPeerId,
        result.peerId,
      );
    }
    final name = result.bloxName.isNotEmpty ? result.bloxName : 'My Blox';
    await SecureStorageService.instance.write(SecureStorageKeys.bloxName, name);

    // Configure discovery service
    BloxDiscoveryService.instance.setPairedBlox(
      hardwareId: result.hardwareId.isNotEmpty ? result.hardwareId : null,
      peerId: result.peerId.isNotEmpty ? result.peerId : null,
      pairingSecret: result.pairingSecret,
    );

    // Handle optional IP address
    if (result.ipAddress.isNotEmpty) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.bloxIpOverride,
        result.ipAddress,
      );
      BloxDiscoveryService.instance.setManualIp(result.ipAddress);
    }

    setState(() {
      _isPaired = true;
      _pairedHardwareId = result.hardwareId.isNotEmpty ? result.hardwareId : null;
      _pairedBloxName = name;
      _manualIpOverride = result.ipAddress.isNotEmpty ? result.ipAddress : null;
      _isLoading = false;
      _isScanning = true;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Blox paired successfully')),
      );
    }

    // Try mDNS discovery (now works on Windows)
    BloxDiscoveryService.instance.stopScanning();
    BloxDiscoveryService.instance.startScanning(
      interval: const Duration(seconds: 30),
    );

    // If IP was provided, do immediate health check without waiting for NSD
    if (result.ipAddress.isNotEmpty) {
      await _quickCheckBlox();
    } else {
      // Wait for NSD scan to complete
      await Future.delayed(const Duration(seconds: 10));
      if (mounted) setState(() {});
      // On desktop, let user pick from discovered devices if no hwId/peerId match
      await _maybePickDiscoveredDevice();
      await _checkBloxReachable();
    }

    if (mounted) setState(() => _isScanning = false);
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

class _ManualPairingResult {
  final String pairingSecret;
  final String ipAddress;
  final String bloxName;
  final String hardwareId;
  final String peerId;

  const _ManualPairingResult({
    required this.pairingSecret,
    required this.ipAddress,
    required this.bloxName,
    required this.hardwareId,
    required this.peerId,
  });
}

class _ManualPairingDialog extends StatefulWidget {
  final String? jwtToken;
  final String ipfsEndpoint;

  const _ManualPairingDialog({
    required this.jwtToken,
    required this.ipfsEndpoint,
  });

  @override
  State<_ManualPairingDialog> createState() => _ManualPairingDialogState();
}

class _ManualPairingDialogState extends State<_ManualPairingDialog> {
  late final TextEditingController _secretController;
  late final TextEditingController _ipController;
  late final TextEditingController _nameController;
  late final TextEditingController _hwIdController;
  late final TextEditingController _peerIdController;

  @override
  void initState() {
    super.initState();
    _secretController = TextEditingController();
    _ipController = TextEditingController();
    _nameController = TextEditingController();
    _hwIdController = TextEditingController();
    _peerIdController = TextEditingController();
  }

  @override
  void dispose() {
    _secretController.dispose();
    _ipController.dispose();
    _nameController.dispose();
    _hwIdController.dispose();
    _peerIdController.dispose();
    super.dispose();
  }

  String? get _qrData {
    final token = widget.jwtToken;
    if (token == null || token.isEmpty) return null;
    return jsonEncode({
      'api': token,
      'endpoint': widget.ipfsEndpoint,
    });
  }

  void _submit() {
    final secret = _secretController.text.trim();
    if (secret.isEmpty) return;
    Navigator.pop(
      context,
      _ManualPairingResult(
        pairingSecret: secret,
        ipAddress: _ipController.text.trim(),
        bloxName: _nameController.text.trim(),
        hardwareId: _hwIdController.text.trim(),
        peerId: _peerIdController.text.trim(),
      ),
    );
  }

  /// Desktop alternative to the QR + paste flow: open the web FxBlox
  /// (blox.fx.land) with the same hand-off params. When it finishes, the
  /// browser lands on files.fx.land/autopin-complete → "Open in FxFiles"
  /// (`fxfiles://autopin-complete?…`) → DeepLinkService completes the
  /// pairing, so this dialog closes itself once the browser is open.
  Future<void> _pairInBrowser() async {
    final token = widget.jwtToken;
    if (token == null || token.isEmpty) return;
    final url = buildBloxWebPairUrl(token: token, endpoint: widget.ipfsEndpoint);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger?.showSnackBar(
          const SnackBar(content: Text('Could not open blox.fx.land.')),
        );
        return;
      }
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text(ErrorMessages.getUserFriendlyMessage(e, context: 'open blox.fx.land'))),
      );
      return;
    }
    if (!mounted) return;
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Finish pairing in your browser — FxFiles opens automatically when it is done.'),
        duration: Duration(seconds: 6),
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final qrData = _qrData;

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(LucideIcons.link),
                  const SizedBox(width: 12),
                  Text(
                    'Pair Blox Device',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(LucideIcons.x),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth >= 560) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _buildQrSection(qrData)),
                            const SizedBox(width: 24),
                            Expanded(child: _buildFormSection()),
                          ],
                        );
                      }
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildQrSection(qrData),
                          const SizedBox(height: 24),
                          _buildFormSection(),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ListenableBuilder(
                    listenable: _secretController,
                    builder: (context, _) => FilledButton.icon(
                      onPressed: _secretController.text.trim().isEmpty ? null : _submit,
                      icon: const Icon(LucideIcons.check),
                      label: const Text('Pair'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQrSection(String? qrData) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'QR Code',
          style: TextStyle(
            color: AppColors.primary,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 12),
        if (qrData != null) ...[
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: qrData,
                version: QrVersions.auto,
                size: 180,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.alertTriangle, color: Colors.orange[700], size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Configure your API Key in Settings first to enable QR pairing.',
                    style: TextStyle(fontSize: 13, color: Colors.orange[800]),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        Text(
          'Instructions',
          style: TextStyle(
            color: AppColors.primary,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 8),
        _buildStep(1, 'Open FxBlox app on your phone'),
        _buildStep(2, 'Go to Settings > "Auto-Pin Pairing" > Add new app'),
        _buildStep(3, 'Tap "Scan QR Code" and scan this code'),
        _buildStep(4, 'Tap "Get Secret"'),
        _buildStep(5, 'Copy the shown secret (it is only shown once) and paste it in the "Pairing Secret" field'),
        const SizedBox(height: 16),
        Text(
          'No phone handy?',
          style: TextStyle(
            color: AppColors.primary,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: qrData == null ? null : _pairInBrowser,
          icon: const Icon(LucideIcons.globe, size: 18),
          label: const Text('Pair in browser'),
        ),
        const SizedBox(height: 4),
        Text(
          'Opens blox.fx.land; it brings you back to FxFiles when pairing is done.',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }

  Widget _buildStep(int number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Text(
              '$number',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildFormSection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pairing Details',
          style: TextStyle(
            color: AppColors.primary,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _secretController,
          decoration: const InputDecoration(
            labelText: 'Pairing Secret *',
            hintText: 'Paste the secret from FxBlox',
            border: OutlineInputBorder(),
            prefixIcon: Icon(LucideIcons.key),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ipController,
          decoration: const InputDecoration(
            labelText: 'IP Address (optional)',
            hintText: '192.168.1.100',
            helperText: 'mDNS may discover it automatically',
            border: OutlineInputBorder(),
            prefixIcon: Icon(LucideIcons.network),
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: 'Blox Name (optional)',
            hintText: 'My Blox',
            border: OutlineInputBorder(),
            prefixIcon: Icon(LucideIcons.hardDrive),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _hwIdController,
          decoration: const InputDecoration(
            labelText: 'Hardware ID (optional)',
            hintText: 'For device matching',
            border: OutlineInputBorder(),
            prefixIcon: Icon(LucideIcons.fingerprint),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _peerIdController,
          decoration: const InputDecoration(
            labelText: 'Peer ID (optional)',
            hintText: 'For device matching',
            border: OutlineInputBorder(),
            prefixIcon: Icon(LucideIcons.radio),
          ),
        ),
      ],
    );
  }
}

class _DevicePickerDialog extends StatelessWidget {
  final List<BloxDevice> devices;
  const _DevicePickerDialog({required this.devices});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Blox Device'),
      content: SizedBox(
        width: 400,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: devices.length,
          itemBuilder: (ctx, i) {
            final d = devices[i];
            return ListTile(
              leading: const Icon(LucideIcons.hardDrive),
              title: Text(d.name ?? 'Blox Device'),
              subtitle: Text(d.ip),
              trailing: d.hardwareId != null
                  ? Text(
                      '${d.hardwareId!.substring(0, 8)}...',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    )
                  : null,
              onTap: () => Navigator.pop(ctx, d),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
