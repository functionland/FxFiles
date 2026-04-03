import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/collaboration_group.dart';
import 'package:fula_files/core/services/collaboration_service.dart';
import 'package:fula_files/core/services/collab_folder_sync_service.dart';
import 'package:fula_files/core/services/cloud_collaboration_storage_service.dart';
import 'package:fula_files/shared/utils/error_messages.dart';

/// Provider for collaboration service
final collaborationServiceProvider = Provider<CollaborationService>((ref) {
  return CollaborationService.instance;
});

/// State notifier for managing collaboration groups
class CollaborationNotifier extends Notifier<CollaborationState> {
  late CollaborationService _service;

  @override
  CollaborationState build() {
    _service = CollaborationService.instance;
    Future.microtask(() => loadGroups());
    return CollaborationState.initial();
  }

  Future<void> loadGroups() async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      var outgoing = await _service.getOutgoingCollaborations();
      var accepted = await _service.getAcceptedCollaborations();

      // Auto-restore from cloud if local is empty
      if (outgoing.isEmpty) {
        try {
          final cloudCollabs =
              await CloudCollaborationStorageService.instance.downloadCollaborations();
          if (cloudCollabs.isNotEmpty) {
            await _service.importOutgoingCollaborations(cloudCollabs);
            outgoing = cloudCollabs;
          }
        } catch (_) {
          // Cloud sync is optional
        }
      }

      // Auto-restore accepted collaborations from cloud if local is empty
      if (accepted.isEmpty) {
        try {
          final cloudAccepted =
              await CloudCollaborationStorageService.instance.downloadAcceptedCollaborations();
          if (cloudAccepted.isNotEmpty) {
            await _service.importAcceptedCollaborations(cloudAccepted);
            accepted = cloudAccepted;
          }
        } catch (_) {
          // Cloud sync is optional
        }
      }

      // Ensure local data is backed up to cloud for future restores
      if (outgoing.isNotEmpty || accepted.isNotEmpty) {
        _syncToCloud();
      }

      state = state.copyWith(
        isLoading: false,
        outgoingGroups: outgoing,
        acceptedGroups: accepted,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forSync(e),
      );
    }
  }

  /// Create a new collaboration group
  Future<String?> createGroup({
    required String name,
    required List<CollabFileInput> files,
    int expiryDays = 365,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final outgoing = await _service.createGroup(
        name: name,
        files: files,
        expiryDays: expiryDays,
      );

      // Sync to cloud
      await _syncToCloud();

      // Generate link
      final link = _service.generateCollaborationLink(outgoing);

      await loadGroups();
      return link;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forSync(e),
      );
      return null;
    }
  }

  /// Add a file to an existing group
  Future<bool> addFileToGroup({
    required String groupId,
    required String pathScope,
    required String bucket,
    required String fileName,
    required int fileSize,
    String? contentType,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await _service.addFileToGroup(
        groupId: groupId,
        pathScope: pathScope,
        bucket: bucket,
        fileName: fileName,
        fileSize: fileSize,
        contentType: contentType,
      );

      await _syncToCloud();
      await loadGroups();
      return true;
    } catch (e, stack) {
      debugPrint('[CollabProvider] addFileToGroup failed: $e\n$stack');
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forSync(e),
      );
      return false;
    }
  }

  /// Accept a collaboration link
  Future<AcceptedCollaboration?> acceptCollaborationLink(String url) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final accepted = await _service.acceptCollaboration(url);
      await _syncToCloud();
      await loadGroups();
      return accepted;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forSync(e),
      );
      return null;
    }
  }

  /// Refresh a single group (re-fetch manifest to see collaborator additions)
  Future<void> refreshGroup(String groupId) async {
    try {
      await _service.refreshGroup(groupId);
      await loadGroups();
    } catch (e) {
      state = state.copyWith(error: ErrorMessages.forSync(e));
    }
  }

  /// Refresh all groups
  Future<void> refreshAllGroups() async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final allIds = [
        ...state.outgoingGroups.map((g) => g.id),
        ...state.acceptedGroups.map((g) => g.id),
      ];
      for (final id in allIds) {
        await _service.refreshGroup(id);
      }
      await loadGroups();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forSync(e),
      );
    }
  }

  /// Revoke a collaboration group
  Future<bool> revokeGroup(String groupId) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await _service.revokeGroup(groupId);
      await _syncToCloud();
      await loadGroups();
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forSync(e),
      );
      return false;
    }
  }

  /// Download a file from a collaboration group
  Future<Uint8List?> downloadFile(String groupId, CollaborationFile file) async {
    try {
      return await _service.downloadCollabFile(groupId, file);
    } catch (e) {
      debugPrint('[CollabProvider] downloadFile failed: $e');
      state = state.copyWith(error: ErrorMessages.forSync(e));
      return null;
    }
  }

  /// Generate link for an outgoing collaboration
  String? generateLink(String groupId) {
    try {
      final collab = state.outgoingGroups.firstWhere((c) => c.id == groupId);
      return _service.generateCollaborationLink(collab);
    } catch (_) {
      return null;
    }
  }

  /// Get a specific group by ID (from either outgoing or accepted)
  CollaborationGroup? getGroup(String groupId) {
    for (final c in state.outgoingGroups) {
      if (c.id == groupId) return c.group;
    }
    for (final c in state.acceptedGroups) {
      if (c.id == groupId) return c.group;
    }
    return null;
  }

  /// Check if this user owns a group
  bool isOwner(String groupId) {
    return state.outgoingGroups.any((c) => c.id == groupId);
  }

  /// Sync collaborations from cloud
  Future<void> syncFromCloud() async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final localCollabs = await _service.getOutgoingCollaborations();
      final merged = await CloudCollaborationStorageService.instance
          .syncCollaborations(localCollabs);

      if (merged.length != localCollabs.length) {
        await _service.importOutgoingCollaborations(merged);
      }

      await loadGroups();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: ErrorMessages.forSync(e),
      );
    }
  }

  Future<void> _syncToCloud() async {
    try {
      final collabs = await _service.getOutgoingCollaborations();
      await CloudCollaborationStorageService.instance.uploadCollaborations(collabs);
      final accepted = await _service.getAcceptedCollaborations();
      await CloudCollaborationStorageService.instance.uploadAcceptedCollaborations(accepted);
    } catch (_) {
      // Don't fail the operation if cloud sync fails
    }
  }

  /// Assign a local folder to a collab group and start sync
  Future<void> assignFolder(String groupId, String folderPath) async {
    try {
      await CollabFolderSyncService.instance.assignFolder(groupId, folderPath);
      await loadGroups();
    } catch (e) {
      debugPrint('[CollabProvider] assignFolder failed: $e');
      state = state.copyWith(error: ErrorMessages.forSync(e));
    }
  }

  /// Remove local folder assignment and stop sync
  Future<void> unassignFolder(String groupId) async {
    try {
      await CollabFolderSyncService.instance.unassignFolder(groupId);
      await loadGroups();
    } catch (e) {
      debugPrint('[CollabProvider] unassignFolder failed: $e');
      state = state.copyWith(error: ErrorMessages.forSync(e));
    }
  }

  /// Trigger immediate sync for a group
  Future<void> syncNow(String groupId) async {
    try {
      await CollabFolderSyncService.instance.syncNow(groupId);
      await loadGroups();
    } catch (e) {
      debugPrint('[CollabProvider] syncNow failed: $e');
      state = state.copyWith(error: ErrorMessages.forSync(e));
    }
  }

  void clearError() {
    state = state.copyWith(error: null);
  }
}

/// State for collaboration groups
class CollaborationState {
  final bool isLoading;
  final String? error;
  final List<OutgoingCollaboration> outgoingGroups;
  final List<AcceptedCollaboration> acceptedGroups;

  CollaborationState({
    required this.isLoading,
    this.error,
    required this.outgoingGroups,
    required this.acceptedGroups,
  });

  factory CollaborationState.initial() => CollaborationState(
    isLoading: false,
    outgoingGroups: [],
    acceptedGroups: [],
  );

  CollaborationState copyWith({
    bool? isLoading,
    String? error,
    List<OutgoingCollaboration>? outgoingGroups,
    List<AcceptedCollaboration>? acceptedGroups,
  }) {
    return CollaborationState(
      isLoading: isLoading ?? this.isLoading,
      error: error,
      outgoingGroups: outgoingGroups ?? this.outgoingGroups,
      acceptedGroups: acceptedGroups ?? this.acceptedGroups,
    );
  }

  /// All groups sorted by last updated (newest first)
  List<CollabGroupEntry> get allGroups {
    final entries = <CollabGroupEntry>[];
    for (final c in outgoingGroups) {
      entries.add(CollabGroupEntry(
        group: c.group,
        isOwner: true,
        updatedAt: c.group.updatedAt,
        localFolderPath: c.localFolderPath,
        syncEnabled: c.syncEnabled,
      ));
    }
    for (final c in acceptedGroups) {
      entries.add(CollabGroupEntry(
        group: c.group,
        isOwner: false,
        updatedAt: c.group.updatedAt,
        localFolderPath: c.localFolderPath,
        syncEnabled: c.syncEnabled,
      ));
    }
    entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return entries;
  }

  bool get isEmpty => outgoingGroups.isEmpty && acceptedGroups.isEmpty;
}

/// A unified entry for the collaborate tab list
class CollabGroupEntry {
  final CollaborationGroup group;
  final bool isOwner;
  final DateTime updatedAt;
  final String? localFolderPath;
  final bool syncEnabled;

  CollabGroupEntry({
    required this.group,
    required this.isOwner,
    required this.updatedAt,
    this.localFolderPath,
    this.syncEnabled = false,
  });

  String get id => group.id;
  String get name => group.name;
  int get fileCount => group.fileCount;
  bool get isValid => group.isValid;
  bool get hasFolderSync => localFolderPath != null && syncEnabled;
}

/// Provider for collaboration state
final collaborationProvider =
    NotifierProvider<CollaborationNotifier, CollaborationState>(() {
  return CollaborationNotifier();
});
