import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/app/router.dart';
import 'package:fula_files/app/theme/app_theme.dart';
import 'package:fula_files/core/services/blox_discovery_service.dart';
import 'package:fula_files/core/services/deep_link_service.dart';
import 'package:fula_files/core/services/file_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/sharing_service.dart';
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/collab_folder_sync_service.dart';
import 'package:fula_files/core/services/share_folder_sync_service.dart';
import 'package:fula_files/core/services/folder_watch_service.dart';
import 'package:fula_files/core/services/shelf_service.dart';
import 'package:fula_files/core/services/shelf_storage_service.dart';
import 'package:fula_files/core/services/shelf_ios_bridge.dart';
import 'package:fula_files/core/services/wallet_service.dart' show walletNavigatorKey;
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/features/settings/providers/settings_provider.dart';
import 'package:fula_files/features/onboarding/screens/terms_of_service_screen.dart';
import 'package:fula_files/features/sharing/widgets/create_collaboration_dialog.dart';
import 'package:fula_files/features/sharing/widgets/create_share_dialog.dart';
import 'package:fula_files/shared/widgets/keyboard_shortcuts.dart';
import 'package:fula_files/shared/widgets/mini_player.dart';

class FulaFilesApp extends ConsumerStatefulWidget {
  const FulaFilesApp({super.key});

  @override
  ConsumerState<FulaFilesApp> createState() => _FulaFilesAppState();
}

class _FulaFilesAppState extends ConsumerState<FulaFilesApp>
    with WidgetsBindingObserver {
  // Track if user accepted ToS in this session (before async save completes)
  bool _acceptedThisSession = false;

  StreamSubscription<Map<String, String?>>? _bloxPairingSubscription;
  StreamSubscription<Map<String, String?>>? _nftClaimSubscription;
  StreamSubscription<String?>? _shelfDeepLinkSubscription;
  StreamSubscription<String>? _shellUploadSubscription;
  StreamSubscription<String>? _shellShareSubscription;
  StreamSubscription<String>? _shellCollabSubscription;
  StreamSubscription<String>? _shellAcceptCollabSubscription;
  StreamSubscription<String>? _shellAcceptShareSubscription;
  StreamSubscription<void>? _apiKeyReplaceSubscription;

  // Periodic re-evaluation of active tag shares. Catches tag-membership
  // changes that originated outside this device (other device, future webui).
  Timer? _tagShareSweepTimer;
  static const Duration _tagShareSweepInterval = Duration(minutes: 30);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Listen for blox pairing deep links while app is running (warm return)
    _bloxPairingSubscription =
        DeepLinkService.instance.onBloxPairingComplete.listen(_navigateToBloxPairing);

    // Listen for NFT claim deep links while app is running
    _nftClaimSubscription =
        DeepLinkService.instance.onNftClaimReceived.listen(_navigateToNftClaim);

    // Listen for Shelf deep links — emitted when the user taps a
    // notification posted by `ShelfNotificationService` (Phase 8).
    _shelfDeepLinkSubscription =
        DeepLinkService.instance.onShelfDeepLink.listen(_navigateToShelf);

    // Listen for Windows shell context menu actions
    _shellUploadSubscription =
        DeepLinkService.instance.onShellUpload.listen(_handleShellUpload);
    _shellShareSubscription =
        DeepLinkService.instance.onShellShare.listen(_handleShellShare);
    _shellCollabSubscription =
        DeepLinkService.instance.onShellCollab.listen(_handleShellCollab);
    _shellAcceptCollabSubscription =
        DeepLinkService.instance.onShellAcceptCollab.listen(_handleShellAcceptCollab);
    _shellAcceptShareSubscription =
        DeepLinkService.instance.onShellAcceptShare.listen(_handleShellAcceptShare);

    // Prompt the user whenever an incoming deep link proposes replacing the
    // stored API key with a different one (attacker-driven account hijack).
    _apiKeyReplaceSubscription =
        DeepLinkService.instance.onApiKeyReplaceProposed.listen((_) {
      _promptApiKeyReplace();
    });

    // Check for pending params from cold-start deep links
    // (router not ready during initState, so defer to next frame)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pendingPairing = DeepLinkService.instance.consumePendingBloxPairing();
      if (pendingPairing != null) {
        _navigateToBloxPairing(pendingPairing);
      }

      final pendingNftClaim = DeepLinkService.instance.consumePendingNftClaim();
      if (pendingNftClaim != null) {
        _navigateToNftClaim(pendingNftClaim);
      }

      // Shell context menu actions need the navigator to be fully mounted.
      // On cold start, walletNavigatorKey.currentContext may still be null
      // after the first frame, so retry until it's available.
      _processShellPendingCommands();

      // First-pass refresh of active tag shares so cross-device tag-membership
      // changes are reflected on the recipient side without waiting for the
      // owner to tag/untag a file. refreshAllTagShares is a no-op when there
      // are no active tag shares and tolerates FulaApi-not-configured.
      // ignore: discarded_futures
      SharingService.instance.refreshAllTagShares();
    });

    // Periodic re-sweep. Idempotent and cheap when no tag shares are active.
    _tagShareSweepTimer = Timer.periodic(_tagShareSweepInterval, (_) {
      SharingService.instance.refreshAllTagShares();
    });
  }

  @override
  void dispose() {
    _bloxPairingSubscription?.cancel();
    _nftClaimSubscription?.cancel();
    _shelfDeepLinkSubscription?.cancel();
    _shellUploadSubscription?.cancel();
    _shellShareSubscription?.cancel();
    _shellCollabSubscription?.cancel();
    _shellAcceptCollabSubscription?.cancel();
    _shellAcceptShareSubscription?.cancel();
    _apiKeyReplaceSubscription?.cancel();
    _tagShareSweepTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Navigate to BloxPairingScreen with the pairing params from the deep link.
  void _navigateToBloxPairing(Map<String, String?> params) {
    final queryParts = <String>[];
    params.forEach((key, value) {
      if (value != null && value.isNotEmpty) {
        queryParts.add('$key=${Uri.encodeComponent(value)}');
      }
    });
    final query = queryParts.isNotEmpty ? '?${queryParts.join('&')}' : '';
    ref.read(routerProvider).push('/blox-pairing$query');
  }

  /// Navigate to `/dump` (or `/dump/<id>`) in response to a Shelf deep
  /// link. `itemId` may be null for the bare `fxfiles://dump` URL.
  void _navigateToShelf(String? itemId) {
    final route = itemId == null ? '/shelf' : '/shelf/$itemId';
    ref.read(routerProvider).push(route);
  }

  /// Navigate to NftClaimScreen with the claim params from the deep link.
  void _navigateToNftClaim(Map<String, String?> params) {
    final queryParts = <String>[];
    params.forEach((key, value) {
      if (value != null && value.isNotEmpty) {
        queryParts.add('$key=${Uri.encodeComponent(value)}');
      }
    });
    final query = queryParts.isNotEmpty ? '?${queryParts.join('&')}' : '';
    ref.read(routerProvider).push('/nft-claim$query');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshBloxConnection();
      // Resume any pending uploads that were interrupted by sleep
      SyncService.instance.resumeIfPending();
      // Tell SyncForegroundService (if running) to stop — main isolate
      // takes back ownership of the queue. Awaited cleanup is
      // fire-and-forget; the service-side lock release is the source of
      // truth, not this notification.
      unawaited(SyncService.instance.handleAppForegrounded());
      // Restart file watchers and scan for changes missed while backgrounded
      FolderWatchService.instance.onAppResumed();
      // Restart collab folder watchers (stale after sleep/wake on Windows)
      CollabFolderSyncService.instance.onAppResumed();
      // Re-poll share folder syncs (download-only).
      ShareFolderSyncService.instance.onAppResumed();
      // Shelf (R3 Plan B): drain anything the Android share receiver
      // staged into `dump_pending/` while the main app was backgrounded
      // or not running. Fire-and-forget — its own in-process mutex
      // (R9) deduplicates concurrent calls.
      unawaited(ShelfService.instance.drainPendingDir());
      // iOS Share Extension handoff — the Share Extension stages into
      // the App Group container; the bridge moves payloads into the
      // main app sandbox and feeds them through ingestAndSchedule.
      // Safe to call on every resume; native-side dedupes empty
      // containers cheaply.
      if (Platform.isIOS) {
        unawaited(ShelfIosBridge.instance.drainAppGroupContainer());
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      // App is moving to background. If uploads are still pending, ask
      // MainActivity to bring up SyncForegroundService — that pins the
      // process (foreground service notification) and spawns a fresh
      // FlutterEngine that drains the queue from a separate isolate.
      // Without this, swiping the app away kills the upload and the
      // ongoing notification simultaneously.
      unawaited(SyncService.instance.handleAppBackgrounded());
      // Flush any pending dump-metadata sync immediately rather than
      // waiting for the 2 s debounce to expire. If the OS kills the
      // isolate after this point (Android can do that any time), the
      // Timer would never fire and the just-shared row would not
      // reach the cloud — meaning the next clean reset would lose it.
      unawaited(ShelfStorageService.instance.syncToCloud());
    }
  }

  /// Process pending shell context menu commands, retrying until the navigator
  /// is mounted (cold start may need a few hundred ms for the router to build).
  void _processShellPendingCommands({int attempt = 0}) {
    if (!mounted) return;

    final hasAnyPending =
        DeepLinkService.instance.pendingShellUpload != null ||
        DeepLinkService.instance.pendingShellShare != null ||
        DeepLinkService.instance.pendingShellCollab != null ||
        DeepLinkService.instance.pendingShellAcceptCollab != null ||
        DeepLinkService.instance.pendingShellAcceptShare != null;
    if (!hasAnyPending) return;

    // Wait for the GoRouter navigator to be mounted
    if (walletNavigatorKey.currentContext == null && attempt < 10) {
      Future.delayed(const Duration(milliseconds: 300), () {
        _processShellPendingCommands(attempt: attempt + 1);
      });
      return;
    }

    final pendingUpload = DeepLinkService.instance.consumePendingShellUpload();
    if (pendingUpload != null) _handleShellUpload(pendingUpload);

    final pendingShare = DeepLinkService.instance.consumePendingShellShare();
    if (pendingShare != null) _handleShellShare(pendingShare);

    final pendingCollab = DeepLinkService.instance.consumePendingShellCollab();
    if (pendingCollab != null) _handleShellCollab(pendingCollab);

    final pendingAcceptCollab = DeepLinkService.instance.consumePendingShellAcceptCollab();
    if (pendingAcceptCollab != null) _handleShellAcceptCollab(pendingAcceptCollab);

    final pendingAcceptShare = DeepLinkService.instance.consumePendingShellAcceptShare();
    if (pendingAcceptShare != null) _handleShellAcceptShare(pendingAcceptShare);
  }

  /// Ask the user to confirm a shell-initiated action. Shell deep links can
  /// be fired by any running app or visited website; never act on one
  /// silently.
  Future<bool> _confirmShellAction({
    required String title,
    required String action,
    required String filePath,
  }) async {
    final ctx = walletNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return false;
    final approved = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(action),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color:
                    Theme.of(dialogCtx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                filePath,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Only proceed if you started this action yourself.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(dialogCtx).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return approved ?? false;
  }

  /// Confirmation dialog for when an incoming deep link proposes replacing
  /// the stored API key with a different one.
  Future<void> _promptApiKeyReplace() async {
    final ctx = walletNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) {
      DeepLinkService.instance.rejectApiKeyReplace();
      return;
    }
    final approved = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Switch account?'),
        content: const Text(
          'A deep link is asking FxFiles to switch to a different account '
          'and replace your current API key.\n\n'
          'Only continue if you started this sign-in yourself. Otherwise '
          'your uploads could be sent to an attacker\'s account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Keep current'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    if (approved == true) {
      await DeepLinkService.instance.confirmApiKeyReplace();
    } else {
      DeepLinkService.instance.rejectApiKeyReplace();
    }
  }

  /// Handle file/folder upload triggered from Windows Explorer context menu.
  Future<void> _handleShellUpload(String filePath) async {
    try {
      final entityType = FileSystemEntity.typeSync(filePath);
      if (entityType == FileSystemEntityType.notFound) {
        debugPrint('ShellUpload: file not found');
        _showShellSnackBar('File not found: $filePath', isError: true);
        return;
      }

      final isDirectory = entityType == FileSystemEntityType.directory;
      final confirmed = await _confirmShellAction(
        title: 'Upload to Fula Network?',
        action: isDirectory
            ? 'FxFiles is being asked to upload this folder:'
            : 'FxFiles is being asked to upload this file:',
        filePath: filePath,
      );
      if (!confirmed) return;

      final name = filePath.split(Platform.pathSeparator).last;

      if (isDirectory) {
        final dir = Directory(filePath);
        int fileCount = 0;
        await for (final entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final relativePath = entity.path.substring(filePath.length + 1);
            final remoteKey = '$name/$relativePath'.replaceAll('\\', '/');
            final category = FileCategory.fromPath(entity.path);
            await SyncService.instance.queueUpload(
              localPath: entity.path,
              remoteBucket: category.bucketName,
              remoteKey: remoteKey,
            );
            fileCount++;
          }
        }
        _showShellSnackBar('Queued $fileCount files from "$name" for upload');
      } else {
        final category = FileCategory.fromPath(filePath);
        await SyncService.instance.queueUpload(
          localPath: filePath,
          remoteBucket: category.bucketName,
          remoteKey: name,
        );
        _showShellSnackBar('Queued for upload: $name');
      }
    } catch (e) {
      debugPrint('ShellUpload: error: $e');
      _showShellSnackBar('Upload failed: $e', isError: true);
    }
  }

  /// Handle share link creation triggered from Windows Explorer context menu.
  Future<void> _handleShellShare(String filePath) async {
    try {
      final entityType = FileSystemEntity.typeSync(filePath);
      if (entityType == FileSystemEntityType.notFound) {
        _showShellSnackBar('File not found: $filePath', isError: true);
        return;
      }

      final isDirectory = entityType == FileSystemEntityType.directory;
      final confirmed = await _confirmShellAction(
        title: 'Create share link?',
        action:
            'FxFiles is being asked to create a public share link for:',
        filePath: filePath,
      );
      if (!confirmed) return;

      final ctx = walletNavigatorKey.currentContext;
      if (ctx == null) {
        debugPrint('ShellShare: no navigator context available');
        return;
      }

      final name = filePath.split(Platform.pathSeparator).last;

      // Check if file is synced to cloud (aggregate children for directories)
      bool isSynced;
      if (isDirectory) {
        final children = LocalStorageService.instance.getSyncStatesUnderPath(filePath);
        isSynced = children.isNotEmpty && children.every((s) => s.status == SyncStatus.synced);
      } else {
        final syncState = LocalStorageService.instance.getSyncState(filePath);
        isSynced = syncState != null && syncState.status == SyncStatus.synced;
      }

      if (!isSynced) {
        // Show dialog offering to upload first
        if (!ctx.mounted) return;
        final shouldUpload = await showDialog<bool>(
          context: ctx,
          builder: (dialogCtx) => AlertDialog(
            title: const Text('File Not Uploaded'),
            content: Text(
              '"$name" must be uploaded to Fula Network before creating a share link.\n\n'
              'Would you like to upload it now?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogCtx, true),
                child: const Text('Upload'),
              ),
            ],
          ),
        );
        if (shouldUpload == true) {
          await _handleShellUpload(filePath);
          _showShellSnackBar('Upload "$name" first, then use Create Share Link again');
        }
        return;
      }

      // File is synced — show the public link dialog
      final String bucket;
      final String pathScope;
      if (isDirectory) {
        // Determine bucket from actual uploaded files, not folder name
        final children = LocalStorageService.instance.getSyncStatesUnderPath(filePath);
        final bucketCounts = <String, int>{};
        for (final s in children) {
          if (s.bucket != null && s.bucket!.isNotEmpty) {
            bucketCounts[s.bucket!] = (bucketCounts[s.bucket!] ?? 0) + 1;
          }
        }
        bucket = bucketCounts.isEmpty
            ? FileCategory.other.bucketName
            : bucketCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
        pathScope = '$name/';
      } else {
        final category = FileCategory.fromPath(filePath);
        bucket = category.bucketName;
        pathScope = name;
      }

      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      const mimeTypes = {
        'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
        'gif': 'image/gif', 'webp': 'image/webp', 'mp4': 'video/mp4',
        'mov': 'video/quicktime', 'mp3': 'audio/mpeg', 'pdf': 'application/pdf',
        'txt': 'text/plain', 'json': 'application/json', 'zip': 'application/zip',
      };

      if (!ctx.mounted) return;
      final result = await showCreatePublicLinkDialog(
        context: ctx,
        pathScope: pathScope,
        bucket: bucket,
        fileName: name,
        contentType: mimeTypes[ext],
        localPath: filePath,
      );

      if (result != null && ctx.mounted) {
        showDialog(
          context: ctx,
          builder: (dialogCtx) => AlertDialog(
            title: const Text('Link Created!'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Share this link:'),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(dialogCtx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    result.url,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: const Text('Close'),
              ),
              FilledButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: result.url));
                  Navigator.pop(dialogCtx);
                  _showShellSnackBar('Link copied to clipboard');
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy Link'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      debugPrint('ShellShare: error: $e');
      _showShellSnackBar('Share failed: $e', isError: true);
    }
  }

  /// Handle "Add to Collaborate" triggered from Windows Explorer context menu
  /// for directories. Opens the create collaboration dialog pre-filled with
  /// the folder path and name.
  Future<void> _handleShellCollab(String folderPath) async {
    try {
      final entityType = FileSystemEntity.typeSync(folderPath);
      if (entityType != FileSystemEntityType.directory) {
        _showShellSnackBar('Not a folder: $folderPath', isError: true);
        return;
      }

      final confirmed = await _confirmShellAction(
        title: 'Create collaboration?',
        action: 'FxFiles is being asked to start a collaboration on:',
        filePath: folderPath,
      );
      if (!confirmed) return;

      final ctx = walletNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) {
        debugPrint('ShellCollab: no navigator context available');
        return;
      }

      final folderName = folderPath.split(Platform.pathSeparator).last;

      showCreateCollaborationDialog(
        ctx,
        ref,
        initialFolderPath: folderPath,
        initialName: folderName,
      );
    } catch (e) {
      debugPrint('ShellCollab: error: $e');
      _showShellSnackBar('Collaborate failed: $e', isError: true);
    }
  }

  /// Handle "Accept Collaboration" triggered from Windows Explorer context menu
  /// for directories. Opens the accept collaboration screen with the folder
  /// path pre-filled for sync.
  Future<void> _handleShellAcceptCollab(String folderPath) async {
    try {
      final entityType = FileSystemEntity.typeSync(folderPath);
      if (entityType != FileSystemEntityType.directory) {
        _showShellSnackBar('Not a folder: $folderPath', isError: true);
        return;
      }

      final confirmed = await _confirmShellAction(
        title: 'Accept collaboration?',
        action:
            'FxFiles is being asked to use this folder for an incoming collaboration:',
        filePath: folderPath,
      );
      if (!confirmed) return;

      ref.read(routerProvider).push('/collab/accept-link', extra: folderPath);
    } catch (e) {
      debugPrint('ShellAcceptCollab: error: $e');
      _showShellSnackBar('Accept collaboration failed: $e', isError: true);
    }
  }

  /// Handle "Accept Share" triggered from the Windows Explorer context menu
  /// for directories. Opens the accept-share screen with the folder
  /// pre-selected; the user then pastes the share link and confirms.
  Future<void> _handleShellAcceptShare(String folderPath) async {
    try {
      final entityType = FileSystemEntity.typeSync(folderPath);
      if (entityType != FileSystemEntityType.directory) {
        _showShellSnackBar('Not a folder: $folderPath', isError: true);
        return;
      }

      final confirmed = await _confirmShellAction(
        title: 'Accept share?',
        action:
            'FxFiles is being asked to use this folder as the local mirror for an incoming share:',
        filePath: folderPath,
      );
      if (!confirmed) return;

      ref.read(routerProvider).push('/share/accept-link', extra: folderPath);
    } catch (e) {
      debugPrint('ShellAcceptShare: error: $e');
      _showShellSnackBar('Accept share failed: $e', isError: true);
    }
  }

  /// Show a snackbar using the global navigator context.
  void _showShellSnackBar(String message, {bool isError = false}) {
    final ctx = walletNavigatorKey.currentContext;
    if (ctx != null && ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Colors.red : null,
        ),
      );
    }
  }

  /// Re-check local Blox connectivity when app returns to foreground.
  /// Non-blocking — runs entirely in the background.
  void _refreshBloxConnection() {
    Future(() async {
      try {
        final secret = BloxDiscoveryService.instance.pairingSecret;
        if (secret == null) return; // Not paired
        if (!FulaApiService.instance.isConfigured) return;
        if (BloxDiscoveryService.instance.isScanning) return; // Already scanning (e.g. pairing in progress)

        // Quick health check on current/last-known IP
        if (await BloxDiscoveryService.instance.quickHealthCheck(
          timeout: const Duration(seconds: 3),
        )) {
          // Device reachable — ensure local client is initialized
          if (!FulaApiService.instance.hasLocalClient) {
            final blox = BloxDiscoveryService.instance.pairedBlox;
            if (blox != null) {
              await FulaApiService.instance.initializeLocalClient(
                endpoint: blox.s3Url,
                accessToken: secret,
              );
              debugPrint('BloxDiscovery: local client initialized on app resume');
            }
          }
          return;
        }

        // Saved IP unreachable — dispose stale local client (avoids 3s timeout
        // per download attempt while NSD scan runs) and discover new IP
        debugPrint('BloxDiscovery: IP unreachable on resume, running NSD scan');
        FulaApiService.instance.disposeLocalClient();

        BloxDiscoveryService.instance.stopScanning();
        BloxDiscoveryService.instance.startScanning(
          interval: const Duration(seconds: 30),
        );
        await Future.delayed(const Duration(seconds: 10));
        BloxDiscoveryService.instance.stopScanning();

        // Skip if already initialized (e.g. user visited My Devices meanwhile)
        if (FulaApiService.instance.hasLocalClient) return;

        final blox = BloxDiscoveryService.instance.pairedBlox;
        if (blox == null) {
          debugPrint('BloxDiscovery: no device found after NSD scan on resume');
          return;
        }

        if (await BloxDiscoveryService.instance.quickHealthCheck(
          timeout: const Duration(seconds: 5),
        )) {
          await FulaApiService.instance.initializeLocalClient(
            endpoint: blox.s3Url,
            accessToken: secret,
          );
          // Persist new IP for next startup
          if (BloxDiscoveryService.instance.manualIp == null) {
            BloxDiscoveryService.instance.setLastKnownIp(blox.ip);
            await SecureStorageService.instance.write(
              SecureStorageKeys.bloxLastKnownIp,
              blox.ip,
            );
          }
          debugPrint('BloxDiscovery: local client initialized on resume after NSD discovery');
        } else {
          debugPrint('BloxDiscovery: device not reachable after NSD scan on resume');
        }
      } catch (e) {
        debugPrint('BloxDiscovery: resume refresh failed: $e');
      }
    });
  }

  void _onTosAccepted() {
    setState(() {
      _acceptedThisSession = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final router = ref.watch(routerProvider);

    // ToS is accepted if: saved in storage OR accepted this session
    final tosAccepted = settings.tosAccepted || _acceptedThisSession;

    return MaterialApp.router(
      title: 'FxFiles',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: settings.themeMode,
      routerConfig: router,
      builder: (context, child) {
        // Show ToS screen if not accepted
        if (!tosAccepted) {
          return TermsOfServiceScreen(onAccepted: _onTosAccepted);
        }

        return DesktopKeyboardShortcuts(
          child: Column(
            children: [
              Expanded(child: child ?? const SizedBox()),
              const MiniPlayer(),
            ],
          ),
        );
      },
    );
  }
}
