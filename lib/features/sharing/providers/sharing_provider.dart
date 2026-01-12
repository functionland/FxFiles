import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/sharing_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/cloud_share_storage_service.dart';
import 'package:fula_files/shared/utils/error_messages.dart';

/// Provider for sharing service
final sharingServiceProvider = Provider<SharingService>((ref) {
  return SharingService.instance;
});

/// Provider for outgoing shares (shares created by this user)
final outgoingSharesProvider = FutureProvider<List<OutgoingShare>>((ref) async {
  return SharingService.instance.getOutgoingShares();
});

/// Provider for active outgoing shares
final activeOutgoingSharesProvider = FutureProvider<List<OutgoingShare>>((ref) async {
  return SharingService.instance.getActiveOutgoingShares();
});

/// Provider for accepted shares (shares received by this user)
final acceptedSharesProvider = FutureProvider<List<AcceptedShare>>((ref) async {
  return SharingService.instance.getAcceptedShares();
});

/// Provider for valid accepted shares
final validAcceptedSharesProvider = FutureProvider<List<AcceptedShare>>((ref) async {
  return SharingService.instance.getValidAcceptedShares();
});

/// Provider for user's public key (for sharing with others)
final userPublicKeyProvider = FutureProvider<String?>((ref) async {
  return AuthService.instance.getPublicKeyString();
});

/// State notifier for managing shares
class SharesNotifier extends Notifier<SharesState> {
  late final SharingService _sharingService;

  @override
  SharesState build() {
    _sharingService = SharingService.instance;
    // Schedule loadShares after build completes to avoid circular dependency
    Future.microtask(() => loadShares());
    return SharesState.initial();
  }

  Future<void> loadShares() async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      var outgoing = await _sharingService.getOutgoingShares();
      final accepted = await _sharingService.getValidAcceptedShares();

      // Auto-restore from cloud if local is empty
      if (outgoing.isEmpty) {
        try {
          final cloudShares = await CloudShareStorageService.instance.downloadShares();
          if (cloudShares.isNotEmpty) {
            // Merge cloud shares into local
            await CloudShareStorageService.instance.syncShares(outgoing);
            outgoing = await _sharingService.getOutgoingShares();
          }
        } catch (e) {
          // Ignore errors - cloud sync is optional
        }
      }

      state = state.copyWith(
        isLoading: false,
        outgoingShares: outgoing,
        acceptedShares: accepted,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forShare(e),
      );
    }
  }

  /// Create a new share for a specific recipient
  Future<ShareToken?> createShare({
    required String pathScope,
    required String bucket,
    required String recipientPublicKeyBase64,
    required String recipientName,
    Uint8List? dek,  // DEPRECATED - ignored, kept for interface compat
    SharePermissions permissions = SharePermissions.readOnly,
    int? expiryDays,
    String? label,
    ShareMode shareMode = ShareMode.temporal,
    SnapshotBinding? snapshotBinding,
    String? fileName,
    String? contentType,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final recipientPublicKey = AuthService.instance.parsePublicKey(recipientPublicKeyBase64);

      final outgoingShare = await _sharingService.shareWithUser(
        pathScope: pathScope,
        bucket: bucket,
        recipientPublicKey: recipientPublicKey,
        recipientName: recipientName,
        permissions: permissions,
        expiryDays: expiryDays,
        label: label,
        shareMode: shareMode,
        snapshotBinding: snapshotBinding,
        fileName: fileName,
        contentType: contentType,
      );

      // Sync to cloud
      await _syncToCloud();

      // Reload shares
      await loadShares();

      return outgoingShare.token;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forShare(e),
      );
      return null;
    }
  }

  /// Create a public link that anyone with the link can access
  Future<GeneratedShareLink?> createPublicLink({
    required String pathScope,
    required String bucket,
    Uint8List? dek,  // DEPRECATED - ignored, kept for interface compat
    required int expiryDays,
    String? label,
    ShareMode shareMode = ShareMode.temporal,
    SnapshotBinding? snapshotBinding,
    String? fileName,
    String? contentType,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final result = await _sharingService.createPublicLink(
        pathScope: pathScope,
        bucket: bucket,
        expiryDays: expiryDays,
        label: label,
        shareMode: shareMode,
        snapshotBinding: snapshotBinding,
        fileName: fileName,
        contentType: contentType,
      );

      // Sync to cloud
      await _syncToCloud();

      // Reload shares
      await loadShares();

      return result;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forShare(e),
      );
      return null;
    }
  }

  /// Create a password-protected link
  Future<GeneratedShareLink?> createPasswordProtectedLink({
    required String pathScope,
    required String bucket,
    Uint8List? dek,  // DEPRECATED - ignored, kept for interface compat
    required int expiryDays,
    required String password,
    String? label,
    ShareMode shareMode = ShareMode.temporal,
    SnapshotBinding? snapshotBinding,
    String? fileName,
    String? contentType,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final result = await _sharingService.createPasswordProtectedLink(
        pathScope: pathScope,
        bucket: bucket,
        expiryDays: expiryDays,
        password: password,
        label: label,
        shareMode: shareMode,
        snapshotBinding: snapshotBinding,
        fileName: fileName,
        contentType: contentType,
      );

      // Sync to cloud
      await _syncToCloud();

      // Reload shares
      await loadShares();

      return result;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forShare(e),
      );
      return null;
    }
  }

  /// Download a file using an accepted share
  Future<Uint8List?> downloadSharedFile(String shareId) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final share = state.acceptedShares.firstWhere(
        (s) => s.id == shareId,
        orElse: () => throw SharingException('Share not found'),
      );

      final data = await _sharingService.downloadSharedFile(share);

      state = state.copyWith(isLoading: false);
      return data;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forShare(e),
      );
      return null;
    }
  }

  /// Download a file using an accepted share object directly
  Future<Uint8List?> downloadFromShare(AcceptedShare share) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final data = await _sharingService.downloadSharedFile(share);

      state = state.copyWith(isLoading: false);
      return data;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forShare(e),
      );
      return null;
    }
  }

  /// Sync shares to cloud storage
  Future<void> _syncToCloud() async {
    try {
      final shares = await _sharingService.getOutgoingShares();
      await CloudShareStorageService.instance.uploadShares(shares);
    } catch (e) {
      // Don't fail the operation if cloud sync fails
      // Just log the error
    }
  }

  /// Sync shares from cloud storage
  Future<void> syncFromCloud() async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final localShares = await _sharingService.getOutgoingShares();
      final mergedShares = await CloudShareStorageService.instance.syncShares(localShares);

      // Import merged shares if there are new ones from cloud
      if (mergedShares.length != localShares.length) {
        await _sharingService.importOutgoingShares(mergedShares);
      }

      await loadShares();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forShare(e),
      );
    }
  }

  /// Accept a share from encoded string
  Future<AcceptedShare?> acceptShare(String encodedToken) async {
    state = state.copyWith(isLoading: true, error: null);
    
    try {
      final accepted = await _sharingService.acceptShareFromString(encodedToken);
      
      // Reload shares
      await loadShares();
      
      return accepted;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forShare(e),
      );
      return null;
    }
  }

  /// Accept a share from URL
  Future<AcceptedShare?> acceptShareFromUrl(String url) async {
    state = state.copyWith(isLoading: true, error: null);
    
    try {
      final token = _sharingService.parseShareLink(url);
      if (token == null) {
        throw SharingException('Invalid share link');
      }
      
      final accepted = await _sharingService.acceptShare(token);
      
      // Reload shares
      await loadShares();
      
      return accepted;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forShare(e),
      );
      return null;
    }
  }

  /// Revoke a share
  Future<bool> revokeShare(String shareId) async {
    state = state.copyWith(isLoading: true, error: null);
    
    try {
      await _sharingService.revokeShare(shareId);
      
      // Reload shares
      await loadShares();
      
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forShare(e),
      );
      return false;
    }
  }

  /// Remove an accepted share
  Future<bool> removeAcceptedShare(String shareId) async {
    state = state.copyWith(isLoading: true, error: null);
    
    try {
      await _sharingService.removeAcceptedShare(shareId);
      
      // Reload shares
      await loadShares();
      
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forShare(e),
      );
      return false;
    }
  }

  /// Generate share link for a token
  String generateShareLink(ShareToken token, {Uint8List? linkSecretKey}) {
    return _sharingService.generateShareLink(token, linkSecretKey: linkSecretKey);
  }

  /// Generate share link from an OutgoingShare (handles all types)
  String generateShareLinkFromOutgoing(OutgoingShare share) {
    return _sharingService.generateShareLinkFromOutgoing(share);
  }

  /// Clear error
  void clearError() {
    state = state.copyWith(error: null);
  }
}

/// State for shares
class SharesState {
  final bool isLoading;
  final String? error;
  final List<OutgoingShare> outgoingShares;
  final List<AcceptedShare> acceptedShares;

  SharesState({
    required this.isLoading,
    this.error,
    required this.outgoingShares,
    required this.acceptedShares,
  });

  factory SharesState.initial() => SharesState(
    isLoading: false,
    outgoingShares: [],
    acceptedShares: [],
  );

  SharesState copyWith({
    bool? isLoading,
    String? error,
    List<OutgoingShare>? outgoingShares,
    List<AcceptedShare>? acceptedShares,
  }) {
    return SharesState(
      isLoading: isLoading ?? this.isLoading,
      error: error,
      outgoingShares: outgoingShares ?? this.outgoingShares,
      acceptedShares: acceptedShares ?? this.acceptedShares,
    );
  }

  /// Get active outgoing shares
  List<OutgoingShare> get activeOutgoingShares =>
      outgoingShares.where((s) => s.isValid).toList();

  /// Get shares for a specific path
  List<OutgoingShare> getSharesForPath(String bucket, String path) {
    return outgoingShares.where((s) =>
      s.bucket == bucket &&
      (path.startsWith(s.pathScope) || s.pathScope.startsWith(path))
    ).toList();
  }

  /// Check if a path is shared
  bool isPathShared(String bucket, String path) {
    return getSharesForPath(bucket, path).isNotEmpty;
  }
}

/// Provider for shares state notifier
final sharesProvider = NotifierProvider<SharesNotifier, SharesState>(() {
  return SharesNotifier();
});

/// Provider to check if a specific path has active shares
final pathSharesProvider = Provider.family<List<OutgoingShare>, PathShareQuery>((ref, query) {
  final state = ref.watch(sharesProvider);
  return state.getSharesForPath(query.bucket, query.path);
});

/// Query object for path shares
class PathShareQuery {
  final String bucket;
  final String path;

  PathShareQuery({required this.bucket, required this.path});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PathShareQuery &&
          runtimeType == other.runtimeType &&
          bucket == other.bucket &&
          path == other.path;

  @override
  int get hashCode => bucket.hashCode ^ path.hashCode;
}
