import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/app/theme/app_colors.dart';

/// [error] is used by progress checklists where a step can fail (e.g. the
/// website-generation card). Consumers that only ever move forward — like
/// `setup_unlock_sheet.dart` — simply never produce it.
enum StepRowState { pending, active, done, error }

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

  /// Draw the filled, outlined card around the row.
  ///
  /// True suits `setup_unlock_sheet`, where each row IS a tappable action.
  /// Set false for a pure PROGRESS list: there the boxes read as buttons
  /// and invite a tap that does nothing.
  final bool bordered;

  /// Compact scale for nested rows (the generation passes under
  /// "Generate site"): smaller badge and type, tighter padding.
  final bool dense;

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
    this.bordered = true,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDone = state == StepRowState.done;
    final isActive = state == StepRowState.active;
    final isError = state == StepRowState.error;

    // A failed step must read as failed, not as pending: without this branch
    // the new `error` variant would fall through to the pending styling and
    // look like work that simply hasn't started.
    final bg = isError
        ? AppColors.errorFaint
        : isActive
            ? AppColors.primaryFaint
            : theme.colorScheme.surface.withValues(alpha: 0.5);
    final borderColor = isError
        ? AppColors.errorBorder
        : isActive
            ? AppColors.primary
            : theme.dividerColor.withValues(alpha: 0.4);

    return Container(
      decoration: bordered
          ? BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: borderColor, width: isActive ? 1.5 : 1),
            )
          : null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: bordered
                ? const EdgeInsets.all(14)
                : EdgeInsets.symmetric(vertical: dense ? 3 : 5),
            child: Column(
              children: [
                Row(
                  children: [
                    _badge(isDone, isActive, isError, number, context),
                    SizedBox(width: dense ? 8 : 12),
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
                                    fontSize: dense ? 12 : 13,
                                    fontWeight: isActive || isError
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: isError
                                        ? AppColors.error
                                        : isDone
                                            ? theme
                                                .colorScheme.onSurfaceVariant
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
                                color: isError
                                    ? AppColors.error
                                    : theme.colorScheme.onSurfaceVariant,
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

  Widget _badge(
      bool done, bool active, bool error, String? n, BuildContext context) {
    final fill = error
        ? AppColors.error
        : done || active
            ? AppColors.primary
            : Colors.transparent;
    final size = dense ? 16.0 : 24.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: done || active || error
            ? null
            : Border.all(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                width: 1.5,
              ),
      ),
      alignment: Alignment.center,
      child: error
          ? Icon(LucideIcons.x,
              color: Colors.white, size: dense ? 10 : 14)
          : done
              ? Icon(LucideIcons.check,
                  color: Colors.white, size: dense ? 10 : 14)
              : Text(
                  n ?? '',
                  style: TextStyle(
                    color: active
                        ? Colors.white
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: dense ? 9 : 12,
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
