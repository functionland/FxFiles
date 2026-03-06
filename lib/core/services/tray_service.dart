import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:fula_files/core/models/upload_progress.dart';
import 'package:fula_files/core/services/upload_progress_manager.dart';
import 'package:fula_files/core/utils/platform_capabilities.dart';

/// Manages the desktop system tray icon, tooltip, and context menu.
/// Shows sync progress in the tray like OneDrive / Dropbox.
/// Intercepts window close to minimize to tray instead of quitting.
class TrayService with TrayListener, WindowListener {
  TrayService._();
  static final TrayService instance = TrayService._();

  bool _isInitialized = false;
  bool _isSyncing = false;

  /// Throttle tray updates to avoid flooding the native API.
  DateTime _lastTrayUpdate = DateTime(0);
  static const _trayUpdateInterval = Duration(seconds: 1);

  Future<void> init() async {
    if (!PlatformCapabilities.isDesktop) return;
    if (_isInitialized) return;

    try {
      // tray_manager resolves iconPath relative to data/flutter_assets/
      // so pass the Flutter asset path directly
      final iconPath = Platform.isWindows
          ? 'assets/icons/app_icon.ico'
          : 'assets/icons/icon.png';

      await trayManager.setIcon(iconPath);
      await trayManager.setToolTip('FxFiles \u2014 Up to date');

      trayManager.addListener(this);
      await _rebuildMenu();

      // Intercept window close to minimize to tray instead of quitting
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);

      // Listen for sync progress changes
      UploadProgressManager.instance.addListener(_onProgressUpdate);

      _isInitialized = true;
      debugPrint('TrayService initialized');
    } catch (e) {
      debugPrint('TrayService: Failed to initialize: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // TrayListener callbacks
  // ---------------------------------------------------------------------------

  @override
  void onTrayIconMouseDown() {
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  // ---------------------------------------------------------------------------
  // WindowListener — minimize to tray on close
  // ---------------------------------------------------------------------------

  @override
  void onWindowClose() async {
    // Hide to tray instead of quitting
    await windowManager.hide();
  }

  // ---------------------------------------------------------------------------
  // Progress integration
  // ---------------------------------------------------------------------------

  void _onProgressUpdate(BatchUploadProgress? progress) {
    if (progress != null) {
      _isSyncing = true;
      final now = DateTime.now();
      if (now.difference(_lastTrayUpdate) >= _trayUpdateInterval) {
        _lastTrayUpdate = now;
        _updateSyncStatus(progress);
      }
    } else if (_isSyncing) {
      _isSyncing = false;
      _showIdle();
    }
  }

  void _updateSyncStatus(BatchUploadProgress progress) {
    trayManager.setToolTip(
      'FxFiles \u2014 Syncing ${progress.fileProgressString} '
      '(${progress.formattedPercentage})',
    );
    _rebuildMenu(progress: progress);
  }

  void _showIdle() {
    trayManager.setToolTip('FxFiles \u2014 Up to date');
    _rebuildMenu();
  }

  // ---------------------------------------------------------------------------
  // Context menu
  // ---------------------------------------------------------------------------

  Future<void> _rebuildMenu({BatchUploadProgress? progress}) async {
    final items = <MenuItem>[
      MenuItem(label: 'Open FxFiles', onClick: (_) => _showWindow()),
    ];

    if (progress != null) {
      items.add(MenuItem.separator());
      items.add(MenuItem(
        label: 'Syncing ${progress.fileProgressString}',
        disabled: true,
      ));
      items.add(MenuItem(
        label: '${progress.formattedPercentage} \u2014 ${progress.formattedETA} remaining',
        disabled: true,
      ));
      if (progress.currentFileName != null) {
        items.add(MenuItem(
          label: progress.currentFileName!,
          disabled: true,
        ));
      }
    } else {
      items.add(MenuItem.separator());
      items.add(MenuItem(label: 'Up to date', disabled: true));
    }

    items.add(MenuItem.separator());
    items.add(MenuItem(
      label: 'Quit',
      onClick: (_) async {
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
      },
    ));

    await trayManager.setContextMenu(Menu(items: items));
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  void dispose() {
    if (_isInitialized) {
      UploadProgressManager.instance.removeListener(_onProgressUpdate);
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      trayManager.destroy();
    }
  }
}
