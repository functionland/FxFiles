// ⚠️ MOVED — disclaimer dialog now lives at
// `lib/shared/widgets/legal_disclaimer_dialog.dart` (shared between the
// hidden AI feature and the active Automate feature) and was renamed
// from `showAiAutomationDisclaimer` → `showBulkSendDisclaimer` (the
// generic name applies to both). This file is kept as a re-export so
// any stale imports still resolve.
// See: C:\Users\ehsan\.claude\plans\now-i-need-a-keen-kahan.md

import 'package:flutter/material.dart';
import 'package:fula_files/shared/widgets/legal_disclaimer_dialog.dart';

export 'package:fula_files/shared/widgets/legal_disclaimer_dialog.dart';

/// Back-compat alias. Prefer `showBulkSendDisclaimer` directly.
Future<bool> showAiAutomationDisclaimer(BuildContext context) =>
    showBulkSendDisclaimer(context);
