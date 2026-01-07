import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/billing/billing_models.dart';

class CreditStatsCard extends StatelessWidget {
  final StorageInfo? storageInfo;

  const CreditStatsCard({
    super.key,
    this.storageInfo,
  });

  @override
  Widget build(BuildContext context) {
    final info = storageInfo;

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.wallet,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Credits & Storage',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (info != null) ...[
              // Balance
              _buildStatRow(
                context,
                icon: LucideIcons.coins,
                label: 'Balance',
                value: '${info.balanceFula.toStringAsFixed(2)} FULA',
                color: const Color(0xFF06B597),
              ),
              const SizedBox(height: 12),
              // Storage usage
              _buildStatRow(
                context,
                icon: LucideIcons.hardDrive,
                label: 'Storage Used',
                value: '${info.formattedCurrentStorage} / ${info.formattedTotalStorage}',
                color: info.isLowStorage ? Colors.orange : null,
              ),
              const SizedBox(height: 8),
              // Storage progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: info.usagePercentage,
                  backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(
                    info.isLowStorage
                        ? Colors.orange
                        : Theme.of(context).colorScheme.primary,
                  ),
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${info.formattedRemainingStorage} remaining',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: info.isLowStorage
                          ? Colors.orange
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              if (info.isLowStorage) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.alertTriangle,
                        size: 14,
                        color: Colors.orange,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Low storage - add credits to continue uploading',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.orange,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ] else ...[
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    Color? color,
  }) {
    return Row(
      children: [
        Icon(
          icon,
          size: 18,
          color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const Spacer(),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: color,
              ),
        ),
      ],
    );
  }
}
