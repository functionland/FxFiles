/// User-friendly error message utility for FxFiles
///
/// This utility maps technical exceptions to user-friendly messages
/// that are appropriate for display in the UI.
library;

/// Categories of errors for better user feedback
enum ErrorCategory {
  network,
  storage,
  permission,
  authentication,
  sync,
  share,
  file,
  archive,
  billing,
  unknown,
}

/// User-friendly error message helper
class ErrorMessages {
  ErrorMessages._();

  /// Convert any exception to a user-friendly message
  static String getUserFriendlyMessage(dynamic error, {String? context}) {
    final errorStr = error.toString().toLowerCase();

    // Network errors
    if (_isNetworkError(errorStr)) {
      return context != null
          ? 'Unable to $context. Please check your internet connection and try again.'
          : 'Connection failed. Please check your internet connection and try again.';
    }

    // Timeout errors
    if (_isTimeoutError(errorStr)) {
      return context != null
          ? 'The operation timed out while trying to $context. Please try again.'
          : 'The operation timed out. Please try again.';
    }

    // Permission errors
    if (_isPermissionError(errorStr)) {
      return context != null
          ? 'Permission denied while trying to $context. Please check app permissions in Settings.'
          : 'Permission denied. Please check app permissions in Settings.';
    }

    // Storage/file system errors
    if (_isStorageError(errorStr)) {
      return context != null
          ? 'Unable to $context. Please check available storage space.'
          : 'Storage error. Please check available storage space.';
    }

    // Authentication errors
    if (_isAuthError(errorStr)) {
      return 'Authentication failed. Please sign in again.';
    }

    // Encryption/decryption errors
    if (_isEncryptionError(errorStr)) {
      return context != null
          ? 'Unable to $context. The file may be corrupted or the password is incorrect.'
          : 'Decryption failed. Please check your password and try again.';
    }

    // Not found errors
    if (_isNotFoundError(errorStr)) {
      return context != null
          ? 'Could not find the item while trying to $context.'
          : 'The requested item could not be found.';
    }

    // Already exists errors
    if (_isAlreadyExistsError(errorStr)) {
      return context != null
          ? 'Unable to $context. An item with this name already exists.'
          : 'An item with this name already exists.';
    }

    // Invalid format errors
    if (_isFormatError(errorStr)) {
      return context != null
          ? 'Unable to $context. The format is invalid or unsupported.'
          : 'Invalid format. Please check the input and try again.';
    }

    // Sync errors
    if (_isSyncError(errorStr)) {
      return context != null
          ? 'Sync failed while trying to $context. Please try again later.'
          : 'Sync failed. Please try again later.';
    }

    // Share errors
    if (_isShareError(errorStr)) {
      return _getShareErrorMessage(errorStr, context);
    }

    // Billing/wallet errors
    if (_isBillingError(errorStr)) {
      return _getBillingErrorMessage(errorStr, context);
    }

    // Archive errors
    if (_isArchiveError(errorStr)) {
      return context != null
          ? 'Unable to $context. The archive may be corrupted or in an unsupported format.'
          : 'Archive operation failed. Please try again.';
    }

    // API configuration errors
    if (_isConfigError(errorStr)) {
      return 'Service not configured. Please check your settings.';
    }

    // Cancelled by user
    if (_isCancelledError(errorStr)) {
      return 'Operation cancelled.';
    }

    // Default fallback with context
    if (context != null) {
      return 'Unable to $context. Please try again.';
    }

    return 'Something went wrong. Please try again.';
  }

  /// Get error category for analytics/logging
  static ErrorCategory getErrorCategory(dynamic error) {
    final errorStr = error.toString().toLowerCase();

    if (_isNetworkError(errorStr) || _isTimeoutError(errorStr)) {
      return ErrorCategory.network;
    }
    if (_isStorageError(errorStr)) return ErrorCategory.storage;
    if (_isPermissionError(errorStr)) return ErrorCategory.permission;
    if (_isAuthError(errorStr)) return ErrorCategory.authentication;
    if (_isSyncError(errorStr)) return ErrorCategory.sync;
    if (_isShareError(errorStr)) return ErrorCategory.share;
    if (_isArchiveError(errorStr)) return ErrorCategory.archive;
    if (_isBillingError(errorStr)) return ErrorCategory.billing;
    if (_isNotFoundError(errorStr) || _isAlreadyExistsError(errorStr) || _isFormatError(errorStr)) {
      return ErrorCategory.file;
    }

    return ErrorCategory.unknown;
  }

  // ============================================================================
  // Error detection helpers
  // ============================================================================

  static bool _isNetworkError(String error) {
    return error.contains('socketexception') ||
        error.contains('connection refused') ||
        error.contains('connection reset') ||
        error.contains('no internet') ||
        error.contains('network is unreachable') ||
        error.contains('failed host lookup') ||
        error.contains('connection failed') ||
        error.contains('handshakeexception') ||
        error.contains('clientexception');
  }

  static bool _isTimeoutError(String error) {
    return error.contains('timeout') ||
        error.contains('timed out') ||
        error.contains('connection timed out');
  }

  static bool _isPermissionError(String error) {
    return error.contains('permission denied') ||
        error.contains('access denied') ||
        error.contains('not authorized') ||
        error.contains('unauthorized') ||
        error.contains('forbidden') ||
        error.contains('403');
  }

  static bool _isStorageError(String error) {
    return error.contains('no space left') ||
        error.contains('disk full') ||
        error.contains('storage') && error.contains('full') ||
        error.contains('enospc') ||
        error.contains('quota exceeded');
  }

  static bool _isAuthError(String error) {
    return error.contains('authentication failed') ||
        error.contains('invalid token') ||
        error.contains('token expired') ||
        error.contains('sign in') ||
        error.contains('not signed in') ||
        error.contains('401') ||
        error.contains('unauthenticated');
  }

  static bool _isEncryptionError(String error) {
    return error.contains('decrypt') && error.contains('failed') ||
        error.contains('encryption key') ||
        error.contains('invalid key') ||
        error.contains('wrong password') ||
        error.contains('mac mismatch') ||
        error.contains('authentication tag');
  }

  static bool _isNotFoundError(String error) {
    return error.contains('not found') ||
        error.contains('no such file') ||
        error.contains('does not exist') ||
        error.contains('404') ||
        error.contains('nosuchkey') ||
        error.contains('nosuchbucket');
  }

  static bool _isAlreadyExistsError(String error) {
    return error.contains('already exists') ||
        error.contains('duplicate') ||
        error.contains('conflict') ||
        error.contains('409');
  }

  static bool _isFormatError(String error) {
    return error.contains('format') && error.contains('invalid') ||
        error.contains('parse') && error.contains('error') ||
        error.contains('malformed') ||
        error.contains('unsupported format') ||
        error.contains('invalid data');
  }

  static bool _isSyncError(String error) {
    return error.contains('sync') && error.contains('failed') ||
        error.contains('sync') && error.contains('error') ||
        error.contains('upload failed') ||
        error.contains('download failed');
  }

  static bool _isShareError(String error) {
    return error.contains('share') ||
        error.contains('recipient') ||
        error.contains('public key') ||
        error.contains('revoked') ||
        error.contains('expired');
  }

  static bool _isBillingError(String error) {
    return error.contains('billingapiexception') ||
        error.contains('wallet') ||
        error.contains('balance') ||
        error.contains('insufficient') ||
        error.contains('transaction') ||
        error.contains('payment') ||
        error.contains('credit') ||
        error.contains('linked');
  }

  static bool _isArchiveError(String error) {
    return error.contains('archive') ||
        error.contains('zip') ||
        error.contains('extract') ||
        error.contains('compress');
  }

  static bool _isConfigError(String error) {
    return error.contains('not configured') ||
        error.contains('not initialized') ||
        error.contains('missing configuration');
  }

  static bool _isCancelledError(String error) {
    return error.contains('cancelled') ||
        error.contains('canceled') ||
        error.contains('aborted') ||
        error.contains('user cancelled');
  }

  // ============================================================================
  // Specific error message generators
  // ============================================================================

  static String _getShareErrorMessage(String error, String? context) {
    if (error.contains('revoked')) {
      return 'This share has been revoked by the owner.';
    }
    if (error.contains('expired')) {
      return 'This share link has expired.';
    }
    if (error.contains('invalid') && error.contains('recipient')) {
      return 'Invalid recipient. Please check the Share ID and try again.';
    }
    if (error.contains('public key')) {
      return 'Invalid Share ID format. Please check and try again.';
    }
    return context != null
        ? 'Unable to $context. Please try again.'
        : 'Share operation failed. Please try again.';
  }

  static String _getBillingErrorMessage(String error, String? context) {
    if (error.contains('insufficient')) {
      return 'Insufficient balance. Please add more credits.';
    }
    if (error.contains('wallet') && error.contains('not connected')) {
      return 'Wallet not connected. Please connect your wallet first.';
    }
    if (error.contains('transaction') && error.contains('failed')) {
      return 'Transaction failed. Please try again.';
    }
    if (error.contains('already linked')) {
      return 'This wallet is already linked to another account.';
    }
    if (error.contains('invalid signature')) {
      return 'Signature verification failed. Please try again.';
    }

    // For BillingApiException errors with server messages like "400 - Actual error message"
    // Extract and show the actual server message
    final serverMsgMatch = RegExp(r'\d{3}\s*-\s*(.+)$').firstMatch(error);
    if (serverMsgMatch != null) {
      final serverMessage = serverMsgMatch.group(1)!.trim();
      // Capitalize first letter if needed
      if (serverMessage.isNotEmpty) {
        return serverMessage[0].toUpperCase() + serverMessage.substring(1);
      }
    }

    return context != null
        ? 'Unable to $context. Please try again.'
        : 'Billing operation failed. Please try again.';
  }

  // ============================================================================
  // Contextual error messages for specific operations
  // ============================================================================

  /// Get error message for file operations
  static String forFileOperation(dynamic error, String operation) {
    return getUserFriendlyMessage(error, context: operation);
  }

  /// Get error message for sync operations
  static String forSync(dynamic error) {
    return getUserFriendlyMessage(error, context: 'sync files');
  }

  /// Get error message for upload operations
  static String forUpload(dynamic error) {
    return getUserFriendlyMessage(error, context: 'upload');
  }

  /// Get error message for download operations
  static String forDownload(dynamic error) {
    return getUserFriendlyMessage(error, context: 'download');
  }

  /// Get error message for share operations
  static String forShare(dynamic error) {
    return getUserFriendlyMessage(error, context: 'share');
  }

  /// Get error message for delete operations
  static String forDelete(dynamic error) {
    return getUserFriendlyMessage(error, context: 'delete');
  }

  /// Get error message for copy operations
  static String forCopy(dynamic error) {
    return getUserFriendlyMessage(error, context: 'copy');
  }

  /// Get error message for move operations
  static String forMove(dynamic error) {
    return getUserFriendlyMessage(error, context: 'move');
  }

  /// Get error message for rename operations
  static String forRename(dynamic error) {
    return getUserFriendlyMessage(error, context: 'rename');
  }

  /// Get error message for authentication
  static String forAuth(dynamic error) {
    return getUserFriendlyMessage(error, context: 'sign in');
  }

  /// Get error message for settings
  static String forSettings(dynamic error) {
    return getUserFriendlyMessage(error, context: 'save settings');
  }

  /// Get error message for archive operations
  static String forArchive(dynamic error, {bool isExtract = false}) {
    return getUserFriendlyMessage(
      error,
      context: isExtract ? 'extract archive' : 'create archive',
    );
  }

  /// Get error message for face detection
  static String forFaceDetection(dynamic error) {
    return getUserFriendlyMessage(error, context: 'detect faces');
  }

  /// Get error message for billing/wallet operations
  static String forBilling(dynamic error, {String? operation}) {
    return getUserFriendlyMessage(
      error,
      context: operation ?? 'complete transaction',
    );
  }

  /// Get error message for crop/edit operations
  static String forImageEdit(dynamic error, {String? operation}) {
    return getUserFriendlyMessage(
      error,
      context: operation ?? 'edit image',
    );
  }

  /// Get error message for restore operations
  static String forRestore(dynamic error) {
    return getUserFriendlyMessage(error, context: 'restore');
  }
}
