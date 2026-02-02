import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:fula_files/core/models/upload_progress.dart';
import 'package:fula_files/core/services/upload_speed_tracker.dart';

/// Callback for progress updates
typedef ProgressCallback = void Function(BatchUploadProgress? progress);

/// Manages upload progress tracking across the app.
/// Provides time-based progress estimation and batch tracking.
class UploadProgressManager {
  UploadProgressManager._();
  static final UploadProgressManager instance = UploadProgressManager._();

  /// Active uploads by local path
  final Map<String, UploadProgressState> _activeUploads = {};

  /// Batch tracking
  int _batchTotalFiles = 0;
  int _batchCompletedFiles = 0;
  int _batchFailedFiles = 0;
  int _batchTotalBytes = 0;
  int _batchCompletedBytes = 0;
  DateTime? _batchStartedAt;
  Duration _estimatedTotalDuration = Duration.zero;

  /// Progress update listeners
  final List<ProgressCallback> _listeners = [];

  /// Timer for periodic UI updates
  Timer? _updateTimer;

  /// Update interval for UI refresh
  static const Duration updateInterval = Duration(milliseconds: 500);

  /// Whether a batch is currently active
  bool get hasBatch => _batchStartedAt != null && _batchTotalFiles > 0;

  /// Get progress for a specific file
  UploadProgressState? getFileProgress(String localPath) {
    return _activeUploads[localPath];
  }

  /// Get current batch progress (null if no batch active)
  BatchUploadProgress? get batchProgress {
    if (!hasBatch) return null;

    return BatchUploadProgress(
      totalFiles: _batchTotalFiles,
      completedFiles: _batchCompletedFiles,
      failedFiles: _batchFailedFiles,
      totalBytes: _batchTotalBytes,
      completedBytes: _batchCompletedBytes,
      startedAt: _batchStartedAt!,
      activeUploads: _activeUploads.values.toList(),
      estimatedTotalDuration: _estimatedTotalDuration,
    );
  }

  /// Add a progress listener
  void addListener(ProgressCallback callback) {
    _listeners.add(callback);
  }

  /// Remove a progress listener
  void removeListener(ProgressCallback callback) {
    _listeners.remove(callback);
  }

  /// Start tracking a new batch of uploads.
  /// Call this before starting to process an upload queue.
  void startBatch({
    required int totalFiles,
    required int totalBytes,
  }) {
    debugPrint('UploadProgressManager: Starting batch of $totalFiles files (${_formatBytes(totalBytes)})');

    _batchTotalFiles = totalFiles;
    _batchCompletedFiles = 0;
    _batchFailedFiles = 0;
    _batchTotalBytes = totalBytes;
    _batchCompletedBytes = 0;
    _batchStartedAt = DateTime.now();
    _activeUploads.clear();

    // Estimate total duration based on speed tracker
    _estimatedTotalDuration = UploadSpeedTracker.instance.estimateDuration(totalBytes);
    debugPrint('UploadProgressManager: Estimated total duration: ${_estimatedTotalDuration.inSeconds}s');

    _startUpdateTimer();
    _notifyListeners();
  }

  /// Update batch totals when files are added to the queue mid-batch.
  void updateBatchTotals({
    required int additionalFiles,
    required int additionalBytes,
  }) {
    if (!hasBatch) return;

    _batchTotalFiles += additionalFiles;
    _batchTotalBytes += additionalBytes;

    // Re-estimate based on remaining bytes
    final remainingBytes = _batchTotalBytes - _batchCompletedBytes;
    final elapsedDuration = DateTime.now().difference(_batchStartedAt!);
    final remainingDuration = UploadSpeedTracker.instance.estimateDuration(remainingBytes);
    _estimatedTotalDuration = elapsedDuration + remainingDuration;

    _notifyListeners();
  }

  /// Start tracking an individual upload within the batch.
  void startUpload({
    required String localPath,
    required String remoteKey,
    required int totalBytes,
  }) {
    // Create batch if none exists (for single file uploads)
    if (!hasBatch) {
      startBatch(totalFiles: 1, totalBytes: totalBytes);
    }

    final fileName = localPath.split('/').last;
    final estimatedDuration = UploadSpeedTracker.instance.estimateDuration(totalBytes);

    _activeUploads[localPath] = UploadProgressState(
      localPath: localPath,
      remoteKey: remoteKey,
      fileName: fileName,
      totalBytes: totalBytes,
      startedAt: DateTime.now(),
      estimatedDuration: estimatedDuration,
    );

    debugPrint('UploadProgressManager: Started upload $fileName (${_formatBytes(totalBytes)}, est. ${estimatedDuration.inSeconds}s)');
    _notifyListeners();
  }

  /// Mark an upload as complete and record speed for future estimates.
  void completeUpload({
    required String localPath,
    required Duration actualDuration,
  }) {
    final upload = _activeUploads.remove(localPath);
    if (upload == null) {
      debugPrint('UploadProgressManager: completeUpload called for unknown path: $localPath');
      return;
    }

    // Record speed sample for future estimates
    UploadSpeedTracker.instance.recordUpload(upload.totalBytes, actualDuration);

    // Update batch progress
    _batchCompletedFiles++;
    _batchCompletedBytes += upload.totalBytes;

    // Recalibrate remaining time estimate based on actual speed
    _recalibrateEstimate();

    debugPrint('UploadProgressManager: Completed ${upload.fileName} in ${actualDuration.inSeconds}s ($_batchCompletedFiles/$_batchTotalFiles)');
    _notifyListeners();

    // Check if batch is complete
    if (_batchCompletedFiles + _batchFailedFiles >= _batchTotalFiles) {
      _endBatch();
    }
  }

  /// Mark an upload as failed.
  void failUpload(String localPath) {
    final upload = _activeUploads.remove(localPath);
    if (upload == null) return;

    _batchFailedFiles++;

    debugPrint('UploadProgressManager: Failed ${upload.fileName} ($_batchFailedFiles failures)');
    _notifyListeners();

    // Check if batch is complete
    if (_batchCompletedFiles + _batchFailedFiles >= _batchTotalFiles) {
      _endBatch();
    }
  }

  /// Pause an upload (e.g., due to network loss).
  void pauseUpload(String localPath) {
    final upload = _activeUploads[localPath];
    if (upload == null || upload.isPaused) return;

    _activeUploads[localPath] = upload.copyWith(
      isPaused: true,
      pauseDuration: upload.elapsed,
    );
    _notifyListeners();
  }

  /// Resume a paused upload.
  void resumeUpload(String localPath) {
    final upload = _activeUploads[localPath];
    if (upload == null || !upload.isPaused) return;

    // Adjust start time to account for pause
    _activeUploads[localPath] = upload.copyWith(
      isPaused: false,
      startedAt: DateTime.now().subtract(upload.pauseDuration),
    );
    _notifyListeners();
  }

  /// Recalibrate batch estimate based on actual upload speeds.
  void _recalibrateEstimate() {
    if (!hasBatch || _batchCompletedFiles == 0) return;

    final remainingBytes = _batchTotalBytes - _batchCompletedBytes;
    if (remainingBytes <= 0) return;

    // Estimate remaining duration based on updated speed tracker
    final remainingDuration = UploadSpeedTracker.instance.estimateDuration(remainingBytes);
    final elapsed = DateTime.now().difference(_batchStartedAt!);
    _estimatedTotalDuration = elapsed + remainingDuration;
  }

  void _endBatch() {
    debugPrint('UploadProgressManager: Batch complete - $_batchCompletedFiles succeeded, $_batchFailedFiles failed');
    _stopUpdateTimer();

    // Keep batch info for a moment so UI can show completion
    Future.delayed(const Duration(seconds: 2), () {
      if (_batchCompletedFiles + _batchFailedFiles >= _batchTotalFiles) {
        _batchStartedAt = null;
        _activeUploads.clear();
        _notifyListeners();
      }
    });
  }

  void _startUpdateTimer() {
    _stopUpdateTimer();
    _updateTimer = Timer.periodic(updateInterval, (_) {
      _notifyListeners();
    });
  }

  void _stopUpdateTimer() {
    _updateTimer?.cancel();
    _updateTimer = null;
  }

  void _notifyListeners() {
    final progress = batchProgress;
    for (final listener in _listeners) {
      try {
        listener(progress);
      } catch (e) {
        debugPrint('UploadProgressManager: Listener error: $e');
      }
    }
  }

  /// Cancel all tracking and reset state.
  void reset() {
    _stopUpdateTimer();
    _activeUploads.clear();
    _batchTotalFiles = 0;
    _batchCompletedFiles = 0;
    _batchFailedFiles = 0;
    _batchTotalBytes = 0;
    _batchCompletedBytes = 0;
    _batchStartedAt = null;
    _estimatedTotalDuration = Duration.zero;
    _notifyListeners();
  }

  /// Create a stream of batch progress updates.
  Stream<BatchUploadProgress?> get progressStream {
    late StreamController<BatchUploadProgress?> controller;
    ProgressCallback? callback;

    controller = StreamController<BatchUploadProgress?>(
      onListen: () {
        callback = (progress) => controller.add(progress);
        addListener(callback!);
        // Emit current state immediately
        controller.add(batchProgress);
      },
      onCancel: () {
        if (callback != null) {
          removeListener(callback!);
        }
      },
    );

    return controller.stream;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
