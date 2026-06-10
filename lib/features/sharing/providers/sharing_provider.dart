import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
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
  late SharingService _sharingService;

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
      var accepted = await _sharingService.getValidAcceptedShares();

      // Auto-restore from cloud if local is empty
      if (outgoing.isEmpty) {
        try {
          final cloudShares = await CloudShareStorageService.instance.downloadShares();
          if (cloudShares.isNotEmpty) {
            await _sharingService.importOutgoingShares(cloudShares);
            outgoing = cloudShares;
          }
        } catch (e) {
          // Ignore errors - cloud sync is optional
        }
      }

      // Auto-restore accepted shares from cloud if local is empty
      if (accepted.isEmpty) {
        try {
          final cloudAccepted = await CloudShareStorageService.instance.downloadAcceptedShares();
          if (cloudAccepted.isNotEmpty) {
            await _sharingService.importAcceptedShares(cloudAccepted);
            accepted = cloudAccepted;
          }
        } catch (e) {
          // Ignore errors - cloud sync is optional
        }
      }

      // Merge cloud revocation list so revokes from other devices apply here.
      try {
        final cloudRevoked =
            await CloudShareStorageService.instance.downloadRevokedList();
        if (cloudRevoked.isNotEmpty) {
          await _sharingService.importRevokedShareIds(cloudRevoked);
        }
      } catch (_) {
        // Optional sync — ignore failures.
      }

      // Ensure local data is backed up to cloud for future restores
      if (outgoing.isNotEmpty || accepted.isNotEmpty) {
        _syncToCloud();
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

  /// Create a public link for a tag (latest mode).
  Future<GeneratedShareLink?> createTagPublicLink({
    required String tagId,
    required int expiryDays,
    String? label,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final result = await _sharingService.createTagPublicLink(
        tagId: tagId,
        expiryDays: expiryDays,
        label: label,
      );

      await _syncToCloud();
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

  /// Create a password-protected public link for a tag (latest mode).
  Future<GeneratedShareLink?> createTagPasswordLink({
    required String tagId,
    required int expiryDays,
    required String password,
    String? label,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final result = await _sharingService.createTagPasswordProtectedLink(
        tagId: tagId,
        expiryDays: expiryDays,
        password: password,
        label: label,
      );

      await _syncToCloud();
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

  /// Share a tag with a specific recipient (latest mode).
  Future<ShareToken?> shareTagWithUser({
    required String tagId,
    required String recipientPublicKeyBase64,
    required String recipientName,
    int? expiryDays,
    String? label,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final recipientPublicKey = AuthService.instance.parsePublicKey(recipientPublicKeyBase64);
      final outgoingShare = await _sharingService.shareTagWithUser(
        tagId: tagId,
        recipientPublicKey: recipientPublicKey,
        recipientName: recipientName,
        expiryDays: expiryDays,
        label: label,
      );

      await _syncToCloud();
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
      final accepted = await _sharingService.getAcceptedShares();
      await CloudShareStorageService.instance.uploadAcceptedShares(accepted);
    } catch (e) {
      // Don't fail the operation if cloud sync fails
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

      await _syncToCloud();
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
  ///
  /// For Type 1/2 (public/password link) URLs of the form
  /// `https://cloud.fx.land/view/{id}#{fragment}`, we extract the
  /// full [PublicLinkPayload] (which carries the URL's ephemeral
  /// private key in `sk`) and thread `linkSecretKey` through to
  /// [SharingService.acceptShare]. That way the desktop folder-sync
  /// service can later use the linkSecretKey to decrypt the share
  /// manifest + unwrap per-file tokens cross-account.
  ///
  /// For Type 3 (recipient-specific) `fxblox://share/...` deep links,
  /// the legacy path applies: `parseShareLink` returns the token, no
  /// linkSecretKey to thread.
  Future<AcceptedShare?> acceptShareFromUrl(String url) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      // Try the public-link payload form first (Type 1/2). It returns
      // null for fxblox:// deep links and password-protected links
      // (those need separate handling).
      final publicPayload = _sharingService.parsePublicLink(url);
      if (publicPayload != null && !publicPayload.isPasswordProtected) {
        final accepted = await _sharingService.acceptShare(
          publicPayload.token,
          linkSecretKey: publicPayload.linkSecretKey,
        );
        await _syncToCloud();
        await loadShares();
        return accepted;
      }

      // Fallback to the Type 3 (recipient-specific) path.
      final token = _sharingService.parseShareLink(url);
      if (token == null) {
        throw SharingException('Invalid share link');
      }

      final accepted = await _sharingService.acceptShare(token);

      await _syncToCloud();
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
      // v8: match the bucket FAMILY so a v8-native share is found whether the
      // caller passes the legacy category or the `-v8` sibling (display-only).
      BucketVersionResolver.sameFamily(s.bucket, bucket) &&
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
