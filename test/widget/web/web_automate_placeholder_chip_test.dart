import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/features/automate/widgets/placeholder_chip_bar.dart';

/// Regression guard for the web Automate keyboard-gap fix (#15).
///
/// The fix wraps the placeholder chip bar in `TextFieldTapRegion` +
/// `ExcludeFocus` so a chip tap doesn't unfocus the TO/Message field (on
/// mobile web that closes the soft keyboard and leaves a stale viewInsets
/// gap). The keyboard/gap behaviour itself is mobile-web-platform-specific
/// and can't be reproduced in a widget test, but the real REGRESSION RISK
/// of the change — `ExcludeFocus` swallowing the chip's tap so the
/// placeholder no longer inserts — is fully testable here.
void main() {
  testWidgets(
      'chip tap still inserts the placeholder when wrapped in '
      'TextFieldTapRegion + ExcludeFocus', (tester) async {
    final toFocus = FocusNode();
    final toCtrl = TextEditingController();
    addTearDown(() {
      toFocus.dispose();
      toCtrl.dispose();
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            TextField(focusNode: toFocus, controller: toCtrl),
            // Exactly the wrapping the web Automate screen applies.
            TextFieldTapRegion(
              child: ExcludeFocus(
                child: PlaceholderChipBar(
                  headers: const ['Name'],
                  fields: [
                    PlaceholderField(
                      focusNode: toFocus,
                      controller: toCtrl,
                      label: 'TO',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ));

    // Focus the field so the chip bar records it as the insert target
    // (its focus listener sets _lastFocused).
    toFocus.requestFocus();
    await tester.pump();

    expect(toCtrl.text, isEmpty);

    // The chip must remain tappable through ExcludeFocus and still insert.
    await tester.tap(find.text('{Name}'));
    await tester.pump();

    expect(toCtrl.text, '{Name}');
  });
}
