import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/models/upload_progress.dart';
import 'package:fula_files/core/services/upload_progress_manager.dart';

/// State for upload progress tracking in the UI.
class UploadProgressNotifier extends Notifier<BatchUploadProgress?> {
  StreamSubscription<BatchUploadProgress?>? _subscription;

  @override
  BatchUploadProgress? build() {
    // Subscribe to progress updates from the manager
    _subscription = UploadProgressManager.instance.progressStream.listen((progress) {
      state = progress;
    });

    // Clean up on dispose
    ref.onDispose(() {
      _subscription?.cancel();
    });

    // Return current state immediately
    return UploadProgressManager.instance.batchProgress;
  }
}

/// Provider for batch upload progress.
/// Returns null when no batch is active.
final uploadProgressProvider = NotifierProvider<UploadProgressNotifier, BatchUploadProgress?>(() {
  return UploadProgressNotifier();
});

/// Provider for individual file upload progress.
/// Returns null if the file is not currently being uploaded.
final fileUploadProgressProvider = Provider.family<UploadProgressState?, String>((ref, localPath) {
  // Watch the batch progress to trigger rebuilds
  ref.watch(uploadProgressProvider);

  return UploadProgressManager.instance.getFileProgress(localPath);
});

/// Provider for checking if any uploads are active.
final hasActiveUploadsProvider = Provider<bool>((ref) {
  final progress = ref.watch(uploadProgressProvider);
  return progress?.hasActiveUploads ?? false;
});

/// Provider for overall upload percentage (0-100).
final uploadPercentageProvider = Provider<double>((ref) {
  final progress = ref.watch(uploadProgressProvider);
  return progress?.percentage ?? 0;
});

/// Provider for formatted ETA string.
final uploadETAProvider = Provider<String?>((ref) {
  final progress = ref.watch(uploadProgressProvider);
  if (progress == null || !progress.hasActiveUploads) return null;
  return progress.formattedETA;
});

/// Provider for notification summary string.
final uploadNotificationSummaryProvider = Provider<String?>((ref) {
  final progress = ref.watch(uploadProgressProvider);
  if (progress == null) return null;
  return progress.notificationSummary;
});
