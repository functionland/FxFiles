import 'package:flutter/material.dart';

import 'package:fula_files/web/screens/web_signin_screen.dart';

/// The web login, presented as a CANCELABLE bottom sheet over the (logged-out)
/// home — mirrors the native app's auto-open setup sheet. It hosts the existing
/// [WebSignInScreen] in `asSheet` mode (one login UI, reused — no duplicated
/// auth logic). Dismissing it (scrim tap, drag-down, or "Maybe later") is the
/// "cancel"; the sign-in screen pops the sheet itself once sign-in completes.
///
/// `show` resolves when the sheet closes for ANY reason; the caller decides
/// what happened by re-checking `WebSession.isSignedIn` (still signed-out ⇒ the
/// user cancelled).
class WebLoginSheet {
  WebLoginSheet._();

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      // Dismissible by scrim/drag — that IS the user's "cancel".
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        return Padding(
          // Keep content above the keyboard (Mode B password / Mode C restore
          // text fields) when it opens inside the sheet.
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: ConstrainedBox(
            // Cap the height so the home stays partly visible behind the sheet
            // ("see what you're logging into") and the body scrolls internally.
            constraints: BoxConstraints(
              maxHeight: media.size.height * 0.85,
              maxWidth: 640,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const WebSignInScreen(asSheet: true),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).maybePop(),
                      child: const Text('Maybe later'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
