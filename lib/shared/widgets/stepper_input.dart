import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fula_files/app/theme/app_colors.dart';

class StepperInput extends StatelessWidget {
  final int value;
  final int min;
  final int? max;
  final int step;
  final String? suffix;
  final bool wide;
  final ValueChanged<int> onChanged;

  const StepperInput({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 1,
    this.max,
    this.step = 1,
    this.suffix,
    this.wide = false,
  });

  Future<void> _editValue(BuildContext context) async {
    final controller = TextEditingController(text: value.toString());
    final newValue = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Enter value'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            suffixText: suffix,
          ),
          onSubmitted: (v) {
            final parsed = int.tryParse(v);
            Navigator.of(ctx).pop(parsed);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = int.tryParse(controller.text);
              Navigator.of(ctx).pop(parsed);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newValue != null) {
      var v = newValue;
      if (v < min) v = min;
      if (max != null && v > max!) v = max!;
      onChanged(v);
    }
  }

  void _inc() {
    final next = value + step;
    if (max != null && next > max!) return;
    onChanged(next);
  }

  void _dec() {
    final next = value - step;
    if (next < min) return;
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dividerColor = theme.dividerColor.withValues(alpha: 0.6);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: dividerColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _circleBtn(context, '−', _dec),
          InkWell(
            onTap: () => _editValue(context),
            child: Container(
              constraints: BoxConstraints(minWidth: wide ? 70 : 44),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppColors.primary.withValues(alpha: 0.6)),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '$value',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (suffix != null) ...[
                    const SizedBox(width: 4),
                    Text(
                      suffix!,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          _circleBtn(context, '+', _inc),
        ],
      ),
    );
  }

  Widget _circleBtn(BuildContext context, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        width: 30,
        height: 30,
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
