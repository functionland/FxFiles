import 'package:flutter/material.dart';

/// Shows a legal disclaimer dialog about unencrypted public IPFS uploads.
/// Returns true if the user accepts, false/null otherwise.
Future<bool?> showLegalDisclaimerDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const _LegalDisclaimerDialog(),
  );
}

class _LegalDisclaimerDialog extends StatefulWidget {
  const _LegalDisclaimerDialog();

  @override
  State<_LegalDisclaimerDialog> createState() => _LegalDisclaimerDialogState();
}

class _LegalDisclaimerDialogState extends State<_LegalDisclaimerDialog> {
  bool _accepted = false;

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
            const Text(
              '1. Files will be uploaded WITHOUT encryption to IPFS, '
              'a public decentralized network.\n\n'
              '2. Once uploaded, files may be accessible to anyone with the '
              'content identifier (CID). They cannot be guaranteed to be deleted.\n\n'
              '3. Do NOT upload sensitive, private, or confidential files '
              '(personal documents, credentials, private photos, etc.).\n\n'
              '4. The generated website and all its assets will be publicly '
              'accessible via IPFS gateway URLs.\n\n'
              '5. You are solely responsible for the content you upload and '
              'must ensure you have the right to publish it publicly.',
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              value: _accepted,
              onChanged: (value) => setState(() => _accepted = value ?? false),
              title: const Text(
                'I understand and accept these terms',
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
