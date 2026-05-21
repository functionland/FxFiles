import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/services/tutorial_service.dart';

class CreateSection extends StatelessWidget {
  final bool isWebsiteEnabled;
  final bool isNftEnabled;

  /// ⚠️ HIDDEN — AI feature is paused. The on-device LLM (Llama 3.2 1B
  /// Q4_K_M) works but was overkill for the CRM-bulk-send use case;
  /// the "Automate" tile delivers the same outcome deterministically
  /// (no model download, no fllama, no 1 GB RAM headroom requirement).
  /// To re-enable: have `home_screen.dart` pass `isAiEnabled: true`
  /// and verify the AI source tree (`lib/features/ai_tasks/`,
  /// `ai_model_service.dart`, `local_llm_service.dart`, etc.) still
  /// builds. Plan: C:\Users\ehsan\.claude\plans\now-i-need-a-keen-kahan.md
  final bool isAiEnabled;

  /// Called when the user taps a locked tile. Home wires this to open the
  /// setup unlock sheet (§3).
  final VoidCallback? onLockedTap;

  const CreateSection({
    super.key,
    required this.isWebsiteEnabled,
    required this.isNftEnabled,
    this.isAiEnabled = false, // HIDDEN — was true while AI feature was live.
    this.onLockedTap,
  });

  @override
  Widget build(BuildContext context) {
    return TutorialShowcase(
      showcaseKey: TutorialService.instance.createKey,
      stepIndex: 4,
      targetBorderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'CREATE',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 1,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            // 2x2 grid: Website + NFT (top), Automate + Dump (bottom).
            // The Dump tile was added in the Dump feature (see plan at
            // C:\Users\ehsan\.claude\plans\i-want-to-add-buzzing-anchor.md).
            Row(
              children: [
                Expanded(
                  child: _CreateTile(
                    icon: LucideIcons.globe,
                    label: 'Website',
                    badge: isWebsiteEnabled ? 'beta' : 'needs API key',
                    locked: !isWebsiteEnabled,
                    onTap: () {
                      if (!isWebsiteEnabled) {
                        onLockedTap?.call();
                        return;
                      }
                      context.push('/websites');
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CreateTile(
                    icon: LucideIcons.gem,
                    label: 'NFT',
                    badge: isNftEnabled ? 'mint & share' : 'needs wallet',
                    locked: !isNftEnabled,
                    onTap: () {
                      if (!isNftEnabled) {
                        onLockedTap?.call();
                        return;
                      }
                      context.push('/nfts');
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _CreateTile(
                    icon: LucideIcons.zap,
                    label: 'Automate',
                    badge: 'CSV → bulk send',
                    locked: false,
                    onTap: () => context.push('/automate-tasks'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CreateTile(
                    icon: LucideIcons.inbox,
                    label: 'Dump',
                    badge: 'share to FxFiles',
                    locked: false,
                    onTap: () => context.push('/dump'),
                  ),
                ),
                // ⚠️ HIDDEN — AI tile is dormant. It was a 5th tile in the
                // earlier single-row layout; the 2x2 grid above has no
                // free slot. To re-enable: pick a layout (3x2, or replace
                // one of the existing tiles) and unhide via
                // `isAiEnabled: true` from `home_screen.dart`. The
                // /ai-tasks route in router.dart still resolves for any
                // stranded `ai-tasks-*` tags from earlier installs.
                if (isAiEnabled) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _CreateTile(
                      icon: LucideIcons.sparkles,
                      label: 'AI',
                      badge: 'on-device',
                      locked: false,
                      onTap: () => context.push('/ai-tasks'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String badge;
  final bool locked;
  final VoidCallback onTap;

  const _CreateTile({
    required this.icon,
    required this.label,
    required this.badge,
    required this.locked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = locked ? theme.colorScheme.onSurfaceVariant : AppColors.primary;
    final borderColor = theme.dividerColor.withValues(alpha: 0.4);
    return Material(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(icon, color: iconColor, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: locked
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      badge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
