import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:url_launcher/url_launcher.dart';

class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  // Stream controller for API key received events
  final _apiKeyReceivedController = StreamController<String>.broadcast();
  Stream<String> get onApiKeyReceived => _apiKeyReceivedController.stream;

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

    // Check for API key in query parameters
    final apiKey = uri.queryParameters['key'];
    if (apiKey != null && apiKey.isNotEmpty) {
      debugPrint('DeepLinkService: API key received');
      await _storeApiKey(apiKey);
    }
  }

  Future<void> _storeApiKey(String apiKey) async {
    try {
      // Store the API key
      await SecureStorageService.instance.write(
        SecureStorageKeys.jwtToken,
        apiKey,
      );

      // Also set default API gateway and IPFS server if not already set
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

      // Configure FulaApiService with the new key
      final gateway = await SecureStorageService.instance.read(
        SecureStorageKeys.apiGatewayUrl,
      );
      final ipfs = await SecureStorageService.instance.read(
        SecureStorageKeys.ipfsServerUrl,
      );

      if (gateway != null) {
        FulaApiService.instance.configure(
          endpoint: gateway,
          accessKey: 'JWT:$apiKey',
          secretKey: 'not-used',
          pinningService: ipfs,
          pinningToken: apiKey,
        );
      }

      // Notify listeners that API key was received
      _apiKeyReceivedController.add(apiKey);

      debugPrint('DeepLinkService: API key stored and configured successfully');
    } catch (e) {
      debugPrint('DeepLinkService: Error storing API key: $e');
    }
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

    // Construct the get-key URL with redirect
    final redirectUrl = Uri.encodeComponent('fxfiles://auth-callback');
    final getKeyUrl = Uri.parse('$baseUrl/get-key?redirect=$redirectUrl');

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

  void dispose() {
    _linkSubscription?.cancel();
    _apiKeyReceivedController.close();
  }
}
