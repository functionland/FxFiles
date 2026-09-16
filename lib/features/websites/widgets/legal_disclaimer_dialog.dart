// ⚠️ MOVED — the public-IPFS disclaimer now lives at
// `lib/shared/widgets/ipfs_public_disclaimer_dialog.dart` (shared between
// the native websites screens and the web app, which shows it before both
// website and social-post generation). This shim keeps existing imports
// working.

import 'package:flutter/material.dart';

import 'package:fula_files/shared/legal/terms_content.dart';
import 'package:fula_files/shared/widgets/ipfs_public_disclaimer_dialog.dart';

export 'package:fula_files/shared/legal/terms_content.dart'
    show kBetaGenerateAcknowledgement, kBetaUploadAcknowledgement;
export 'package:fula_files/shared/widgets/ipfs_public_disclaimer_dialog.dart';

/// Back-compat alias. Prefer `showIpfsPublicDisclaimerDialog` directly.
Future<bool?> showLegalDisclaimerDialog(
  BuildContext context, {
  String betaAcknowledgement = kBetaGenerateAcknowledgement,
}) =>
    showIpfsPublicDisclaimerDialog(
      context,
      variant: PublicDisclaimerVariant.website,
      betaAcknowledgement: betaAcknowledgement,
    );
