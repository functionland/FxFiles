import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/core/models/messaging_target.dart';
import 'package:fula_files/core/services/installed_apps_service.dart';
import 'package:fula_files/core/utils/target_uri_builder.dart';

/// Horizontal row of cards — one per supported [TargetApp]. Apps not
/// installed on this device are greyed out, with an "Install" link that
/// jumps to the relevant store. Shared by the hidden AI feature and the
/// active Automate feature.
class TargetAppPicker extends StatefulWidget {
  final TargetApp selected;
  final ValueChanged<TargetApp> onSelected;

  const TargetAppPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  @override
  State<TargetAppPicker> createState() => _TargetAppPickerState();
}

class _TargetAppPickerState extends State<TargetAppPicker> {
  Set<TargetApp>? _installed;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final set = await InstalledAppsService.instance.detect();
    if (!mounted) return;
    setState(() => _installed = set);
  }

  @override
  Widget build(BuildContext context) {
    final installed = _installed;
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemBuilder: (_, i) {
          final target = TargetApp.values[i];
          final available = installed?.contains(target) ?? false;
          final probing = installed == null;
          return _TargetCard(
            target: target,
            selected: widget.selected == target,
            available: probing || available,
            onTap: () {
              if (!probing && !available) {
                _promptInstall(target);
                return;
              }
              widget.onSelected(target);
            },
          );
        },
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemCount: TargetApp.values.length,
      ),
    );
  }

  Future<void> _promptInstall(TargetApp target) async {
    final url = InstalledAppsService.instance.installStoreUrl(target);
    if (url == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${TargetUriBuilder.label(target)} not installed'),
        content: Text(
          '${TargetUriBuilder.label(target)} doesn\'t appear to be installed '
          'on this device. Open its store page to install?',
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open store'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final launched = await launchUrl(Uri.parse(url),
        mode: LaunchMode.externalApplication);
    if (!launched) {
      messenger.showSnackBar(SnackBar(
        content: Text('Could not open store URL for '
            '${TargetUriBuilder.label(target)}.'),
      ));
    }
    InstalledAppsService.instance.invalidate();
    _probe();
  }
}

class _TargetCard extends StatelessWidget {
  final TargetApp target;
  final bool selected;
  final bool available;
  final VoidCallback onTap;

  const _TargetCard({
    required this.target,
    required this.selected,
    required this.available,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = !available;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 100,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.dividerColor.withValues(alpha: 0.5),
            width: selected ? 2 : 1,
          ),
          color: selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
              : theme.cardColor,
        ),
        child: Opacity(
          opacity: dim ? 0.5 : 1.0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_iconFor(target),
                  size: 28,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 6),
              Text(
                TargetUriBuilder.label(target),
                style: theme.textTheme.labelMedium,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (dim)
                Text(
                  'Install',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(TargetApp t) {
    switch (t) {
      case TargetApp.whatsapp:
        return LucideIcons.messageCircle;
      case TargetApp.telegram:
        return LucideIcons.send;
      case TargetApp.sms:
        return LucideIcons.messageSquare;
      case TargetApp.email:
        return LucideIcons.mail;
    }
  }
}
