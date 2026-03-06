import 'dart:io';

/// Centralized platform detection for conditional features.
/// Use these flags to determine platform-specific behavior throughout the app.
class PlatformCapabilities {
  PlatformCapabilities._();

  /// Whether the platform allows browsing the full filesystem.
  /// True on Android (with MANAGE_EXTERNAL_STORAGE permission) and desktop platforms.
  /// False on iOS (sandboxed - only PhotoKit and app sandbox access).
  static bool get canBrowseFilesystem => !Platform.isIOS;

  /// Whether the platform uses PhotoKit for media access.
  /// True on iOS, false on Android (uses direct filesystem).
  static bool get usesPhotoKit => Platform.isIOS;

  /// Whether the platform has a Downloads folder category.
  /// True on Android and desktop platforms.
  /// False on iOS (no equivalent folder).
  static bool get hasDownloadsCategory => !Platform.isIOS;

  /// Whether the platform can watch external folders for changes.
  /// True on Android and desktop (uses Directory.watch()).
  /// False on iOS (can only watch app sandbox).
  static bool get canWatchExternalFolders => !Platform.isIOS;

  /// Whether documents category should show filesystem documents.
  /// True on Android and desktop (scans Documents folder).
  /// False on iOS (shows imported files from app sandbox).
  static bool get canScanDocumentsFolder => !Platform.isIOS;

  /// Whether the platform supports arbitrary folder selection for sync.
  /// True on Android and desktop.
  /// False on iOS (limited to categories and app sandbox).
  static bool get canSelectFoldersForSync => !Platform.isIOS;

  /// Whether search can scan the entire filesystem.
  /// True on Android and desktop.
  /// False on iOS (limited to PhotoKit + imported files).
  static bool get canSearchFilesystem => !Platform.isIOS;

  /// Whether the app should show iOS-specific explanations.
  static bool get shouldShowIOSFilesExplanation => Platform.isIOS;

  /// Platform-specific category labels
  static String get imagesLabel =>
      Platform.isIOS ? 'Photos' : (isDesktop ? 'Pictures' : 'Images');
  static String get documentsLabel =>
      Platform.isIOS ? 'My Files' : 'Documents';

  /// Check if running on mobile (iOS or Android)
  static bool get isMobile => Platform.isIOS || Platform.isAndroid;

  /// Check if running on desktop
  static bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}
