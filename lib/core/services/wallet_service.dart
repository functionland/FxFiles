import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:reown_appkit/reown_appkit.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fula_files/core/models/billing/billing_models.dart';
import 'package:fula_files/core/services/auth_service.dart';

/// Global navigator key for wallet service to use a stable context
final GlobalKey<NavigatorState> walletNavigatorKey = GlobalKey<NavigatorState>();

class WalletService {
  static final WalletService instance = WalletService._();
  WalletService._();

  ReownAppKitModal? _appKitModal;
  bool _isInitialized = false;
  bool _isInitializing = false;
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
  /// Uses the global walletNavigatorKey context if available, otherwise falls back to provided context
  Future<void> initialize(BuildContext context) async {
    if (_isInitialized) return;
    if (_isInitializing) return; // Prevent concurrent initialization

    _isInitializing = true;

    try {
      // Prefer using the global navigator context for stability
      final effectiveContext = walletNavigatorKey.currentContext ?? context;
      debugPrint('WalletService: Initializing with context: ${effectiveContext.hashCode}');

      _appKitModal = ReownAppKitModal(
        context: effectiveContext,
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
      debugPrint('WalletService: AppKitModal initialized successfully');

      // Listen for session events
      _appKitModal!.onModalConnect.subscribe(_onModalConnect);
      _appKitModal!.onModalDisconnect.subscribe(_onModalDisconnect);
      _appKitModal!.onModalUpdate.subscribe(_onModalUpdate);

      // Check for existing session
      if (_appKitModal!.isConnected) {
        _updateConnectionState();
        debugPrint('WalletService: Existing session found, address: $_connectedAddress');
      }

      _isInitialized = true;
    } catch (e) {
      debugPrint('WalletService: Failed to initialize: $e');
      throw WalletServiceException('Failed to initialize wallet service: $e');
    } finally {
      _isInitializing = false;
    }
  }

  /// Reinitialize with a new context (useful when the old context becomes invalid)
  Future<void> reinitialize(BuildContext context) async {
    debugPrint('WalletService: Reinitializing...');
    _isInitialized = false;
    _appKitModal = null;
    await initialize(context);
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
      debugPrint('WalletService: Opening modal view...');
      await _appKitModal!.openModalView();
      debugPrint('WalletService: Modal view opened');

      // Wait for connection or timeout
      final completer = Completer<String?>();
      StreamSubscription? subscription;
      Timer? pollTimer;

      subscription = onConnectionChange.listen((event) {
        if (event.type == WalletEventType.connected && event.address != null) {
          debugPrint('WalletService: Connection event received: ${event.address}');
          pollTimer?.cancel();
          subscription?.cancel();
          if (!completer.isCompleted) {
            completer.complete(event.address);
          }
        }
      });

      // Also poll for connection state in case event is missed when returning from wallet app
      pollTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
        // Check if session is now connected (may happen after returning from wallet app)
        if (_appKitModal!.isConnected) {
          _updateConnectionState();
          if (_connectedAddress != null) {
            debugPrint('WalletService: Connection detected via polling: $_connectedAddress');
            timer.cancel();
            subscription?.cancel();
            if (!completer.isCompleted) {
              completer.complete(_connectedAddress);
            }
          }
        }
      });

      // Timeout after 2 minutes
      Future.delayed(const Duration(minutes: 2), () {
        pollTimer?.cancel();
        subscription?.cancel();
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      });

      return await completer.future;
    } on StateError catch (e) {
      // Handle "Bad state: No element" error from widget stack
      debugPrint('WalletService: StateError when opening modal: $e');
      debugPrint('WalletService: Attempting to reinitialize...');

      // Try to reinitialize with the current context
      await reinitialize(context);

      // Retry opening the modal
      try {
        await _appKitModal!.openModalView();

        final completer = Completer<String?>();
        StreamSubscription? subscription;
        Timer? pollTimer;

        subscription = onConnectionChange.listen((event) {
          if (event.type == WalletEventType.connected && event.address != null) {
            debugPrint('WalletService: Connection event received (retry): ${event.address}');
            pollTimer?.cancel();
            subscription?.cancel();
            if (!completer.isCompleted) {
              completer.complete(event.address);
            }
          }
        });

        // Also poll for connection state in case event is missed
        pollTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
          if (_appKitModal!.isConnected) {
            _updateConnectionState();
            if (_connectedAddress != null) {
              debugPrint('WalletService: Connection detected via polling (retry): $_connectedAddress');
              timer.cancel();
              subscription?.cancel();
              if (!completer.isCompleted) {
                completer.complete(_connectedAddress);
              }
            }
          }
        });

        Future.delayed(const Duration(minutes: 2), () {
          pollTimer?.cancel();
          subscription?.cancel();
          if (!completer.isCompleted) {
            completer.complete(null);
          }
        });

        return await completer.future;
      } catch (retryError) {
        debugPrint('WalletService: Retry also failed: $retryError');
        throw WalletServiceException('Failed to open wallet modal: $retryError');
      }
    } catch (e) {
      debugPrint('WalletService: Failed to connect wallet: $e');
      throw WalletServiceException('Failed to connect wallet: $e');
    }
  }

  /// Generate message for wallet linking
  String generateLinkMessage(String address) {
    final email = AuthService.instance.currentUser?.email ?? 'unknown';
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final message = '''Link wallet to Fula Pinning Service
User: $email
Wallet: $address
Timestamp: $timestamp''';
    debugPrint('WalletService: Generated link message:');
    debugPrint('WalletService: Email: $email');
    debugPrint('WalletService: Address: $address');
    debugPrint('WalletService: Message: $message');
    return message;
  }

  /// Sign a message using personal_sign (EIP-191).
  /// Handles stale pending requests by opening the wallet for the user to
  /// approve/reject, then retrying after the app resumes.
  Future<String> signLinkMessage(String message) async {
    _ensureInitialized();
    _ensureConnected();

    try {
      return await _requestPersonalSign(message);
    } catch (e) {
      final errorStr = e.toString();
      // -32002: "Request of type 'personal_sign' already pending" —
      // stale request from a previous failed attempt sitting in MetaMask.
      // Open the wallet so user can approve/reject it, wait for app resume,
      // then retry with a fresh request.
      if (errorStr.contains('-32002') || errorStr.contains('already pending')) {
        debugPrint('WalletService: Stale pending sign request. Opening wallet to clear it...');

        // Open MetaMask so user can handle the stale request
        await tryOpenWallet();

        // Wait for the app to come back to foreground
        await _waitForAppResume();

        // Brief pause for the relay to process the approval/rejection
        await Future.delayed(const Duration(seconds: 1));

        // Retry the sign — stale request should now be cleared
        debugPrint('WalletService: App resumed, retrying sign...');
        try {
          return await _requestPersonalSign(message);
        } catch (retryError) {
          debugPrint('WalletService: Retry sign failed: $retryError');
          throw WalletServiceException(
            'Failed to sign message. Please try again.',
          );
        }
      }
      rethrow;
    }
  }

  /// Waits until the app returns to the foreground (e.g. after switching to a
  /// wallet app). Times out after 5 minutes.
  Future<void> _waitForAppResume() {
    final completer = Completer<void>();
    late final _AppResumeObserver observer;
    observer = _AppResumeObserver(() {
      if (!completer.isCompleted) {
        WidgetsBinding.instance.removeObserver(observer);
        completer.complete();
      }
    });
    WidgetsBinding.instance.addObserver(observer);

    // Safety timeout
    Future.delayed(const Duration(minutes: 5), () {
      if (!completer.isCompleted) {
        WidgetsBinding.instance.removeObserver(observer);
        completer.complete();
      }
    });

    return completer.future;
  }

  /// Low-level personal_sign request. Opens wallet app after sending.
  Future<String> _requestPersonalSign(String message) async {
    final session = _appKitModal!.session;
    if (session == null) {
      throw WalletServiceException('No active session');
    }

    final topic = session.topic ?? '';
    final chainId = _appKitModal!.selectedChain?.chainId ?? 'eip155:8453';

    debugPrint('WalletService: Requesting signature...');
    debugPrint('WalletService: Topic: $topic');
    debugPrint('WalletService: ChainId: $chainId');
    debugPrint('WalletService: Address: $_connectedAddress');

    // Convert message to hex for personal_sign (EIP-191)
    final hexMessage = '0x${message.codeUnits.map((c) => c.toRadixString(16).padLeft(2, '0')).join()}';
    debugPrint('WalletService: Hex message: $hexMessage');

    var completed = false;

    final pendingSign = _appKitModal!.request(
      topic: topic,
      chainId: chainId,
      request: SessionRequestParams(
        method: 'personal_sign',
        params: [
          hexMessage,
          _connectedAddress,
        ],
      ),
    ).timeout(
      const Duration(minutes: 5),
      onTimeout: () => throw WalletServiceException(
        'Wallet did not respond within 5 minutes. Please try again.',
      ),
    );

    // Give the relay a moment to deliver, then open the wallet app
    // so the user sees the signing prompt without manually switching.
    // Skip if the request already completed (e.g. -32002 error).
    unawaited(Future.delayed(const Duration(milliseconds: 500), () async {
      if (completed) return;
      try {
        await tryOpenWallet();
      } catch (_) {}
    }));

    try {
      final signature = await pendingSign;
      completed = true;
      debugPrint('WalletService: Signature received: $signature');
      return signature as String;
    } catch (e) {
      completed = true;
      rethrow;
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

      final pendingTx = _appKitModal!.request(
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
      ).timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw WalletServiceException(
          'Wallet did not respond within 5 minutes. Please try again.',
        ),
      );

      // Give the relay a moment to deliver, then open the wallet app
      unawaited(Future.delayed(const Duration(milliseconds: 500), () async {
        try {
          await tryOpenWallet();
        } catch (_) {}
      }));

      final txHash = await pendingTx;
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

  /// Send a generic contract transaction (approve, mint, claim, etc.)
  Future<String> sendContractTransaction({
    required SupportedChain chain,
    required String contractAddress,
    required String encodedData,
    BigInt? value,
  }) async {
    _ensureInitialized();
    _ensureConnected();

    var txCompleted = false;
    try {
      final session = _appKitModal!.session;
      if (session == null) {
        throw WalletServiceException('No active session');
      }

      final topic = session.topic ?? '';

      debugPrint('WalletService: Sending tx to $contractAddress on chain ${chain.chainId}');

      final valueHex = value != null && value > BigInt.zero
          ? '0x${value.toRadixString(16)}'
          : '0x0';

      final pendingTx = _appKitModal!.request(
        topic: topic,
        chainId: 'eip155:${chain.chainId}',
        request: SessionRequestParams(
          method: 'eth_sendTransaction',
          params: [
            {
              'from': _connectedAddress,
              'to': contractAddress,
              'data': encodedData,
              'value': valueHex,
            },
          ],
        ),
      ).timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw WalletServiceException(
          'Wallet did not respond within 5 minutes. Please try again.',
        ),
      );

      // Give the relay a moment to deliver, then try to open the wallet app
      // so the user sees the confirmation prompt without manually switching.
      // Stop retrying once the tx completes (user already approved/rejected).
      unawaited(Future.delayed(const Duration(milliseconds: 500), () async {
        for (var attempt = 0; attempt < 3 && !txCompleted; attempt++) {
          try {
            final opened = await tryOpenWallet();
            if (opened) return;
            debugPrint('WalletService: tryOpenWallet attempt ${attempt + 1} returned false');
          } catch (e) {
            debugPrint('WalletService: tryOpenWallet attempt ${attempt + 1} error: $e');
          }
          // Wait longer each retry: 1s, 2s
          if (attempt < 2 && !txCompleted) {
            await Future.delayed(Duration(seconds: attempt + 1));
          }
        }
      }));

      final txHash = await pendingTx;
      txCompleted = true;

      debugPrint('WalletService: Tx sent, hash: $txHash');
      return txHash as String;
    } catch (e) {
      txCompleted = true;
      debugPrint('WalletService: sendContractTransaction error: $e');
      throw WalletServiceException('Failed to send contract transaction: $e');
    }
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
      ).timeout(const Duration(seconds: 30));
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

  /// Get the name of the connected wallet (e.g. "MetaMask", "Trust Wallet")
  String? get connectedWalletName {
    return _appKitModal?.session?.peer?.metadata.name;
  }

  /// Try to open the connected wallet app so the user can confirm a pending tx.
  /// Returns true if a redirect was attempted.
  Future<bool> tryOpenWallet() async {
    if (_appKitModal == null) return false;
    final session = _appKitModal!.session;
    if (session == null) return false;

    // Use the peer's native or universal link from session metadata
    final peerRedirect = session.peer?.metadata.redirect;
    final nativeLink = peerRedirect?.native;
    final universalLink = peerRedirect?.universal;

    final topic = session.topic ?? '';

    // On iOS, opening just "metamask://" goes to the home page instead of the
    // pending WalletConnect request. Append the session topic as a query
    // parameter so the wallet picks up the pending request automatically.
    // Android handles this via push/background, but the topic doesn't hurt.
    String? link = nativeLink ?? universalLink;
    if (link != null && link.isNotEmpty && topic.isNotEmpty) {
      // Strip trailing slash for consistent joining
      final base = link.endsWith('/') ? link.substring(0, link.length - 1) : link;
      // Build WC deep link: <scheme>://wc?sessionTopic=<topic>
      // For universal links: <url>/wc?sessionTopic=<topic>
      if (base.contains('://')) {
        final scheme = base.substring(0, base.indexOf('://') + 3);
        final rest = base.substring(base.indexOf('://') + 3);
        if (rest.isEmpty || rest == '/') {
          link = '${scheme}wc?sessionTopic=${Uri.encodeComponent(topic)}';
        } else {
          // Universal link: append /wc path
          link = '$base/wc?sessionTopic=${Uri.encodeComponent(topic)}';
        }
      }
    }

    if (link != null && link.isNotEmpty) {
      try {
        final uri = Uri.parse(link);
        final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
        debugPrint('WalletService: Launched wallet via $link: $launched');
        return launched;
      } catch (e) {
        debugPrint('WalletService: Failed to launch wallet link: $e');
      }
    }

    return false;
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

/// Observer that fires a callback when the app returns to the foreground.
class _AppResumeObserver extends WidgetsBindingObserver {
  final VoidCallback onResume;
  _AppResumeObserver(this.onResume);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      onResume();
    }
  }
}
