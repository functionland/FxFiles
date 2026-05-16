import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Pre-run disclaimer for AI automation. The send mechanism uses each
/// target app's documented click-to-chat / mailto / sms URL scheme — the
/// user still taps Send inside the target app for every message. Surface
/// that here so nobody expects auto-send.
///
/// Returns `true` when the user confirms; `false` (or null) otherwise.
Future<bool> showAiAutomationDisclaimer(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AlertDialog(
        icon: const Icon(LucideIcons.alertCircle,
            size: 40, color: Colors.amber),
        title: const Text('Before you run this task'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Bullet(
                'FxFiles opens the target app (WhatsApp / Telegram / '
                'Messages / Mail) for each recipient with the message '
                'pre-filled. You tap Send inside the target app — '
                'we do NOT auto-send on your behalf.',
              ),
              _Bullet(
                'This is the only mechanism the app stores allow for '
                'messaging-app integration. Bulk messaging through '
                'unofficial means (Accessibility Service auto-tap, '
                'unofficial WhatsApp APIs) can get your account banned '
                'and would violate the relevant terms of service.',
              ),
              _Bullet(
                'Use sensibly. Per WhatsApp\'s click-to-chat docs '
                '(wa.me), sending unsolicited bulk messages can result '
                'in your number being flagged or banned.',
              ),
              _Bullet(
                'AI parsing runs entirely on this device. No row data '
                'leaves your phone / computer.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('I understand, continue'),
          ),
        ],
      );
    },
  );
  return result == true;
}

class _Bullet extends StatelessWidget {
  final String text;
  final TextStyle? style;
  const _Bullet(this.text, {this.style});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6, right: 8),
            child: Icon(Icons.circle, size: 6),
          ),
          Expanded(
            child: Text(
              text,
              style: style ?? Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
