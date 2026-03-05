import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/billing_api_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:url_launcher/url_launcher.dart';

class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  // Stream controller for API key received events
  final _apiKeyReceivedController = StreamController<String>.broadcast();
  Stream<String> get onApiKeyReceived => _apiKeyReceivedController.stream;

  // Stream controller for org name received events
  final _orgNameReceivedController = StreamController<String>.broadcast();
  Stream<String> get onOrgNameReceived => _orgNameReceivedController.stream;

  // Stream controller for blox pairing completion (from FxBlox deeplink return)
  final _bloxPairingController = StreamController<Map<String, String?>>.broadcast();
  Stream<Map<String, String?>> get onBloxPairingComplete => _bloxPairingController.stream;

  // Pending pairing params — survives until consumed (handles cold start where
  // no listener is attached when the deep link fires).
  Map<String, String?>? _pendingBloxPairing;
  Map<String, String?>? get pendingBloxPairing => _pendingBloxPairing;

  /// Returns and clears any pending blox pairing params (atomic read-and-clear).
  Map<String, String?>? consumePendingBloxPairing() {
    final params = _pendingBloxPairing;
    _pendingBloxPairing = null;
    return params;
  }

  // Default pinning service URL for get-key endpoint
  static const String _defaultPinningService = 'https://cloud.fx.land';

  Future<void> init() async {
    _appLinks = AppLinks();

    // Handle initial link if app was opened via deep link
    try {
      final initialLink = await _appLinks.getInitialLink();
      if (initialLink != null) {
        debugPrint('DeepLinkService: Initial link received: $initialLink');
        await _handleDeepLink(initialLink);
      }
    } catch (e) {
      debugPrint('DeepLinkService: Error getting initial link: $e');
    }

    // Listen for incoming links while app is running
    _linkSubscription = _appLinks.uriLinkStream.listen(
      (Uri uri) async {
        debugPrint('DeepLinkService: Link received: $uri');
        await _handleDeepLink(uri);
      },
      onError: (error) {
        debugPrint('DeepLinkService: Error listening to links: $error');
      },
    );
  }

  Future<void> _handleDeepLink(Uri uri) async {
    debugPrint('DeepLinkService: Handling deep link: $uri');

    // Check if this is an fxfiles:// scheme
    if (uri.scheme != 'fxfiles') {
      debugPrint('DeepLinkService: Unknown scheme: ${uri.scheme}');
      return;
    }

    // Route by host/path
    final host = uri.host;

    if (host == 'autopin-complete') {
      debugPrint('DeepLinkService: Blox pairing complete deeplink received');
      await _handleAutoPinComplete(uri);
      return;
    }

    // Check for API key in query parameters
    final apiKey = uri.queryParameters['key'];
    if (apiKey != null && apiKey.isNotEmpty) {
      debugPrint('DeepLinkService: API key received');
      await _storeApiKey(apiKey);
    }
  }

  Future<void> _handleAutoPinComplete(Uri uri) async {
    final params = <String, String?>{
      'secret': uri.queryParameters['secret'],
      'hardwareId': uri.queryParameters['hardwareId'],
      'bloxPeerId': uri.queryParameters['bloxPeerId'],
      'bloxName': uri.queryParameters['bloxName'],
    };

    final secret = params['secret'];
    if (secret == null || secret.isEmpty) {
      debugPrint('DeepLinkService: autopin-complete missing secret');
      return;
    }

    // Store pairing credentials
    await SecureStorageService.instance.write(SecureStorageKeys.bloxPairingSecret, secret);
    if (params['hardwareId'] != null) {
      await SecureStorageService.instance.write(SecureStorageKeys.bloxHardwareId, params['hardwareId']!);
    }
    if (params['bloxPeerId'] != null) {
      await SecureStorageService.instance.write(SecureStorageKeys.bloxPeerId, params['bloxPeerId']!);
    }
    if (params['bloxName'] != null) {
      await SecureStorageService.instance.write(SecureStorageKeys.bloxName, params['bloxName']!);
    }

    // Store as pending (consumed by app.dart on next frame / init)
    _pendingBloxPairing = params;

    // Notify listeners
    _bloxPairingController.add(params);

    debugPrint('DeepLinkService: Blox pairing stored successfully');
  }

  Future<void> _storeApiKey(String apiKey) async {
    try {
      // Store the API key with timeout protection — keychain can hang on some iOS versions
      await Future.any([
        _performApiKeySetup(apiKey),
        Future.delayed(const Duration(seconds: 15)),
      ]);

      // Always notify listeners, even if setup partially failed.
      // The key is stored first, so even if reinitialize hangs,
      // the key is persisted for next app launch.
      _apiKeyReceivedController.add(apiKey);

      debugPrint('DeepLinkService: API key stored and configured successfully');
    } catch (e) {
      debugPrint('DeepLinkService: Error storing API key: $e');
      // Still try to notify — the key write may have succeeded
      _apiKeyReceivedController.add(apiKey);
    }
  }

  /// Performs the actual API key setup steps. Called with a timeout wrapper.
  Future<void> _performApiKeySetup(String apiKey) async {
    // Store the API key (critical — do this first)
    await SecureStorageService.instance.write(
      SecureStorageKeys.jwtToken,
      apiKey,
    );

    // Set defaults if not already configured
    final existingGateway = await SecureStorageService.instance.read(
      SecureStorageKeys.apiGatewayUrl,
    );
    if (existingGateway == null || existingGateway.isEmpty) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.apiGatewayUrl,
        'https://s3.cloud.fx.land',
      );
    }

    final existingIpfs = await SecureStorageService.instance.read(
      SecureStorageKeys.ipfsServerUrl,
    );
    if (existingIpfs == null || existingIpfs.isEmpty) {
      await SecureStorageService.instance.write(
        SecureStorageKeys.ipfsServerUrl,
        'https://api.cloud.fx.land',
      );
    }

    // Reinitialize FulaApiService with the new settings
    debugPrint('DeepLinkService: Calling reinitializeFulaClient...');
    await AuthService.instance.reinitializeFulaClient();
    debugPrint('DeepLinkService: FulaApiService.isConfigured = ${FulaApiService.instance.isConfigured}');

    // Fetch organization name from userinfo API (non-blocking, errors ignored)
    _fetchAndStoreOrgName();
  }

  /// Opens the browser to get an API key from the Fula pinning service
  Future<bool> openGetApiKeyPage() async {
    // Get the configured IPFS server or use default
    String baseUrl = _defaultPinningService;
    final configuredIpfs = await SecureStorageService.instance.read(
      SecureStorageKeys.ipfsServerUrl,
    );
    if (configuredIpfs != null && configuredIpfs.isNotEmpty) {
      // Extract base URL from the IPFS server (e.g., https://api.cloud.fx.land -> https://cloud.fx.land)
      try {
        final uri = Uri.parse(configuredIpfs);
        // Remove 'api.' prefix if present to get the base cloud URL
        final host = uri.host.replaceFirst('api.', '');
        baseUrl = '${uri.scheme}://$host';
      } catch (e) {
        debugPrint('DeepLinkService: Error parsing IPFS server URL: $e');
      }
    }

    // Construct the get-key URL with redirect and platform
    final redirectUrl = Uri.encodeComponent('fxfiles://auth-callback');

    // Get the auth provider to pass as platform parameter
    final authProvider = AuthService.instance.currentUser?.provider;
    final platformParam = authProvider != null ? '&platform=${authProvider.name}' : '';

    final getKeyUrl = Uri.parse('$baseUrl/get-key?redirect=$redirectUrl$platformParam');

    debugPrint('DeepLinkService: Opening get-key URL: $getKeyUrl');

    try {
      final launched = await launchUrl(
        getKeyUrl,
        mode: LaunchMode.externalApplication,
      );
      return launched;
    } catch (e) {
      debugPrint('DeepLinkService: Error opening get-key URL: $e');
      return false;
    }
  }

  /// Fetch organization name from userinfo API and store it
  /// This runs in the background and does not block - errors are silently ignored
  Future<void> _fetchAndStoreOrgName() async {
    try {
      debugPrint('DeepLinkService: Fetching user info for org name...');
      final userInfo = await BillingApiService.instance.getUserInfo();

      if (userInfo?.org != null && userInfo!.org!.isNotEmpty) {
        debugPrint('DeepLinkService: Got org name: ${userInfo.org}');
        await LocalStorageService.instance.saveSetting('orgName', userInfo.org);
        _orgNameReceivedController.add(userInfo.org!);
      } else {
        debugPrint('DeepLinkService: No org name in response');
        // Clear any previously stored org name
        await LocalStorageService.instance.saveSetting('orgName', '');
      }
    } catch (e) {
      debugPrint('DeepLinkService: Error fetching org name (ignored): $e');
      // Silently ignore errors - org name is optional
    }
  }

  void dispose() {
    _linkSubscription?.cancel();
    _apiKeyReceivedController.close();
    _orgNameReceivedController.close();
    _bloxPairingController.close();
  }
}
