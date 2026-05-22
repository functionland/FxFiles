// Widget test for DumpAddSheet — verifies the 3 actions render. We
// don't drive the actual platform pickers here (those require live
// image_picker / file_picker plugins) — those paths are exercised
// at the device-level smoke in Session 5.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/features/dump/widgets/dump_add_sheet.dart';

Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => DumpAddSheet.show(ctx),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the 3 add-action rows', (tester) async {
    await _openSheet(tester);

    expect(find.text('Add note'), findsOneWidget);
    expect(find.text('Take photo'), findsOneWidget);
    expect(find.text('Import file'), findsOneWidget);
  });

  testWidgets('Add note row uses the right subtitle hint', (tester) async {
    await _openSheet(tester);
    expect(
      find.text('Type some text — saved to your Dump'),
      findsOneWidget,
    );
  });
}
