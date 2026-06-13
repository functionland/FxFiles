import 'package:flutter/material.dart';

import 'package:fula_files/web/services/web_upload_manager.dart';

/// Persistent, shell-level upload status surface. Mounted once above the
/// router (see app_web.dart), so it shows from every screen and survives
/// in-app navigation — the whole reason uploads were hoisted out of
/// WebBucketScreen.
///
/// Renders nothing when the queue is empty. While uploading it shows the
/// current file + progress + how many remain; when the drain finishes it
/// shows a dismissible summary (and keeps failed/skipped rows so errors
/// aren't lost).
class WebUploadTray extends StatelessWidget {
  const WebUploadTray({super.key});

  @override
  Widget build(BuildContext context) {
    final mgr = WebUploadManager.instance;
    return AnimatedBuilder(
      animation: mgr,
      builder: (context, _) {
        final jobs = mgr.jobs;
        if (jobs.isEmpty) return const SizedBox.shrink();

        final theme = Theme.of(context);
        final active = jobs.where((j) => j.isActive).toList();
        final current = mgr.current;
        final done =
            jobs.where((j) => j.status == WebUploadStatus.done).length;
        final problems = jobs
            .where((j) =>
                j.status == WebUploadStatus.failed ||
                j.status == WebUploadStatus.skipped)
            .toList();

        return SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.bottomCenter,
            // While uploading the card is display-only — let taps fall
            // through to the page (FAB / any open dialog) so this overlay
            // never steals input. Only the finished state has a control
            // (Dismiss), so it stays interactive.
            child: IgnorePointer(
              ignoring: active.isNotEmpty,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Material(
                    elevation: 6,
                    borderRadius: BorderRadius.circular(12),
                    color: theme.colorScheme.surfaceContainerHigh,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      child: active.isNotEmpty
                          ? _activeBody(theme, current, active.length, done)
                          : _finishedBody(theme, mgr, done, problems),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _activeBody(
    ThemeData theme,
    WebUploadJob? current,
    int activeCount,
    int done,
  ) {
    final name = current?.name ?? 'Preparing…';
    final pct = current?.progress;
    final remainingNote =
        activeCount > 1 ? '$activeCount files left' : 'Uploading…';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    remainingNote +
                        (pct != null
                            ? ' · ${(pct * 100).toStringAsFixed(0)}%'
                            : ''),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct, // null → indeterminate
            minHeight: 4,
          ),
        ),
      ],
    );
  }

  Widget _finishedBody(
    ThemeData theme,
    WebUploadManager mgr,
    int done,
    List<WebUploadJob> problems,
  ) {
    final hasProblems = problems.isNotEmpty;
    final headline = StringBuffer();
    if (done > 0) {
      headline.write('$done upload${done == 1 ? '' : 's'} complete');
    }
    if (hasProblems) {
      if (headline.isNotEmpty) headline.write(' · ');
      headline.write(
          '${problems.length} failed'); // failed OR skipped, both shown below
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              hasProblems ? Icons.warning_amber_rounded : Icons.check_circle,
              size: 20,
              color: hasProblems ? Colors.orange : Colors.green,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                headline.toString(),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: mgr.clearFinished,
              child: const Text('Dismiss'),
            ),
          ],
        ),
        if (hasProblems) ...[
          const SizedBox(height: 4),
          ...problems.take(4).map(
                (j) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '• ${j.name}: ${j.error ?? 'failed'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                  ),
                ),
              ),
          if (problems.length > 4)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '…and ${problems.length - 4} more',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor),
              ),
            ),
        ],
      ],
    );
  }
}
