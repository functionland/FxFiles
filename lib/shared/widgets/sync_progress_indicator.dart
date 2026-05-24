import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/features/sync/providers/upload_progress_provider.dart';

/// A widget that displays sync status.
///
/// **UX**: just three icons — not-synced cloud, indeterminate spinner while
/// syncing, green checkmark when synced (red cloud-off on error). The
/// in-app row deliberately does not show a percentage; see
/// [_buildSyncingIndicator] for why.
///
/// For non-syncing states, prefer [SyncProgressIndicator.icon] to skip the
/// ConsumerStatefulWidget overhead and just return a stateless icon.
class SyncProgressIndicator extends ConsumerStatefulWidget {
  final SyncStatus status;
  final String? localPath;
  final double size;

  /// Kept for backward compatibility with existing call sites that pass
  /// `showPercentage: false`. The widget no longer renders a percentage
  /// in either state (see [_buildSyncingIndicator]); this field is a
  /// no-op now. Remove only when all call sites have been updated.
  final bool showPercentage;

  const SyncProgressIndicator({
    super.key,
    required this.status,
    this.localPath,
    this.size = 14,
    this.showPercentage = true,
  });

  /// Returns a simple Icon for non-syncing states, avoiding the overhead of
  /// a StatefulWidget unnecessarily. Returns null for syncing status (use
  /// the full widget for that — it needs the Riverpod watch to rebuild
  /// when a peer file's sync state changes).
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

class _SyncProgressIndicatorState extends ConsumerState<SyncProgressIndicator> {
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
    // Watch the batch progress to drive rebuilds when uploads tick.
    // The result isn't read directly — the watch itself is what re-runs
    // the build when the provider fires (e.g., when a peer file flips
    // syncing → synced).
    ref.watch(uploadProgressProvider);

    // Always show an indeterminate spinner while syncing.
    //
    // Why no percentage:
    //
    //  - The resumable SDK path (`uploadLargeFileResumable`, used by
    //    every upload since FxFiles 0.6.1's Phase C wireup) fires
    //    `onProgress` EXACTLY ONCE — at completion, with
    //    `bytesUploaded == totalBytes`
    //    (see `fula_api_service.dart:1010-1015`). There is no streaming
    //    byte-level progress to render mid-upload. A percentage display
    //    would just show "0%" the entire time and then flip to the
    //    green checkmark.
    //
    //  - When the upload runs in the SyncForegroundService isolate
    //    (app backgrounded with a pending upload), the main isolate's
    //    `SyncService.activeSync` and `UploadProgressManager` see
    //    nothing — Dart isolates don't share heap. Live progress lives
    //    in the foreground notification, not in-app.
    //
    // Both cases collapse to the same UX: indeterminate spinner while
    // syncing, green checkmark on completion, red cloud-off on error.
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: const CircularProgressIndicator(strokeWidth: 2),
    );
  }
}
