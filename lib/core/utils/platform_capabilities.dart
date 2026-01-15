import 'dart:io';

/// Centralized platform detection for conditional features.
/// Use these flags to determine platform-specific behavior throughout the app.
class PlatformCapabilities {
  PlatformCapabilities._();

  /// Whether the platform allows browsing the full filesystem.
  /// True on Android (with MANAGE_EXTERNAL_STORAGE permission).
  /// False on iOS (sandboxed - only PhotoKit and app sandbox access).
  static bool get canBrowseFilesystem => Platform.isAndroid;

  /// Whether the platform uses PhotoKit for media access.
  /// True on iOS, false on Android (uses direct filesystem).
  static bool get usesPhotoKit => Platform.isIOS;

  /// Whether the platform has a Downloads folder category.
  /// True on Android (/storage/emulated/0/Download).
  /// False on iOS (no equivalent folder).
  static bool get hasDownloadsCategory => Platform.isAndroid;

  /// Whether the platform can watch external folders for changes.
  /// True on Android (with storage permission).
  /// False on iOS (can only watch app sandbox).
  static bool get canWatchExternalFolders => Platform.isAndroid;

  /// Whether documents category should show filesystem documents.
  /// True on Android (scans Documents folder).
  /// False on iOS (shows imported files from app sandbox).
  static bool get canScanDocumentsFolder => Platform.isAndroid;

  /// Whether the platform supports arbitrary folder selection for sync.
  /// True on Android.
  /// False on iOS (limited to categories and app sandbox).
  static bool get canSelectFoldersForSync => Platform.isAndroid;

  /// Whether search can scan the entire filesystem.
  /// True on Android.
  /// False on iOS (limited to PhotoKit + imported files).
  static bool get canSearchFilesystem => Platform.isAndroid;

  /// Whether the app should show iOS-specific explanations.
  static bool get shouldShowIOSFilesExplanation => Platform.isIOS;

  /// Platform-specific category labels
  static String get imagesLabel => Platform.isIOS ? 'Photos' : 'Images';
  static String get documentsLabel => Platform.isIOS ? 'My Files' : 'Docs';

  /// Check if running on mobile (iOS or Android)
  static bool get isMobile => Platform.isIOS || Platform.isAndroid;

  /// Check if running on desktop
  static bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}
