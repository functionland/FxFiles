import 'dart:async';
import 'dart:io';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/billing_api_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  // Stream controller for API key received events
  final _apiKeyReceivedController = StreamController<String>.broadcast();
  Stream<String> get onApiKeyReceived => _apiKeyReceivedController.stream;

  // Stream controller for Dump deep-link navigation. Emits the
  // optional item id (or `null` for the bare `/dump` root). The app
  // subscribes and routes via go_router.
  final _dumpDeepLinkController = StreamController<String?>.broadcast();
  Stream<String?> get onDumpDeepLink => _dumpDeepLinkController.stream;

  /// Notify subscribers that an API key has been configured by an
  /// in-app flow (e.g. Mode B/C sign-in writes the JWT directly to
  /// SecureStorage). Mirrors the silent first-time-write path that the
  /// deep-link handler takes for a brand-new JWT — it does NOT go
  /// through the replacement-proposed comparison, since the caller is
  /// the authoritative source of the new token and there is nothing
  /// to compare against.
  ///
  /// Without this hook, home_screen's `_jwtToken` and
  /// setup_unlock_sheet's `_hasJwt` stay stale after Mode B/C sign-in:
  /// the setup sheet would still show "Connect cloud storage" as active
  /// and push the user through a now-redundant browser/get-key dance
  /// that ends with a "switch account?" prompt (because the new JWT
  /// the browser returns differs in `jti` from the in-app one).
  Future<void> notifyApiKeyConfigured(String apiKey) async {
    // The deep-link /get-key flow runs _performApiKeySetup which writes the
    // JWT AND the gateway/IPFS endpoint defaults. The in-app exchange
    // (Mode A OAuth in-app, Mode B/C seed sign-in) writes only the JWT and
    // calls into here — so without seeding the endpoints, _initializeFulaClient
    // bails on the next cold start with "endpoint configured = false" and
    // FulaApiService stays unconfigured even though the user is authenticated.
    // Mirror the deep-link defaults here so all three sign-in paths reach the
    // same persisted state.
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
    _apiKeyReceivedController.add(apiKey);
  }

  // Fires only when an incoming deep link would REPLACE a different, already
  // stored JWT. The UI must confirm via [confirmApiKeyReplace]. First-time
  // login and idempotent re-login write silently without emitting this.
  final _apiKeyReplaceProposedController = StreamController<void>.broadcast();
  Stream<void> get onApiKeyReplaceProposed =>
      _apiKeyReplaceProposedController.stream;

  // Holds a proposed replacement key until the user confirms or rejects it.
  String? _pendingReplacementApiKey;

  // Stream controller for org name received events
  final _orgNameReceivedController = StreamController<String>.broadcast();
  Stream<String> get onOrgNameReceived => _orgNameReceivedController.stream;

  // Stream controller for blox pairing completion (from FxBlox deeplink return)
  final _bloxPairingController = StreamController<Map<String, String?>>.broadcast();
  Stream<Map<String, String?>> get onBloxPairingComplete => _bloxPairingController.stream;

  // Stream controller for NFT claim deep links
  final _nftClaimController = StreamController<Map<String, String?>>.broadcast();
  Stream<Map<String, String?>> get onNftClaimReceived => _nftClaimController.stream;

  // Stream controllers for Windows shell context menu actions
  final _shellUploadController = StreamController<String>.broadcast();
  Stream<String> get onShellUpload => _shellUploadController.stream;

  final _shellShareController = StreamController<String>.broadcast();
  Stream<String> get onShellShare => _shellShareController.stream;

  final _shellCollabController = StreamController<String>.broadcast();
  Stream<String> get onShellCollab => _shellCollabController.stream;

  final _shellAcceptCollabController = StreamController<String>.broadcast();
  Stream<String> get onShellAcceptCollab => _shellAcceptCollabController.stream;

  final _shellAcceptShareController = StreamController<String>.broadcast();
  Stream<String> get onShellAcceptShare => _shellAcceptShareController.stream;

  // Pending pairing params — survives until consumed (handles cold start where
  // no listener is attached when the deep link fires).
  Map<String, String?>? _pendingBloxPairing;
  Map<String, String?>? get pendingBloxPairing => _pendingBloxPairing;

  // Pending NFT claim params
  Map<String, String?>? _pendingNftClaim;
  Map<String, String?>? get pendingNftClaim => _pendingNftClaim;

  // Pending shell action params (for cold start)
  String? _pendingShellUpload;
  String? get pendingShellUpload => _pendingShellUpload;

  String? _pendingShellShare;
  String? get pendingShellShare => _pendingShellShare;

  String? _pendingShellCollab;
  String? get pendingShellCollab => _pendingShellCollab;

  String? _pendingShellAcceptCollab;
  String? get pendingShellAcceptCollab => _pendingShellAcceptCollab;

  String? _pendingShellAcceptShare;
  String? get pendingShellAcceptShare => _pendingShellAcceptShare;

  /// URI from dart_entrypoint_arguments on cold start via shell context menu.
  /// Set by main.dart before init() is called.
  String? _initialShellUri;

  /// Returns and clears any pending blox pairing params (atomic read-and-clear).
  Map<String, String?>? consumePendingBloxPairing() {
    final params = _pendingBloxPairing;
    _pendingBloxPairing = null;
    return params;
  }

  /// Returns and clears any pending NFT claim params (atomic read-and-clear).
  Map<String, String?>? consumePendingNftClaim() {
    final params = _pendingNftClaim;
    _pendingNftClaim = null;
    return params;
  }

  /// Returns and clears any pending shell upload path (atomic read-and-clear).
  String? consumePendingShellUpload() {
    final p = _pendingShellUpload;
    _pendingShellUpload = null;
    return p;
  }

  /// Returns and clears any pending shell share path (atomic read-and-clear).
  String? consumePendingShellShare() {
    final p = _pendingShellShare;
    _pendingShellShare = null;
    return p;
  }

  /// Returns and clears any pending shell collab path (atomic read-and-clear).
  String? consumePendingShellCollab() {
    final p = _pendingShellCollab;
    _pendingShellCollab = null;
    return p;
  }

  /// Returns and clears any pending shell accept-collab path (atomic read-and-clear).
  String? consumePendingShellAcceptCollab() {
    final p = _pendingShellAcceptCollab;
    _pendingShellAcceptCollab = null;
    return p;
  }

  /// Returns and clears any pending shell accept-share path (atomic read-and-clear).
  String? consumePendingShellAcceptShare() {
    final p = _pendingShellAcceptShare;
    _pendingShellAcceptShare = null;
    return p;
  }

  /// Called from main.dart when the app is cold-started via shell context menu.
  /// The URI is processed during init().
  void setInitialShellUri(String uri) {
    _initialShellUri = uri;
  }

  // Default pinning service URL for get-key endpoint
  static const String _defaultPinningService = 'https://cloud.fx.land';

  Future<void> init() async {
    _appLinks = AppLinks();

    // On Windows, register the fxfiles:// URI scheme so the OS knows to launch this app
    if (Platform.isWindows) {
      _registerWindowsUriScheme();
    }

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

    // Handle shell URI passed via dart_entrypoint_arguments (cold start
    // from Windows Explorer context menu). app_links won't pick this up
    // because argc==3 when launched with --shell-upload/--shell-share.
    if (_initialShellUri != null) {
      final uri = Uri.tryParse(_initialShellUri!);
      if (uri != null) {
        debugPrint('DeepLinkService: Processing shell URI: $uri');
        await _handleDeepLink(uri);
      }
      _initialShellUri = null;
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

  /// HTTPS host for universal/app links (must match NftService.claimLinkHost)
  static const String _universalLinkHost = 'files.fx.land';

  Future<void> _handleDeepLink(Uri uri) async {
    debugPrint('DeepLinkService: Handling deep link: $uri');

    // Handle HTTPS universal/app links from our domain
    if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host == _universalLinkHost) {
      _handleUniversalLink(uri);
      return;
    }

    // Handle fxfiles:// custom scheme
    if (uri.scheme != 'fxfiles') {
      debugPrint('DeepLinkService: Unknown scheme: ${uri.scheme}');
      return;
    }

    // Route by host/path
    final host = uri.host;

    // Ignore bare fxfiles:// returns (e.g. WalletConnect callback from MetaMask)
    if (host.isEmpty || host == 'wc-callback') {
      debugPrint('DeepLinkService: Ignoring wallet return link');
      return;
    }

    if (host == 'autopin-complete') {
      debugPrint('DeepLinkService: Blox pairing complete deeplink received');
      await _handleAutoPinComplete(uri);
      return;
    }

    if (host == 'nft-claim') {
      debugPrint('DeepLinkService: NFT claim deeplink received');
      _handleNftClaim(uri);
      return;
    }

    if (host == 'shell') {
      debugPrint('DeepLinkService: Shell context menu action received');
      _handleShellCommand(uri);
      return;
    }

    if (host == 'dump') {
      // `fxfiles://dump` → /dump root. `fxfiles://dump/<id>` →
      // /dump/<id>. Notifications posted by DumpNotificationService
      // tap here (Android PendingIntent + iOS UNNotification deep
      // link in Session 4).
      final segments = uri.pathSegments;
      final itemId = segments.isEmpty ? null : segments.first;
      debugPrint('DeepLinkService: Dump deeplink received (id=$itemId)');
      _dumpDeepLinkController.add(itemId);
      return;
    }

    // Extract identity params (included by server when user is signed in)
    final email = uri.queryParameters['email'];
    final name = uri.queryParameters['name'];
    final id = uri.queryParameters['id'];
    final provider = uri.queryParameters['provider'];
    final picture = uri.queryParameters['picture'];

    // If identity included, create/update user session
    if (email != null && email.isNotEmpty && id != null && id.isNotEmpty) {
      debugPrint('DeepLinkService: User identity received ($email)');
      await AuthService.instance.handleBrowserSignIn(
        id: id,
        email: email,
        displayName: name,
        photoUrl: picture,
        provider: provider == 'apple' ? AuthProvider.apple : AuthProvider.google,
      );

    }

    // Check for API key in query parameters
    final apiKey = uri.queryParameters['key'];
    if (apiKey != null && apiKey.isNotEmpty) {
      debugPrint('DeepLinkService: API key received');
      await _storeApiKey(apiKey);
    }
  }

  /// Handle HTTPS universal links from files.fx.land
  void _handleUniversalLink(Uri uri) {
    final path = uri.path;

    if (path == '/nft-claim') {
      debugPrint('DeepLinkService: NFT claim universal link received');
      _handleNftClaim(uri);
      return;
    }

    debugPrint('DeepLinkService: Unknown universal link path: $path');
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
    // First-time login (no stored token) or idempotent re-login (same token)
    // proceeds silently — this is the legitimate cloud.fx.land → redirect
    // flow. Only when we'd overwrite a DIFFERENT existing token do we prompt
    // the user, to block an attacker-supplied JWT from hijacking an active
    // session.
    try {
      final existing = await SecureStorageService.instance
          .read(SecureStorageKeys.jwtToken);
      if (existing != null && existing.isNotEmpty && existing != apiKey) {
        debugPrint(
            'DeepLinkService: incoming API key differs from stored token — awaiting user confirmation');
        _pendingReplacementApiKey = apiKey;
        _apiKeyReplaceProposedController.add(null);
        return;
      }
    } catch (e) {
      debugPrint('DeepLinkService: error reading existing token: $e');
      // Fall through and attempt the write; if SecureStorage is unreadable
      // we have no basis for a "replacement" decision anyway.
    }

    await _writeAndAnnounceApiKey(apiKey);
  }

  /// Confirm the pending replacement-JWT write after the UI has obtained user
  /// approval. Called by the app-level dialog; see app.dart.
  Future<void> confirmApiKeyReplace() async {
    final pending = _pendingReplacementApiKey;
    _pendingReplacementApiKey = null;
    if (pending == null) return;
    await _writeAndAnnounceApiKey(pending);
  }

  /// Reject and drop a pending replacement-JWT proposal.
  void rejectApiKeyReplace() {
    _pendingReplacementApiKey = null;
  }

  Future<void> _writeAndAnnounceApiKey(String apiKey) async {
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

    // Construct the get-key URL with redirect, platform, and mode
    final redirectUrl = Uri.encodeComponent('fxfiles://auth-callback');

    // Get the auth provider to pass as platform parameter — locks the
    // web sign-in UI to the same OAuth provider the user picked in app,
    // so a user who chose Google in FxFiles can't accidentally tap
    // Apple on the web (different identity → different vault).
    final authProvider = AuthService.instance.currentUser?.provider;
    final platformParam = authProvider != null ? '&platform=${authProvider.name}' : '';

    // Same defence-in-depth for the vault mode (A/B/C). Without this,
    // a user who set up Mode B (OAuth+seed) on the app could land on
    // /login on the web and accidentally click the Mode A card,
    // creating a separate Mode A vault under the same OAuth identity.
    // Encoded in SecureStorage as keyDerivationVersion =
    //   '2_mode_B' → Mode B
    //   '2_mode_C' → Mode C
    //   anything else / null → Mode A (legacy / first-time)
    final kdv = await SecureStorageService.instance
        .read(SecureStorageKeys.keyDerivationVersion);
    final modeTag = _modeTagForKeyDerivationVersion(kdv);
    final modeParam = '&mode=$modeTag';

    final getKeyUrl = Uri.parse(
        '$baseUrl/get-key?redirect=$redirectUrl$platformParam$modeParam');

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

  /// Map the SecureStorage `keyDerivationVersion` value to the
  /// 1-char mode tag the pinning-webui expects on its `?mode=` URL
  /// parameter. See SecureStorageKeys.keyDerivationVersion for the
  /// authoritative list of stored values.
  static String _modeTagForKeyDerivationVersion(String? kdv) {
    if (kdv == '2_mode_B') return 'b';
    if (kdv == '2_mode_C') return 'c';
    // Legacy users (kdv null / 'v1') and explicit Mode A both land here.
    return 'a';
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

  void _handleNftClaim(Uri uri) {
    // Parse secret from URL fragment (never sent to server) with query param fallback
    final fragmentParams = uri.fragment.isNotEmpty
        ? Uri.splitQueryString(uri.fragment)
        : <String, String>{};
    final params = <String, String?>{
      'chain': uri.queryParameters['chain'],
      'contract': uri.queryParameters['contract'],
      'token': uri.queryParameters['token'],
      'hash': fragmentParams['secret'] ?? uri.queryParameters['hash'],
    };

    _pendingNftClaim = params;
    _nftClaimController.add(params);

    debugPrint('DeepLinkService: NFT claim params stored');
  }

  /// Resolve the current user's home/profile directory. Returns null if the
  /// environment lookup fails — callers must treat that as "reject".
  String? _userProfileDir() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final profile = env['USERPROFILE'];
      if (profile != null && profile.isNotEmpty) return profile;
    }
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) return home;
    return null;
  }

  /// Reject any shell-supplied path that escapes the current user's profile
  /// directory. This is the second line of defence against
  /// `fxfiles://shell/upload?path=C:\Windows\...` style exfil requests — even
  /// if the UI layer's confirmation dialog is accidentally bypassed, obvious
  /// exfil targets never reach the handler.
  bool _isShellPathAllowed(String rawPath) {
    try {
      final profile = _userProfileDir();
      if (profile == null) return false;
      final normalizedProfile = p.normalize(p.absolute(profile));
      final normalizedPath = p.normalize(p.absolute(rawPath));
      return normalizedPath == normalizedProfile ||
          p.isWithin(normalizedProfile, normalizedPath);
    } catch (_) {
      return false;
    }
  }

  /// Handle shell context menu deep links (fxfiles://shell/upload?path=... or fxfiles://shell/share?path=...)
  void _handleShellCommand(Uri uri) {
    // Shell context-menu integration is Windows-only: the Explorer registry
    // entries and the MSIX `--shell-*` launcher args in windows/runner/main.cpp
    // are the only legitimate producers of `fxfiles://shell/*`. On
    // iOS/Android the `fxfiles://` scheme is registered without host scoping
    // (Info.plist, AndroidManifest autoVerify), so a third-party app or
    // webpage tap-handler could fire this URI. Reject on non-Windows.
    if (!Platform.isWindows) {
      debugPrint(
          'DeepLinkService: shell command rejected on non-Windows platform');
      return;
    }

    final segments = uri.pathSegments; // e.g. ['upload'] or ['share']
    final path = uri.queryParameters['path'];

    if (path == null || path.isEmpty) {
      debugPrint('DeepLinkService: shell command missing path param');
      return;
    }

    // Path scoping: reject anything outside the user's profile dir.
    // Any UI-layer confirmation dialog is still expected on top of this.
    if (!_isShellPathAllowed(path)) {
      debugPrint(
          'DeepLinkService: shell path rejected (outside user profile)');
      return;
    }

    // Uri.parse already URL-decoded the path query parameter
    if (segments.isNotEmpty && segments.first == 'upload') {
      debugPrint('DeepLinkService: shell upload request received');
      _pendingShellUpload = path;
      _shellUploadController.add(path);
    } else if (segments.isNotEmpty && segments.first == 'share') {
      debugPrint('DeepLinkService: shell share request received');
      _pendingShellShare = path;
      _shellShareController.add(path);
    } else if (segments.isNotEmpty && segments.first == 'collab') {
      debugPrint('DeepLinkService: shell collab request received');
      _pendingShellCollab = path;
      _shellCollabController.add(path);
    } else if (segments.isNotEmpty && segments.first == 'accept-collab') {
      debugPrint('DeepLinkService: shell accept-collab request received');
      _pendingShellAcceptCollab = path;
      _shellAcceptCollabController.add(path);
    } else if (segments.isNotEmpty && segments.first == 'accept-share') {
      debugPrint('DeepLinkService: shell accept-share request received');
      _pendingShellAcceptShare = path;
      _shellAcceptShareController.add(path);
    } else {
      debugPrint('DeepLinkService: unknown shell command: $segments');
    }
  }

  /// Register fxfiles:// URI scheme in the Windows registry for debug/unpackaged builds.
  /// MSIX builds use protocol_activation in pubspec.yaml instead.
  void _registerWindowsUriScheme() {
    try {
      final exePath = Platform.resolvedExecutable;
      final commands = [
        ['reg', 'add', r'HKCU\Software\Classes\fxfiles', '/ve', '/d', 'URL:FxFiles Protocol', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\fxfiles', '/v', 'URL Protocol', '/d', '', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\fxfiles\shell\open\command', '/ve', '/d', '"$exePath" "%1"', '/f'],
      ];
      for (final cmd in commands) {
        Process.run(cmd.first, cmd.sublist(1));
      }
      debugPrint('DeepLinkService: Windows URI scheme registered for $exePath');
    } catch (e) {
      debugPrint('DeepLinkService: Failed to register URI scheme: $e');
    }

    // Also register Explorer context menu entries
    _registerWindowsContextMenu();
  }

  /// Register cascading "FxFiles" context menu with sub-items in the Windows
  /// registry for both files and directories.
  void _registerWindowsContextMenu() {
    try {
      final exePath = Platform.resolvedExecutable;

      // Remove old flat entries from previous versions
      final cleanupKeys = [
        r'HKCU\Software\Classes\*\shell\FxFilesUpload',
        r'HKCU\Software\Classes\*\shell\FxFilesShare',
        r'HKCU\Software\Classes\Directory\shell\FxFilesUpload',
        r'HKCU\Software\Classes\Directory\shell\FxFilesShare',
      ];
      for (final key in cleanupKeys) {
        Process.run('reg', ['delete', key, '/f']);
      }

      // Also remove any stale parent key from previous attempt (without MUIVerb)
      Process.run('reg', ['delete', r'HKCU\Software\Classes\*\shell\FxFiles', '/f']);
      Process.run('reg', ['delete', r'HKCU\Software\Classes\Directory\shell\FxFiles', '/f']);

      final commands = [
        // ── Files (*) ──
        // Parent "FxFiles" cascading menu (MUIVerb + SubCommands required for submenus)
        ['reg', 'add', r'HKCU\Software\Classes\*\shell\FxFiles', '/v', 'MUIVerb', '/d', 'FxFiles', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\*\shell\FxFiles', '/v', 'Icon', '/d', '"$exePath",0', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\*\shell\FxFiles', '/v', 'SubCommands', '/t', 'REG_SZ', '/d', '', '/f'],
        // Sub-item: Upload to Fula Network
        ['reg', 'add', r'HKCU\Software\Classes\*\shell\FxFiles\shell\01Upload', '/ve', '/d', 'Upload to Fula Network', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\*\shell\FxFiles\shell\01Upload', '/v', 'Icon', '/d', '"$exePath",0', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\*\shell\FxFiles\shell\01Upload\command', '/ve', '/d', '"$exePath" --shell-upload "%1"', '/f'],
        // Sub-item: Create Share Link
        ['reg', 'add', r'HKCU\Software\Classes\*\shell\FxFiles\shell\02Share', '/ve', '/d', 'Create Share Link', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\*\shell\FxFiles\shell\02Share', '/v', 'Icon', '/d', '"$exePath",0', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\*\shell\FxFiles\shell\02Share\command', '/ve', '/d', '"$exePath" --shell-share "%1"', '/f'],

        // ── Directories ──
        // Parent "FxFiles" cascading menu
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles', '/v', 'MUIVerb', '/d', 'FxFiles', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles', '/v', 'Icon', '/d', '"$exePath",0', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles', '/v', 'SubCommands', '/t', 'REG_SZ', '/d', '', '/f'],
        // Sub-item: Upload to Fula Network
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\01Upload', '/ve', '/d', 'Upload to Fula Network', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\01Upload', '/v', 'Icon', '/d', '"$exePath",0', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\01Upload\command', '/ve', '/d', '"$exePath" --shell-upload "%V"', '/f'],
        // Sub-item: Create Share Link
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\02Share', '/ve', '/d', 'Create Share Link', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\02Share', '/v', 'Icon', '/d', '"$exePath",0', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\02Share\command', '/ve', '/d', '"$exePath" --shell-share "%V"', '/f'],
        // Sub-item: Add to Collaborate (directories only)
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\03Collab', '/ve', '/d', 'Add to Collaborate', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\03Collab', '/v', 'Icon', '/d', '"$exePath",0', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\03Collab\command', '/ve', '/d', '"$exePath" --shell-collab "%V"', '/f'],
        // Sub-item: Accept Collaboration (directories only)
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\04AcceptCollab', '/ve', '/d', 'Accept collab on this folder', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\04AcceptCollab', '/v', 'Icon', '/d', '"$exePath",0', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\04AcceptCollab\command', '/ve', '/d', '"$exePath" --shell-accept-collab "%V"', '/f'],
        // Sub-item: Accept Share (directories only) — one-way mirror of an
        // accepted share into the chosen folder, paired with the in-app
        // AcceptShareScreen via fxfiles://shell/accept-share.
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\05AcceptShare', '/ve', '/d', 'Accept share on this folder', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\05AcceptShare', '/v', 'Icon', '/d', '"$exePath",0', '/f'],
        ['reg', 'add', r'HKCU\Software\Classes\Directory\shell\FxFiles\shell\05AcceptShare\command', '/ve', '/d', '"$exePath" --shell-accept-share "%V"', '/f'],
      ];
      for (final cmd in commands) {
        Process.run(cmd.first, cmd.sublist(1));
      }
      debugPrint('DeepLinkService: Windows context menu entries registered');
    } catch (e) {
      debugPrint('DeepLinkService: Failed to register context menu: $e');
    }
  }

  void dispose() {
    _linkSubscription?.cancel();
    _apiKeyReceivedController.close();
    _orgNameReceivedController.close();
    _bloxPairingController.close();
    _nftClaimController.close();
    _shellUploadController.close();
    _shellShareController.close();
    _shellCollabController.close();
    _shellAcceptCollabController.close();
    _shellAcceptShareController.close();
  }
}
