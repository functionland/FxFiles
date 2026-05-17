// ⚠️ HIDDEN — AI feature paused (see CreateSection's isAiEnabled gate).
// See plan: C:\Users\ehsan\.claude\plans\now-i-need-a-keen-kahan.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/services/ai_model_service.dart';
import 'package:fula_files/core/services/device_memory_service.dart';
import 'package:fula_files/features/ai_tasks/providers/ai_model_provider.dart';

/// First-run on-device model download UI. Shown at the top of the AI
/// Tasks browser screen while the model is missing or downloading. Hides
/// itself once status is `ready`.
///
/// Also handles the `unsupported` state: when the device has <2 GB RAM
/// the model is never downloaded. The card explains why and points the
/// user at the heuristic-only fallback that the feature still supports.
class ModelDownloadCard extends ConsumerWidget {
  const ModelDownloadCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final asyncEvent = ref.watch(aiModelStatusProvider);
    final event = asyncEvent.value ?? AiModelService.instance.lastEvent;
    final memSvc = DeviceMemoryService.instance;

    if (event.status == AiModelStatus.ready) {
      // On reduced-quality tiers we still show a small badge so the user
      // knows their device is running in a degraded mode.
      if (memSvc.tier == MemoryTier.low || memSvc.tier == MemoryTier.medium) {
        return const _ReducedQualityBadge();
      }
      return const SizedBox.shrink();
    }

    final color = switch (event.status) {
      AiModelStatus.error => Colors.red,
      AiModelStatus.paused => Colors.orange,
      AiModelStatus.unsupported => Colors.grey,
      _ => theme.colorScheme.primary,
    };

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  event.status == AiModelStatus.unsupported
                      ? LucideIcons.alertTriangle
                      : LucideIcons.cpu,
                  color: color,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  event.status == AiModelStatus.unsupported
                      ? 'AI parsing not available on this device'
                      : 'On-device AI model',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _statusBlurb(event, memSvc),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            if (event.status == AiModelStatus.downloading) ...[
              LinearProgressIndicator(value: event.progressFraction),
              const SizedBox(height: 4),
              Text(
                _progressLabel(event),
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: AiModelService.instance.cancelDownload,
                    icon: const Icon(LucideIcons.pause, size: 16),
                    label: const Text('Pause'),
                  ),
                ],
              ),
            ] else if (event.status == AiModelStatus.unsupported) ...[
              // No download button; the device can't host the model.
              // We still let the user use the feature via literal
              // templates, so we keep the card informational only.
            ] else
              _ControlRow(event: event),
            if (event.status != AiModelStatus.unsupported) ...[
              const SizedBox(height: 8),
              _WifiOnlyToggle(),
            ],
          ],
        ),
      ),
    );
  }

  String _statusBlurb(AiModelEvent ev, DeviceMemoryService mem) {
    switch (ev.status) {
      case AiModelStatus.notDownloaded:
        final tierBlurb = switch (mem.tier) {
          MemoryTier.low =>
            ' This device will use reduced parameters to fit its memory.',
          MemoryTier.medium => ' This device will use moderate parameters.',
          _ => '',
        };
        return 'AI tasks run on your device — no servers involved. Download '
            'the ~700 MB Llama 3.2 1B model once to enable on-device parsing.'
            '$tierBlurb';
      case AiModelStatus.downloading:
        return 'Downloading the model. Safe to leave the screen — the '
            'download continues in the background until you pause it.';
      case AiModelStatus.paused:
        return ev.errorMessage ?? 'Paused. Tap Resume when ready.';
      case AiModelStatus.error:
        return ev.errorMessage ?? 'Something went wrong. Try again.';
      case AiModelStatus.ready:
        return '';
      case AiModelStatus.unsupported:
        final ram = mem.formattedTotalRam();
        final ramHint = ram == null ? '' : ' (your device has $ram)';
        return 'On-device AI requires at least 2 GB of RAM$ramHint. '
            'The CRM Automation feature still works — just write your '
            'message using {ColumnName} placeholders matching your CSV '
            'headers (e.g. "Hello {Name}") and the app will substitute '
            'them per row.';
    }
  }

  String _progressLabel(AiModelEvent ev) {
    final dl = ev.downloadedBytes ?? 0;
    final total = ev.totalBytes ?? 0;
    if (total == 0) return '${_mb(dl)} downloaded';
    final pct = ev.progressFraction == null
        ? '?'
        : (ev.progressFraction! * 100).toStringAsFixed(1);
    return '${_mb(dl)} / ${_mb(total)} ($pct %)';
  }

  String _mb(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class _ControlRow extends StatelessWidget {
  final AiModelEvent event;
  const _ControlRow({required this.event});

  @override
  Widget build(BuildContext context) {
    final isError = event.status == AiModelStatus.error;
    final isPaused = event.status == AiModelStatus.paused;
    return Row(
      children: [
        FilledButton.icon(
          onPressed: () => AiModelService.instance.startDownload(),
          icon: Icon(
            isError || isPaused
                ? LucideIcons.refreshCw
                : LucideIcons.download,
            size: 16,
          ),
          label: Text(isError
              ? 'Retry'
              : isPaused
                  ? 'Resume'
                  : 'Download model'),
        ),
        const SizedBox(width: 8),
        if (isError || isPaused)
          TextButton(
            onPressed: () async {
              await AiModelService.instance.deleteModel();
            },
            child: const Text('Reset'),
          ),
      ],
    );
  }
}

class _WifiOnlyToggle extends StatefulWidget {
  @override
  State<_WifiOnlyToggle> createState() => _WifiOnlyToggleState();
}

class _WifiOnlyToggleState extends State<_WifiOnlyToggle> {
  late bool _wifiOnly;

  @override
  void initState() {
    super.initState();
    _wifiOnly = AiModelService.instance.wifiOnly;
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: const Text('Wi-Fi only'),
      subtitle: const Text(
        'Pauses the download when you switch to mobile data.',
      ),
      value: _wifiOnly,
      onChanged: (v) {
        setState(() => _wifiOnly = v);
        AiModelService.instance.wifiOnly = v;
      },
    );
  }
}

/// Small badge shown above the AI Tasks screens on low/medium tiers when
/// the model is ready. Hints to the user that they're running with
/// reduced parameters so output quality may differ from a flagship.
class _ReducedQualityBadge extends StatelessWidget {
  const _ReducedQualityBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mem = DeviceMemoryService.instance;
    final ram = mem.formattedTotalRam();
    final tierLabel =
        mem.tier == MemoryTier.low ? 'low-memory' : 'moderate-memory';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.gauge,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ram == null
                  ? 'Running on a $tierLabel device — using reduced AI parameters'
                  : 'Running on a $ram device — using reduced AI parameters',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
