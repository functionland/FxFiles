import 'package:flutter/material.dart';

/// What is about to be published without encryption.
enum PublicDisclaimerVariant { website, social }

/// Checkbox-gated warning that assets and the generated result will be
/// PUBLIC on IPFS. Shown before every website generation (native parity —
/// no "don't ask again") and before every social-post generation.
/// Returns true only when the user ticks the box and agrees.
///
/// Moved here from lib/features/websites/widgets/legal_disclaimer_dialog.dart
/// (which remains as a re-export shim) so the web screens can share it —
/// same move-to-shared pattern as the bulk-send disclaimer.
Future<bool?> showIpfsPublicDisclaimerDialog(
  BuildContext context, {
  PublicDisclaimerVariant variant = PublicDisclaimerVariant.website,
  /// Optional extra line rendered under the terms (e.g. the FULA price).
  String? footnote,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        _IpfsPublicDisclaimerDialog(variant: variant, footnote: footnote),
  );
}

class _IpfsPublicDisclaimerDialog extends StatefulWidget {
  final PublicDisclaimerVariant variant;
  final String? footnote;
  const _IpfsPublicDisclaimerDialog({required this.variant, this.footnote});

  @override
  State<_IpfsPublicDisclaimerDialog> createState() =>
      _IpfsPublicDisclaimerDialogState();
}

class _IpfsPublicDisclaimerDialogState
    extends State<_IpfsPublicDisclaimerDialog> {
  bool _accepted = false;

  static const String _websiteTerms =
      '1. Files will be uploaded WITHOUT encryption to IPFS, '
      'a public decentralized network.\n\n'
      '2. Once uploaded, files may be accessible to anyone with the '
      'content identifier (CID). They cannot be guaranteed to be deleted.\n\n'
      '3. Do NOT upload sensitive, private, or confidential files '
      '(personal documents, credentials, private photos, etc.).\n\n'
      '4. The generated website and all its assets will be publicly '
      'accessible via IPFS gateway URLs.\n\n'
      '5. You are solely responsible for the content you upload and '
      'must ensure you have the right to publish it publicly.';

  static const String _socialTerms =
      '1. The generated social media image will be uploaded WITHOUT '
      'encryption to IPFS, a public decentralized network.\n\n'
      '2. Your website assets used as visual references are already '
      'public; the new image will be too — anyone with the link or CID '
      'can access it, and it cannot be guaranteed to be deleted.\n\n'
      '3. The generated captions and image are meant for public posting. '
      'Review them before sharing.\n\n'
      '4. You are solely responsible for the content you generate and '
      'must ensure you have the right to publish it publicly.';

  @override
  Widget build(BuildContext context) {
    final terms = widget.variant == PublicDisclaimerVariant.website
        ? _websiteTerms
        : _socialTerms;
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
            Text(terms),
            if (widget.footnote != null) ...[
              const SizedBox(height: 12),
              Text(
                widget.footnote!,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 16),
            CheckboxListTile(
              value: _accepted,
              onChanged: (value) =>
                  setState(() => _accepted = value ?? false),
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
          onPressed:
              _accepted ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Agree'),
        ),
      ],
    );
  }
}
