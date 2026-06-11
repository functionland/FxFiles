import 'package:flutter/foundation.dart';

/// Centralized platform detection for conditional features.
/// Use these flags to determine platform-specific behavior throughout the app.
///
/// Implemented with [kIsWeb] + [defaultTargetPlatform] (not dart:io
/// Platform.*) so this file is safe in the web compile graph. On web,
/// [defaultTargetPlatform] reports the browser's host OS (e.g. iOS for
/// mobile Safari), so every "is this native iOS?" check below guards with
/// !kIsWeb first — native behavior is identical to the previous dart:io
/// implementation, and web answers false for all native-filesystem
/// capabilities.
class PlatformCapabilities {
  PlatformCapabilities._();

  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Whether the app is running in a browser.
  static bool get isWeb => kIsWeb;

  /// Whether the platform allows browsing the full filesystem.
  /// True on Android (with MANAGE_EXTERNAL_STORAGE permission) and desktop platforms.
  /// False on iOS (sandboxed - only PhotoKit and app sandbox access) and web.
  static bool get canBrowseFilesystem => !kIsWeb && !_isIOS;

  /// Whether the platform uses PhotoKit for media access.
  /// True on iOS, false on Android (uses direct filesystem).
  static bool get usesPhotoKit => _isIOS;

  /// Whether the platform has a Downloads folder category.
  /// True on Android and desktop platforms.
  /// False on iOS (no equivalent folder) and web.
  static bool get hasDownloadsCategory => !kIsWeb && !_isIOS;

  /// Whether the platform can watch external folders for changes.
  /// True on Android and desktop (uses Directory.watch()).
  /// False on iOS (can only watch app sandbox) and web.
  static bool get canWatchExternalFolders => !kIsWeb && !_isIOS;

  /// Whether documents category should show filesystem documents.
  /// True on Android and desktop (scans Documents folder).
  /// False on iOS (shows imported files from app sandbox) and web.
  static bool get canScanDocumentsFolder => !kIsWeb && !_isIOS;

  /// Whether the platform supports arbitrary folder selection for sync.
  /// True on Android and desktop.
  /// False on iOS (limited to categories and app sandbox) and web.
  static bool get canSelectFoldersForSync => !kIsWeb && !_isIOS;

  /// Whether search can scan the entire filesystem.
  /// True on Android and desktop.
  /// False on iOS (limited to PhotoKit + imported files) and web.
  static bool get canSearchFilesystem => !kIsWeb && !_isIOS;

  /// Whether the app should show iOS-specific explanations.
  static bool get shouldShowIOSFilesExplanation => _isIOS;

  /// Platform-specific category labels
  static String get imagesLabel =>
      _isIOS ? 'Photos' : (isDesktop ? 'Pictures' : 'Images');
  static String get documentsLabel => _isIOS ? 'My Files' : 'Documents';

  /// Check if running on mobile (iOS or Android)
  static bool get isMobile => _isIOS || _isAndroid;

  /// Native iOS (false on web, including mobile Safari) — for callers
  /// that branch on iOS URI conventions (e.g. the sms: separator).
  static bool get isIOS => _isIOS;

  /// Check if running on desktop
  static bool get isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);
}
