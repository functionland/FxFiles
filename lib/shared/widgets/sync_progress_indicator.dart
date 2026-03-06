import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/upload_progress_manager.dart';
import 'package:fula_files/features/sync/providers/upload_progress_provider.dart';

/// A widget that displays sync status with animated progress indicator.
/// Uses its own Consumer to properly watch progress updates and animate smoothly.
///
/// For non-syncing states, prefer [SyncProgressIndicator.icon] to avoid
/// creating a StatefulWidget with an AnimationController unnecessarily.
class SyncProgressIndicator extends ConsumerStatefulWidget {
  final SyncStatus status;
  final String? localPath;
  final double size;
  final bool showPercentage;

  const SyncProgressIndicator({
    super.key,
    required this.status,
    this.localPath,
    this.size = 14,
    this.showPercentage = true,
  });

  /// Returns a simple Icon for non-syncing states, avoiding the overhead of
  /// a StatefulWidget with AnimationController. Returns null for syncing status
  /// (use the full widget for that).
  static Widget? icon(SyncStatus status, {double size = 14}) {
    switch (status) {
      case SyncStatus.notSynced:
        return Icon(LucideIcons.cloud, size: size, color: Colors.grey.shade400);
      case SyncStatus.synced:
        return Icon(LucideIcons.checkCircle, size: size, color: Colors.green);
      case SyncStatus.error:
        return Icon(LucideIcons.cloudOff, size: size, color: Colors.red);
      case SyncStatus.syncing:
        return null;
    }
  }

  @override
  ConsumerState<SyncProgressIndicator> createState() => _SyncProgressIndicatorState();
}

class _SyncProgressIndicatorState extends ConsumerState<SyncProgressIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  double _currentProgress = 0;
  double _targetProgress = 0;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(() {
        setState(() {
          _currentProgress = _animationController.value * _targetProgress +
              (1 - _animationController.value) * _currentProgress;
        });
      });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _updateProgress(double newProgress) {
    if ((newProgress - _targetProgress).abs() > 0.5) {
      _targetProgress = newProgress;
      _animationController.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (widget.status) {
      case SyncStatus.notSynced:
        return Icon(LucideIcons.cloud, size: widget.size, color: Colors.grey.shade400);

      case SyncStatus.syncing:
        return _buildSyncingIndicator();

      case SyncStatus.synced:
        return Icon(LucideIcons.checkCircle, size: widget.size, color: Colors.green);

      case SyncStatus.error:
        return Icon(LucideIcons.cloudOff, size: widget.size, color: Colors.red);
    }
  }

  Widget _buildSyncingIndicator() {
    if (widget.localPath == null) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const CircularProgressIndicator(strokeWidth: 2),
      );
    }

    // Watch the batch progress to trigger rebuilds
    final batchProgress = ref.watch(uploadProgressProvider);

    // Get progress data
    double progressValue = 0;
    int percentage = 0;

    // Check for actual bytes-based progress from SyncService
    final syncProgress = SyncService.instance.activeSync[widget.localPath];
    if (syncProgress != null && syncProgress.totalBytes > 0) {
      progressValue = syncProgress.bytesTransferred / syncProgress.totalBytes;
      percentage = (progressValue * 100).round();
    } else {
      // Fallback to time-based progress
      final progressState = UploadProgressManager.instance.getFileProgress(widget.localPath!);
      if (progressState != null) {
        progressValue = progressState.percentage / 100;
        percentage = progressState.percentage.round();
      }
    }

    // Also check batch progress for file count based estimate
    if (percentage == 0 && batchProgress != null && batchProgress.totalFiles > 0) {
      // Use batch percentage as fallback
      percentage = batchProgress.percentage.round();
      progressValue = batchProgress.percentage / 100;
    }

    // Update animation target
    if (percentage > 0) {
      _updateProgress(percentage.toDouble());
    }

    final displayPercentage = _currentProgress > 0 ? _currentProgress.round() : percentage;
    final displayProgress = _currentProgress > 0 ? _currentProgress / 100 : progressValue;

    final progressIndicator = SizedBox(
      width: widget.size,
      height: widget.size,
      child: CircularProgressIndicator(
        value: displayProgress > 0 ? displayProgress.clamp(0.0, 1.0) : null,
        strokeWidth: 2,
      ),
    );

    if (!widget.showPercentage) {
      return progressIndicator;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        progressIndicator,
        const SizedBox(width: 4),
        Text(
          '$displayPercentage%',
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: Colors.blue,
          ),
        ),
      ],
    );
  }
}
