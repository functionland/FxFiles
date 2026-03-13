import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/whatsapp_backup_service.dart';

class BackupProgressSheet extends StatefulWidget {
  final VoidCallback? onCancel;

  const BackupProgressSheet({super.key, this.onCancel});

  @override
  State<BackupProgressSheet> createState() => _BackupProgressSheetState();
}

class _BackupProgressSheetState extends State<BackupProgressSheet> {
  BackupProgress _progress = const BackupProgress();
  StreamSubscription<BackupProgress>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = WhatsAppBackupService.instance.progressStream.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(LucideIcons.upload),
              const SizedBox(width: 8),
              Text('Backing up...', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _progress.fraction),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${_progress.completedFiles} / ${_progress.totalFiles} files',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                _formatSize(_progress.completedBytes),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          if (_progress.currentFile != null) ...[
            const SizedBox(height: 4),
            Text(
              _progress.currentFile!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          if (widget.onCancel != null)
            OutlinedButton(
              onPressed: widget.onCancel,
              child: const Text('Cancel'),
            ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
