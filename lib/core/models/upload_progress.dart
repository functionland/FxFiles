/// State for a single file upload progress.
class UploadProgressState {
  /// Local file path being uploaded
  final String localPath;

  /// Remote key (destination path)
  final String remoteKey;

  /// File name for display
  final String fileName;

  /// Total bytes to upload
  final int totalBytes;

  /// Real cumulative bytes uploaded so far, when the SDK reports it
  /// (chunked uploads). `null` means fall back to the time-based estimate —
  /// small/non-chunked uploads emit no per-chunk progress events.
  final int? bytesUploaded;

  /// When the upload started
  final DateTime startedAt;

  /// Estimated duration based on speed tracking
  final Duration estimatedDuration;

  /// Pause duration (if upload was paused)
  final Duration pauseDuration;

  /// Whether the upload is paused
  final bool isPaused;

  const UploadProgressState({
    required this.localPath,
    required this.remoteKey,
    required this.fileName,
    required this.totalBytes,
    this.bytesUploaded,
    required this.startedAt,
    required this.estimatedDuration,
    this.pauseDuration = Duration.zero,
    this.isPaused = false,
  });

  /// Elapsed time since upload started (excluding pause time).
  Duration get elapsed {
    if (isPaused) {
      return pauseDuration;
    }
    return DateTime.now().difference(startedAt) - pauseDuration;
  }

  /// Progress percentage (0-100), capped at 99% until actually complete.
  ///
  /// Prefers REAL cumulative bytes (`bytesUploaded`) reported by the SDK for
  /// chunked uploads; falls back to the time-based estimate when the SDK
  /// reports nothing (small/non-chunked uploads). Either way it's capped at
  /// 99% until `completeUpload` removes the entry — the SDK's cumulative
  /// bytes reach `total` when the last chunk's PUT returns, before the index
  /// PUT + forest-flush tail finishes.
  double get percentage {
    final bytes = bytesUploaded;
    if (bytes != null && totalBytes > 0) {
      return ((bytes / totalBytes) * 100).clamp(0, 99);
    }
    if (estimatedDuration.inMilliseconds <= 0) return 0;
    final progress = (elapsed.inMilliseconds / estimatedDuration.inMilliseconds) * 100;
    return progress.clamp(0, 99); // Cap at 99% until confirmed complete
  }

  /// Estimated time remaining.
  Duration get estimatedTimeRemaining {
    final remaining = estimatedDuration - elapsed;
    if (remaining.isNegative) {
      // Upload is overdue - show small amount remaining
      return const Duration(seconds: 5);
    }
    return remaining;
  }

  /// Formatted ETA string (e.g., "2m 30s", "1h 5m").
  String get formattedETA {
    final remaining = estimatedTimeRemaining;
    if (remaining.inHours > 0) {
      return '${remaining.inHours}h ${remaining.inMinutes.remainder(60)}m';
    }
    if (remaining.inMinutes > 0) {
      return '${remaining.inMinutes}m ${remaining.inSeconds.remainder(60)}s';
    }
    return '${remaining.inSeconds}s';
  }

  /// Formatted progress string (e.g., "45%").
  String get formattedPercentage => '${percentage.round()}%';

  UploadProgressState copyWith({
    String? localPath,
    String? remoteKey,
    String? fileName,
    int? totalBytes,
    int? bytesUploaded,
    DateTime? startedAt,
    Duration? estimatedDuration,
    Duration? pauseDuration,
    bool? isPaused,
  }) {
    return UploadProgressState(
      localPath: localPath ?? this.localPath,
      remoteKey: remoteKey ?? this.remoteKey,
      fileName: fileName ?? this.fileName,
      totalBytes: totalBytes ?? this.totalBytes,
      bytesUploaded: bytesUploaded ?? this.bytesUploaded,
      startedAt: startedAt ?? this.startedAt,
      estimatedDuration: estimatedDuration ?? this.estimatedDuration,
      pauseDuration: pauseDuration ?? this.pauseDuration,
      isPaused: isPaused ?? this.isPaused,
    );
  }
}

/// Aggregate progress state for a batch of uploads.
class BatchUploadProgress {
  /// Total number of files in the batch
  final int totalFiles;

  /// Number of files completed
  final int completedFiles;

  /// Number of files that failed
  final int failedFiles;

  /// Total bytes across all files
  final int totalBytes;

  /// Bytes uploaded so far (based on completed files)
  final int completedBytes;

  /// When the batch started
  final DateTime startedAt;

  /// Currently uploading files
  final List<UploadProgressState> activeUploads;

  /// Estimated total duration for the batch
  final Duration estimatedTotalDuration;

  const BatchUploadProgress({
    required this.totalFiles,
    required this.completedFiles,
    this.failedFiles = 0,
    required this.totalBytes,
    required this.completedBytes,
    required this.startedAt,
    required this.activeUploads,
    required this.estimatedTotalDuration,
  });

  /// Number of files remaining (including in-progress)
  int get remainingFiles => totalFiles - completedFiles - failedFiles;

  /// Whether there are any active uploads
  bool get hasActiveUploads => activeUploads.isNotEmpty;

  /// File progress string (e.g., "3/10 files")
  String get fileProgressString => '$completedFiles/$totalFiles files';

  /// Overall percentage (0-100)
  double get percentage {
    if (totalBytes <= 0) {
      // Fallback to file count based progress
      if (totalFiles <= 0) return 0;
      return (completedFiles / totalFiles) * 100;
    }

    // Calculate completed percentage from finished files
    final completedPct = (completedBytes / totalBytes) * 100;

    // Add weighted progress from active uploads
    double activeProgress = 0;
    for (final upload in activeUploads) {
      final uploadWeight = upload.totalBytes / totalBytes;
      activeProgress += uploadWeight * upload.percentage;
    }

    final total = completedPct + activeProgress;
    return total.clamp(0, 99); // Cap at 99% until batch complete
  }

  /// Formatted overall percentage
  String get formattedPercentage => '${percentage.round()}%';

  /// Overall elapsed time
  Duration get elapsed => DateTime.now().difference(startedAt);

  /// Estimated remaining time for entire batch
  Duration get estimatedTimeRemaining {
    if (estimatedTotalDuration.inMilliseconds <= 0) {
      return Duration.zero;
    }

    final remaining = estimatedTotalDuration - elapsed;
    if (remaining.isNegative) {
      // Estimate based on current progress rate
      final pct = percentage;
      if (pct > 0) {
        final totalEstimate = elapsed.inMilliseconds / (pct / 100);
        final newRemaining = Duration(
          milliseconds: totalEstimate.round() - elapsed.inMilliseconds,
        );
        return newRemaining.isNegative ? const Duration(seconds: 10) : newRemaining;
      }
      return const Duration(seconds: 30);
    }
    return remaining;
  }

  /// Formatted ETA for entire batch
  String get formattedETA {
    final remaining = estimatedTimeRemaining;
    if (remaining.inHours > 0) {
      return '${remaining.inHours}h ${remaining.inMinutes.remainder(60)}m';
    }
    if (remaining.inMinutes > 0) {
      return '${remaining.inMinutes}m ${remaining.inSeconds.remainder(60)}s';
    }
    return '${remaining.inSeconds}s';
  }

  /// Notification-friendly summary (e.g., "3/10 files (45%) - 2m 30s remaining")
  String get notificationSummary {
    final parts = <String>[
      fileProgressString,
      '($formattedPercentage)',
    ];

    if (estimatedTimeRemaining.inSeconds > 0) {
      parts.add('- $formattedETA remaining');
    }

    return parts.join(' ');
  }

  /// Current file being uploaded (for display)
  String? get currentFileName {
    if (activeUploads.isEmpty) return null;
    return activeUploads.first.fileName;
  }

  BatchUploadProgress copyWith({
    int? totalFiles,
    int? completedFiles,
    int? failedFiles,
    int? totalBytes,
    int? completedBytes,
    DateTime? startedAt,
    List<UploadProgressState>? activeUploads,
    Duration? estimatedTotalDuration,
  }) {
    return BatchUploadProgress(
      totalFiles: totalFiles ?? this.totalFiles,
      completedFiles: completedFiles ?? this.completedFiles,
      failedFiles: failedFiles ?? this.failedFiles,
      totalBytes: totalBytes ?? this.totalBytes,
      completedBytes: completedBytes ?? this.completedBytes,
      startedAt: startedAt ?? this.startedAt,
      activeUploads: activeUploads ?? this.activeUploads,
      estimatedTotalDuration: estimatedTotalDuration ?? this.estimatedTotalDuration,
    );
  }
}
