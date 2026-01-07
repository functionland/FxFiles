import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:reown_appkit/reown_appkit.dart';
import 'package:fula_files/core/models/billing/billing_models.dart';
import 'package:fula_files/core/services/auth_service.dart';

class WalletService {
  static final WalletService instance = WalletService._();
  WalletService._();

  ReownAppKitModal? _appKitModal;
  bool _isInitialized = false;
  String? _connectedAddress;
  int? _connectedChainId;

  // Reown Cloud Project ID
  static const String _projectId = '2151302de68781eb004384e63169a651';

  bool get isInitialized => _isInitialized;
  bool get isConnected => _connectedAddress != null;
  String? get connectedAddress => _connectedAddress;
  int? get connectedChainId => _connectedChainId;

  // Stream controllers for connection events
  final _connectionController = StreamController<WalletConnectionEvent>.broadcast();
  Stream<WalletConnectionEvent> get onConnectionChange => _connectionController.stream;

  /// Initialize AppKit with project configuration
  Future<void> initialize(BuildContext context) async {
    if (_isInitialized) return;

    try {
      _appKitModal = ReownAppKitModal(
        context: context,
        projectId: _projectId,
        metadata: const PairingMetadata(
          name: 'FxFiles',
          description: 'Decentralized file storage with Fula',
          url: 'https://fx.land',
          icons: ['https://fx.land/icon.png'],
          redirect: Redirect(
            native: 'fxfiles://',
            universal: 'https://fx.land',
          ),
        ),
        optionalNamespaces: {
          'eip155': RequiredNamespace(
            chains: ['eip155:8453', 'eip155:2046399126'],
            methods: [
              'eth_sendTransaction',
              'personal_sign',
              'eth_signTypedData',
            ],
            events: ['chainChanged', 'accountsChanged'],
          ),
        },
      );

      await _appKitModal!.init();

      // Listen for session events
      _appKitModal!.onModalConnect.subscribe(_onModalConnect);
      _appKitModal!.onModalDisconnect.subscribe(_onModalDisconnect);
      _appKitModal!.onModalUpdate.subscribe(_onModalUpdate);

      // Check for existing session
      if (_appKitModal!.isConnected) {
        _updateConnectionState();
      }

      _isInitialized = true;
    } catch (e) {
      throw WalletServiceException('Failed to initialize wallet service: $e');
    }
  }

  void _onModalConnect(ModalConnect? event) {
    _updateConnectionState();
    _connectionController.add(WalletConnectionEvent(
      type: WalletEventType.connected,
      address: _connectedAddress,
      chainId: _connectedChainId,
    ));
  }

  void _onModalDisconnect(ModalDisconnect? event) {
    _connectedAddress = null;
    _connectedChainId = null;
    _connectionController.add(const WalletConnectionEvent(
      type: WalletEventType.disconnected,
    ));
  }

  void _onModalUpdate(ModalConnect? event) {
    _updateConnectionState();
    _connectionController.add(WalletConnectionEvent(
      type: WalletEventType.updated,
      address: _connectedAddress,
      chainId: _connectedChainId,
    ));
  }

  void _updateConnectionState() {
    if (_appKitModal == null) return;

    // Get address from the modal's selected account
    _connectedAddress = _appKitModal!.session?.getAddress('eip155');

    // Get chain ID from selected chain
    final chainId = _appKitModal!.selectedChain?.chainId;
    if (chainId != null) {
      _connectedChainId = int.tryParse(chainId) ?? int.tryParse(chainId.split(':').last);
    }
  }

  /// Connect wallet using AppKit modal
  Future<String?> connectWallet(BuildContext context) async {
    _ensureInitialized();

    try {
      await _appKitModal!.openModalView();

      // Wait for connection or timeout
      final completer = Completer<String?>();
      StreamSubscription? subscription;

      subscription = onConnectionChange.listen((event) {
        if (event.type == WalletEventType.connected && event.address != null) {
          subscription?.cancel();
          if (!completer.isCompleted) {
            completer.complete(event.address);
          }
        }
      });

      // Timeout after 2 minutes
      Future.delayed(const Duration(minutes: 2), () {
        subscription?.cancel();
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      });

      return await completer.future;
    } catch (e) {
      throw WalletServiceException('Failed to connect wallet: $e');
    }
  }

  /// Generate message for wallet linking
  String generateLinkMessage(String address) {
    final email = AuthService.instance.currentUser?.email ?? 'unknown';
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return '''Link wallet to Fula Pinning Service
User: $email
Wallet: $address
Timestamp: $timestamp''';
  }

  /// Sign a message using personal_sign (EIP-191)
  Future<String> signLinkMessage(String message) async {
    _ensureInitialized();
    _ensureConnected();

    try {
      final session = _appKitModal!.session;
      if (session == null) {
        throw WalletServiceException('No active session');
      }

      final topic = session.topic ?? '';
      final chainId = _appKitModal!.selectedChain?.chainId ?? 'eip155:8453';

      final signature = await _appKitModal!.request(
        topic: topic,
        chainId: chainId,
        request: SessionRequestParams(
          method: 'personal_sign',
          params: [
            message,
            _connectedAddress,
          ],
        ),
      );

      return signature as String;
    } catch (e) {
      throw WalletServiceException('Failed to sign message: $e');
    }
  }

  /// Send ERC20 token transfer
  Future<String> sendErc20Transfer({
    required SupportedChain chain,
    required String toAddress,
    required BigInt amount,
  }) async {
    _ensureInitialized();
    _ensureConnected();

    if (chain.vaultAddress == null || chain.vaultAddress!.isEmpty) {
      throw WalletServiceException('Vault address not configured for ${chain.chainName}');
    }

    try {
      final session = _appKitModal!.session;
      if (session == null) {
        throw WalletServiceException('No active session');
      }

      final topic = session.topic ?? '';

      // Encode ERC20 transfer(address,uint256) call
      // Function selector: 0xa9059cbb
      final data = _encodeErc20Transfer(toAddress, amount);

      final txHash = await _appKitModal!.request(
        topic: topic,
        chainId: 'eip155:${chain.chainId}',
        request: SessionRequestParams(
          method: 'eth_sendTransaction',
          params: [
            {
              'from': _connectedAddress,
              'to': chain.tokenAddress,
              'data': data,
              'value': '0x0',
            },
          ],
        ),
      );

      return txHash as String;
    } catch (e) {
      throw WalletServiceException('Failed to send transaction: $e');
    }
  }

  /// Encode ERC20 transfer function call
  String _encodeErc20Transfer(String toAddress, BigInt amount) {
    // transfer(address,uint256) selector
    const selector = 'a9059cbb';

    // Pad address to 32 bytes (remove 0x prefix, pad to 64 chars)
    final addressHex = toAddress.toLowerCase().replaceFirst('0x', '').padLeft(64, '0');

    // Pad amount to 32 bytes
    final amountHex = amount.toRadixString(16).padLeft(64, '0');

    return '0x$selector$addressHex$amountHex';
  }

  /// Switch to a specific chain
  Future<void> switchChain(int chainId) async {
    _ensureInitialized();
    _ensureConnected();

    try {
      final session = _appKitModal!.session;
      if (session == null) {
        throw WalletServiceException('No active session');
      }

      final topic = session.topic ?? '';
      final currentChainId = _appKitModal!.selectedChain?.chainId ?? 'eip155:8453';

      await _appKitModal!.request(
        topic: topic,
        chainId: currentChainId,
        request: SessionRequestParams(
          method: 'wallet_switchEthereumChain',
          params: [
            {'chainId': '0x${chainId.toRadixString(16)}'},
          ],
        ),
      );
      _connectedChainId = chainId;
    } catch (e) {
      // Chain switch failed, might need to add the chain first
      throw WalletServiceException('Failed to switch chain: $e');
    }
  }

  /// Get FULA token balance for the connected wallet
  Future<BigInt> getFulaBalance(SupportedChain chain) async {
    if (_connectedAddress == null) {
      return BigInt.zero;
    }

    return getErc20Balance(
      chain: chain,
      tokenAddress: chain.tokenAddress,
      walletAddress: _connectedAddress!,
    );
  }

  /// Get ERC20 token balance via RPC
  Future<BigInt> getErc20Balance({
    required SupportedChain chain,
    required String tokenAddress,
    required String walletAddress,
  }) async {
    if (chain.rpcUrl == null) {
      debugPrint('WalletService: No RPC URL for chain ${chain.chainName}');
      return BigInt.zero;
    }

    try {
      // balanceOf(address) selector: 0x70a08231
      final data = _encodeBalanceOf(walletAddress);

      final response = await http.post(
        Uri.parse(chain.rpcUrl!),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'method': 'eth_call',
          'params': [
            {
              'to': tokenAddress,
              'data': data,
            },
            'latest',
          ],
          'id': 1,
        }),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final result = json['result'] as String?;

        if (result == null || result == '0x' || result.isEmpty) {
          return BigInt.zero;
        }

        // Parse hex result
        final balance = BigInt.tryParse(result.replaceFirst('0x', ''), radix: 16);
        debugPrint('WalletService: FULA balance for $walletAddress: $balance');
        return balance ?? BigInt.zero;
      } else {
        debugPrint('WalletService: RPC error ${response.statusCode}: ${response.body}');
        return BigInt.zero;
      }
    } catch (e) {
      debugPrint('WalletService: Failed to get balance: $e');
      return BigInt.zero;
    }
  }

  /// Encode balanceOf(address) function call
  String _encodeBalanceOf(String address) {
    // balanceOf(address) selector
    const selector = '70a08231';
    // Pad address to 32 bytes
    final addressHex = address.toLowerCase().replaceFirst('0x', '').padLeft(64, '0');
    return '0x$selector$addressHex';
  }

  /// Disconnect the wallet
  Future<void> disconnect() async {
    if (_appKitModal != null && _appKitModal!.isConnected) {
      try {
        await _appKitModal!.disconnect();
      } catch (e) {
        // Ignore disconnect errors
      }
    }
    _connectedAddress = null;
    _connectedChainId = null;
    _connectionController.add(const WalletConnectionEvent(
      type: WalletEventType.disconnected,
    ));
  }

  void _ensureInitialized() {
    if (!_isInitialized || _appKitModal == null) {
      throw WalletServiceException('Wallet service is not initialized');
    }
  }

  void _ensureConnected() {
    if (!isConnected) {
      throw WalletServiceException('No wallet connected');
    }
  }

  void dispose() {
    _appKitModal?.onModalConnect.unsubscribe(_onModalConnect);
    _appKitModal?.onModalDisconnect.unsubscribe(_onModalDisconnect);
    _appKitModal?.onModalUpdate.unsubscribe(_onModalUpdate);
    _connectionController.close();
  }
}

enum WalletEventType { connected, disconnected, updated }

class WalletConnectionEvent {
  final WalletEventType type;
  final String? address;
  final int? chainId;

  const WalletConnectionEvent({
    required this.type,
    this.address,
    this.chainId,
  });
}

class WalletServiceException implements Exception {
  final String message;
  WalletServiceException(this.message);

  @override
  String toString() => 'WalletServiceException: $message';
}
