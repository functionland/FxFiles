import 'package:flutter/material.dart';

import 'package:fula_files/shared/legal/terms_content.dart';

/// Checkbox-gated beta notice shown before EVERY user-initiated upload —
/// once per action (a batch of picked or dropped files is one action), never
/// once per file. The owner chose every time over once-per-version.
///
/// Same shape as the website-generation notice
/// (showIpfsPublicDisclaimerDialog): an unticked required box, Agree disabled
/// until it is ticked, and no barrier dismissal.
///
/// Returns true only when the user ticks the box and agrees.
///
/// On the WEB, call this only AFTER the file picker has returned. A browser
/// opens a picker only from inside the user's tap, and awaiting a dialog
/// first moves the picker out of that tap — on iOS Safari it then silently
/// never opens.
Future<bool> showBetaUploadDialog(BuildContext context) async {
  final agreed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const _BetaUploadDialog(),
  );
  return agreed == true;
}

class _BetaUploadDialog extends StatefulWidget {
  const _BetaUploadDialog();

  @override
  State<_BetaUploadDialog> createState() => _BetaUploadDialogState();
}

class _BetaUploadDialogState extends State<_BetaUploadDialog> {
  bool _accepted = false;

  static const String _uploadTerms =
      '1. FxFiles is in beta testing. Uploads may fail or be delayed, and '
      'stored files may not remain accessible.\n\n'
      '2. Do NOT rely on FxFiles as your only copy. Keep your own copies of '
      'anything important.\n\n'
      '3. You are solely responsible for the files you upload and must have '
      'the right to store them.\n\n'
      '4. Any integration with the FULA token is for testing and '
      'demonstration purposes only.';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange),
          SizedBox(width: 8),
          Text('Important Notice'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'By proceeding, you acknowledge and agree to the following:',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text(_uploadTerms),
            const SizedBox(height: 16),
            CheckboxListTile(
              value: _accepted,
              onChanged: (value) => setState(() => _accepted = value ?? false),
              title: const Text(
                kBetaUploadAcknowledgement,
                style: TextStyle(fontSize: 14),
              ),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _accepted ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Agree'),
        ),
      ],
    );
  }
}
