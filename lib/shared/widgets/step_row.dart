import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/app/theme/app_colors.dart';

enum StepRowState { pending, active, done }

class StepRow extends StatelessWidget {
  final StepRowState state;
  final String? number;
  final String title;
  final String? subtitle;
  final String? ctaLabel;
  final VoidCallback? onTap;
  final VoidCallback? onCta;
  final Widget? expanded;
  final bool optional;

  const StepRow({
    super.key,
    required this.state,
    required this.title,
    this.number,
    this.subtitle,
    this.ctaLabel,
    this.onTap,
    this.onCta,
    this.expanded,
    this.optional = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDone = state == StepRowState.done;
    final isActive = state == StepRowState.active;

    final bg = isActive
        ? AppColors.primaryFaint
        : theme.colorScheme.surface.withValues(alpha: 0.5);
    final borderColor = isActive
        ? AppColors.primary
        : theme.dividerColor.withValues(alpha: 0.4);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: isActive ? 1.5 : 1),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Row(
                  children: [
                    _badge(isDone, isActive, number, context),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Flexible(
                                child: Text(
                                  title,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isActive
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: isDone
                                        ? theme.colorScheme.onSurfaceVariant
                                        : theme.colorScheme.onSurface,
                                    decoration: isDone
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                              ),
                              if (optional && !isDone) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    'Optional',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.4,
                                      color:
                                          theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              subtitle!,
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (ctaLabel != null && !isDone)
                      _pillButton(ctaLabel!, onCta ?? onTap),
                  ],
                ),
                if (expanded != null) ...[
                  const SizedBox(height: 12),
                  expanded!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _badge(bool done, bool active, String? n, BuildContext context) {
    final fill = done || active ? AppColors.primary : Colors.transparent;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: done || active
            ? null
            : Border.all(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                width: 1.5,
              ),
      ),
      alignment: Alignment.center,
      child: done
          ? const Icon(LucideIcons.check, color: Colors.white, size: 14)
          : Text(
              n ?? '',
              style: TextStyle(
                color: active ? Colors.white : Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
    );
  }

  Widget _pillButton(String label, VoidCallback? onTap) {
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
