import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/services/master_health_service.dart';

/// Thin status banner that listens to [MasterHealthService] and renders
/// only when the master gateway is unreachable. Hidden when health is
/// [MasterHealthState.online] so it costs zero vertical space in the
/// happy path.
class MasterHealthBanner extends StatelessWidget {
  const MasterHealthBanner({
    super.key,
    this.staleBucketList = false,
    this.bucketsFetchedAt,
  });

  /// When true, augments the offline message with "(bucket list may be
  /// stale)". Pass from the Cloud Files screens after a fallback read.
  final bool staleBucketList;

  /// When [staleBucketList] is true, this is rendered as a long-press
  /// tooltip ("Last refreshed N min ago") so users can judge how out-of-date
  /// the list is without cluttering the banner itself.
  final DateTime? bucketsFetchedAt;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: MasterHealthService.instance,
      builder: (context, _) {
        final state = MasterHealthService.instance.state;
        if (state == MasterHealthState.online && !staleBucketList) {
          return const SizedBox.shrink();
        }

        final theme = Theme.of(context);
        final ({Color bg, Color fg, IconData icon, String text}) style;
        if (state == MasterHealthState.severelyDegraded) {
          style = (
            bg: theme.colorScheme.errorContainer,
            fg: theme.colorScheme.onErrorContainer,
            icon: LucideIcons.shieldAlert,
            text: 'Cloud unreachable — files outside your local cache cannot be opened.',
          );
        } else if (state == MasterHealthState.offline) {
          style = (
            bg: const Color(0xFFFFF3CD),
            fg: const Color(0xFF664D03),
            icon: LucideIcons.cloudOff,
            text: staleBucketList
                ? 'Offline — showing cached bucket list. Recently-fetched files still open.'
                : 'Offline — showing cached files. Recent uploads may be missing.',
          );
        } else {
          // online + staleBucketList → mild "stale" notice without alarm.
          style = (
            bg: theme.colorScheme.surfaceContainerHigh,
            fg: theme.colorScheme.onSurfaceVariant,
            icon: LucideIcons.history,
            text: 'Bucket list is from cache — pull to refresh.',
          );
        }

        Widget banner = Material(
          color: style.bg,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(style.icon, size: 16, color: style.fg),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    style.text,
                    style: TextStyle(color: style.fg, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        );

        if (staleBucketList && bucketsFetchedAt != null) {
          banner = Tooltip(
            message: 'Last refreshed ${_relativeTime(bucketsFetchedAt!)}',
            triggerMode: TooltipTriggerMode.longPress,
            showDuration: const Duration(seconds: 3),
            child: banner,
          );
        }

        return banner;
      },
    );
  }

  static String _relativeTime(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inSeconds < 60) return 'less than a minute ago';
    if (diff.inMinutes < 60) {
      final n = diff.inMinutes;
      return '$n ${n == 1 ? 'minute' : 'minutes'} ago';
    }
    if (diff.inHours < 24) {
      final n = diff.inHours;
      return '$n ${n == 1 ? 'hour' : 'hours'} ago';
    }
    final n = diff.inDays;
    return '$n ${n == 1 ? 'day' : 'days'} ago';
  }
}
