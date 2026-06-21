import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/features/ai_connections/providers/ai_activity_provider.dart';

/// P16 — "AI activity": what the AI assistants you've connected have stored.
///
/// COLLECTIVE by design. Every AI connection writes to the SAME encrypted AI
/// workspace (all connections derive one shared workspace secret), so this list
/// is across ALL your AI connections together — a file CANNOT be traced to one
/// specific connection. The header states this plainly so the collective scope
/// is never mistaken for per-connection attribution.
///
/// GATED: when the user has no AI connection the screen shows a distinct
/// "no AI connections" state and never reads the workspace, so non-AI users see
/// nothing meaningful here.
class AiActivityScreen extends ConsumerWidget {
  const AiActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(aiActivityProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI activity'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.refreshCw),
            tooltip: 'Refresh',
            onPressed: state.isBusy
                ? null
                : () => ref.read(aiActivityProvider.notifier).load(),
          ),
        ],
      ),
      body: _buildBody(context, ref, state),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AiActivityState state,
  ) {
    if (state.isBusy && state.objects.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null) {
      return _CenteredMessage(
        icon: LucideIcons.alertTriangle,
        iconColor: Colors.orange,
        title: "Couldn't load AI activity",
        body: state.error!,
        onRetry: () => ref.read(aiActivityProvider.notifier).load(),
      );
    }

    // Gated: no AI connection → nothing to show, and we never read the workspace.
    if (!state.hasConnection) {
      return const _CenteredMessage(
        icon: LucideIcons.bot,
        title: 'No AI connections',
        body: 'Connect an AI client first. Anything it stores in your shared AI '
            'workspace will show up here.',
      );
    }

    return Column(
      children: [
        const _CollectiveHeader(),
        if (state.objects.isEmpty)
          const Expanded(
            child: _CenteredMessage(
              icon: LucideIcons.folderOpen,
              title: 'Nothing stored yet',
              body: 'Your connected AI assistants have not stored anything in '
                  'the shared AI workspace yet.',
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              itemCount: state.objects.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final o = state.objects[i];
                return ListTile(
                  leading: const Icon(LucideIcons.fileText),
                  title: Text(o.key),
                  subtitle: Text(_subtitle(o)),
                );
              },
            ),
          ),
      ],
    );
  }

  static String _subtitle(FulaObject o) {
    final size = o.sizeFormatted;
    final when = o.lastModified;
    if (when == null) return size;
    return '$size · ${_formatDateTime(when)}';
  }

  static String _formatDateTime(DateTime d) {
    final local = d.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$day $hh:$mm';
  }
}

/// The load-bearing honesty header: states the list is COLLECTIVE across all AI
/// connections with NO per-connection attribution.
class _CollectiveHeader extends StatelessWidget {
  const _CollectiveHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.info,
              size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'These files were created by AI assistants you’ve connected, '
              'stored in your shared AI workspace. This list is collective '
              'across all your AI connections — a file can’t be traced to one '
              'specific connection.',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// A simple centered icon + title + body, with an optional Retry button. Used
/// for the loading-error, no-connection, and empty states.
class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.iconColor,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color? iconColor;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 48,
                color: iconColor ?? Theme.of(context).disabledColor),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              body,
              style: const TextStyle(fontSize: 13),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(LucideIcons.refreshCw, size: 16),
                label: const Text('Retry'),
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
