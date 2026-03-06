import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:nsd/nsd.dart';

/// Represents a discovered blox device on the local network
class BloxDevice {
  final String ip;
  final int port;
  final String? peerId;
  final String? hardwareId;
  final int gatewayPort;
  final int autoPinPort;
  final int s3Port;
  final String? name;

  BloxDevice({
    required this.ip,
    required this.port,
    this.peerId,
    this.hardwareId,
    this.gatewayPort = 8080,
    this.autoPinPort = 3501,
    this.s3Port = 9000,
    this.name,
  });

  String get gatewayUrl => 'http://$ip:$gatewayPort';
  String get autoPinUrl => 'http://$ip:$autoPinPort';
  String get s3Url => 'http://$ip:$s3Port';

  @override
  String toString() => 'BloxDevice($ip, peerId=$peerId, hwId=$hardwareId)';
}

/// Service for discovering blox devices on the local network via mDNS/NSD
/// and providing local-first content retrieval.
class BloxDiscoveryService {
  static final BloxDiscoveryService instance = BloxDiscoveryService._();
  BloxDiscoveryService._();

  final _devicesController = StreamController<List<BloxDevice>>.broadcast();
  final List<BloxDevice> _devices = [];
  Discovery? _discovery;
  Timer? _scanTimer;
  bool _isScanning = false;

  // Paired blox info (stored in secure storage)
  String? _pairedBloxHardwareId;
  String? _pairedBloxPeerId;
  String? _pairingSecret;

  // Manual IP override (when mDNS discovery fails)
  String? _manualIpOverride;

  // Last known IP from a previous NSD scan (persisted across sessions)
  String? _lastKnownIp;

  Stream<List<BloxDevice>> get devicesStream => _devicesController.stream;
  List<BloxDevice> get devices => List.unmodifiable(_devices);
  bool get isScanning => _isScanning;
  String? get pairingSecret => _pairingSecret;
  bool get hasManualIp => _manualIpOverride != null;
  String? get manualIp => _manualIpOverride;
  String? get lastKnownIp => _lastKnownIp;

  /// Set a manual IP override (bypasses mDNS discovery)
  void setManualIp(String? ip) {
    _manualIpOverride = ip;
  }

  /// Clear the manual IP override and re-enable discovery
  void clearManualIp() {
    _manualIpOverride = null;
  }

  /// Set the last known IP from a previous NSD scan or loaded from storage
  void setLastKnownIp(String? ip) {
    _lastKnownIp = ip;
  }

  /// The paired blox device, if found on the network (or manual override)
  BloxDevice? get pairedBlox {
    if (_pairedBloxHardwareId == null && _pairedBloxPeerId == null) {
      return null;
    }

    // Manual IP override takes priority over discovery
    if (_manualIpOverride != null) {
      return BloxDevice(
        ip: _manualIpOverride!,
        port: 40001,
        peerId: _pairedBloxPeerId,
        hardwareId: _pairedBloxHardwareId,
      );
    }

    try {
      return _devices.firstWhere(
        (d) =>
            (_pairedBloxHardwareId != null && d.hardwareId == _pairedBloxHardwareId) ||
            (_pairedBloxPeerId != null && d.peerId == _pairedBloxPeerId),
      );
    } catch (_) {
      // Fall back to last known IP from a previous scan
      if (_lastKnownIp != null) {
        return BloxDevice(
          ip: _lastKnownIp!,
          port: 40001,
          peerId: _pairedBloxPeerId,
          hardwareId: _pairedBloxHardwareId,
        );
      }
      return null;
    }
  }

  /// Configure the paired blox identity
  void setPairedBlox({
    String? hardwareId,
    String? peerId,
    String? pairingSecret,
  }) {
    _pairedBloxHardwareId = hardwareId;
    _pairedBloxPeerId = peerId;
    _pairingSecret = pairingSecret;
  }

  /// Start periodic mDNS scanning for blox devices
  /// On desktop platforms, NSD may not be available — use manual IP entry instead.
  void startScanning({Duration interval = const Duration(seconds: 30)}) {
    if (_isScanning) return;

    // NSD/mDNS scanning is supported on Android, iOS, macOS, and Windows — not Linux
    if (Platform.isLinux) {
      debugPrint('BloxDiscovery: NSD scanning not supported on Linux, use manual IP');
      return;
    }

    _isScanning = true;

    // Initial scan
    _performScan();

    // Periodic scans
    _scanTimer = Timer.periodic(interval, (_) => _performScan());
  }

  /// Stop scanning
  void stopScanning() {
    _isScanning = false;
    _scanTimer?.cancel();
    _scanTimer = null;
    _stopNsdDiscovery();
  }

  Future<void> _stopNsdDiscovery() async {
    if (_discovery != null) {
      try {
        await stopDiscovery(_discovery!);
      } catch (e) {
        debugPrint('BloxDiscovery: error stopping discovery: $e');
      }
      _discovery = null;
    }
  }

  /// Perform a single NSD scan for _fulatower._tcp services
  Future<void> _performScan() async {
    debugPrint('BloxDiscovery: starting NSD scan for _fulatower._tcp');

    // Stop any previous discovery
    await _stopNsdDiscovery();

    try {
      final discovery = await startDiscovery('_fulatower._tcp',
        autoResolve: true,
        ipLookupType: IpLookupType.v4,
      );
      _discovery = discovery;

      final newDevices = <BloxDevice>[];

      discovery.addServiceListener((service, status) {
        debugPrint('BloxDiscovery: service ${status.name}: ${service.name} at ${service.host}:${service.port}');

        if (status == ServiceStatus.found) {
          final device = _serviceToBloxDevice(service);
          if (device != null) {
            debugPrint('BloxDiscovery: found blox device: $device');
            newDevices.add(device);
            // Update immediately when found
            _devices.clear();
            _devices.addAll(newDevices);
            _devicesController.add(List.unmodifiable(_devices));
          }
        }
      });

      // Let discovery run for a few seconds, then stop
      await Future.delayed(const Duration(seconds: 8));
      await _stopNsdDiscovery();

      // Final update
      _devices.clear();
      _devices.addAll(newDevices);
      _devicesController.add(List.unmodifiable(_devices));

      // Save last known IP of the paired device for fast reconnect
      final paired = pairedBlox;
      if (paired != null && _manualIpOverride == null) {
        _lastKnownIp = paired.ip;
      }

      debugPrint('BloxDiscovery: scan complete, found ${_devices.length} devices');
    } catch (e) {
      debugPrint('BloxDiscovery: scan error: $e');
    }
  }

  /// Convert an NSD Service to a BloxDevice
  BloxDevice? _serviceToBloxDevice(Service service) {
    final host = service.host;
    final port = service.port;

    if (host == null || port == null) {
      debugPrint('BloxDiscovery: service missing host/port');
      return null;
    }

    // Extract TXT record fields
    final txt = service.txt;
    String? peerId;
    String? hardwareId;
    int gatewayPort = 8080;
    int autoPinPort = 3501;
    int s3Port = 9000;

    if (txt != null) {
      debugPrint('BloxDiscovery: TXT records: $txt');

      peerId = _txtString(txt, 'bloxPeerIdString');
      hardwareId = _txtString(txt, 'hardwareID');
      gatewayPort = int.tryParse(_txtString(txt, 'gatewayPort') ?? '') ?? 8080;
      autoPinPort = int.tryParse(_txtString(txt, 'autoPinPort') ?? '') ?? 3501;
      s3Port = int.tryParse(_txtString(txt, 's3Port') ?? '') ?? 9000;
    }

    // Only return if this looks like a Fula tower
    if (peerId == null && hardwareId == null) {
      debugPrint('BloxDiscovery: no peerId or hardwareId in TXT records');
      return null;
    }

    // Prefer resolved IP address over hostname
    final addresses = service.addresses;
    final ip = (addresses != null && addresses.isNotEmpty)
        ? addresses.first.address
        : host;

    return BloxDevice(
      ip: ip,
      port: port,
      peerId: peerId,
      hardwareId: hardwareId,
      gatewayPort: gatewayPort,
      autoPinPort: autoPinPort,
      s3Port: s3Port,
      name: service.name,
    );
  }

  /// Extract a string value from NSD TXT record map
  String? _txtString(Map<String, Uint8List?> txt, String key) {
    final value = txt[key];
    if (value == null) return null;
    return utf8.decode(value);
  }

  /// Quick health check using the paired blox (manual IP → last known IP → NSD list).
  /// No NSD scan is triggered. Returns true if the device responds to /healthz.
  Future<bool> quickHealthCheck({Duration timeout = const Duration(seconds: 2)}) async {
    final blox = pairedBlox;
    if (blox == null) return false;
    return checkReachable(blox, timeout: timeout);
  }

  /// Check if a blox device is reachable via the fula-gateway /healthz endpoint
  Future<bool> checkReachable(BloxDevice blox, {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      final url = Uri.parse('${blox.s3Url}/healthz');
      final response = await http.get(url).timeout(timeout);
      return response.statusCode == 200 && response.body == 'ok';
    } catch (_) {
      return false;
    }
  }

  // ===========================================================================
  // Local-first content retrieval
  // ===========================================================================

  /// Try to fetch content from the paired blox's IPFS gateway.
  /// Returns the bytes if successful, null if not available locally.
  Future<Uint8List?> fetchFromBlox(String contentCid, {Duration timeout = const Duration(seconds: 5)}) async {
    final blox = pairedBlox;
    if (blox == null || contentCid.isEmpty) return null;

    try {
      final url = Uri.parse('${blox.gatewayUrl}/ipfs/$contentCid');
      final response = await http.get(url).timeout(timeout);

      if (response.statusCode == 200) {
        return response.bodyBytes;
      }

      if (response.statusCode == 404) {
        // CID not pinned yet — report missing for priority pinning
        _reportMissingCid(blox, contentCid);
      }

      return null;
    } catch (e) {
      debugPrint('BloxDiscoveryService fetchFromBlox error: $e');
      return null;
    }
  }

  /// Report a missing CID to the blox's auto-pin service for priority pinning
  Future<void> _reportMissingCid(BloxDevice blox, String cid) async {
    if (_pairingSecret == null) return;

    try {
      final url = Uri.parse('${blox.autoPinUrl}/api/v1/auto-pin/report-missing');
      await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $_pairingSecret',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'cids': [cid]}),
      ).timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('BloxDiscoveryService reportMissing error: $e');
    }
  }

  /// Get auto-pin status from the paired blox
  Future<Map<String, dynamic>?> getAutoPinStatus() async {
    final blox = pairedBlox;
    if (blox == null || _pairingSecret == null) return null;

    try {
      final url = Uri.parse('${blox.autoPinUrl}/api/v1/auto-pin/status');
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer $_pairingSecret'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('BloxDiscoveryService getStatus error: $e');
      return null;
    }
  }

  /// Clean up resources
  void dispose() {
    stopScanning();
    _devicesController.close();
  }
}
