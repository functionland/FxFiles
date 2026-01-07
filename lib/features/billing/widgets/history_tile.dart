import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/billing/billing_models.dart';

class HistoryTile extends StatelessWidget {
  final CreditHistoryEntry entry;
  final VoidCallback? onTap;

  const HistoryTile({
    super.key,
    required this.entry,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isCredit = entry.txType.isCredit;
    final color = isCredit ? const Color(0xFF06B597) : Colors.red;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withOpacity(0.1),
        child: Icon(
          _getIcon(),
          color: color,
          size: 20,
        ),
      ),
      title: Text(
        entry.txType.displayName,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
      ),
      subtitle: Text(
        _formatDate(entry.createdAt),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            entry.formattedAmount,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
          ),
          Text(
            'Balance: ${entry.balanceAfter.toStringAsFixed(2)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  IconData _getIcon() {
    switch (entry.txType) {
      case CreditTransactionType.deposit:
        return LucideIcons.arrowDownCircle;
      case CreditTransactionType.purchase:
        return LucideIcons.plus;
      case CreditTransactionType.usage:
        return LucideIcons.minus;
      case CreditTransactionType.withdrawal:
        return LucideIcons.arrowUpCircle;
      case CreditTransactionType.refund:
        return LucideIcons.rotateCcw;
      case CreditTransactionType.bonus:
        return LucideIcons.gift;
      case CreditTransactionType.adjustment:
        return LucideIcons.settings2;
      case CreditTransactionType.unknown:
        return LucideIcons.helpCircle;
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      if (difference.inHours == 0) {
        return '${difference.inMinutes}m ago';
      }
      return '${difference.inHours}h ago';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return DateFormat('MMM d, y').format(date);
    }
  }
}
