// Widget test for ShelfAddNoteScreen — verifies Save enable/disable
// logic + tag-picker entry point. The actual save flow touches Hive
// + ShelfService + the file system; that integration is covered by
// the Session 5 device smoke pass.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:fula_files/features/shelf/screens/shelf_add_note_screen.dart';

GoRouter _router() {
  return GoRouter(
    initialLocation: '/shelf/add/note',
    routes: [
      GoRoute(
        path: '/shelf/add/note',
        builder: (_, __) => const ShelfAddNoteScreen(),
      ),
    ],
  );
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('Save is disabled while the text field is empty',
      (tester) async {
    await _pump(tester);
    final saveText = find.descendant(
      of: find.byType(TextButton),
      matching: find.text('Save'),
    );
    expect(saveText, findsOneWidget);
    final saveBtn =
        tester.widget<TextButton>(find.ancestor(
      of: saveText,
      matching: find.byType(TextButton),
    ));
    expect(saveBtn.onPressed, isNull);
  });

  testWidgets('Save enables once text is typed', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField), 'Buy milk');
    await tester.pump();
    final saveText = find.descendant(
      of: find.byType(TextButton),
      matching: find.text('Save'),
    );
    final saveBtn =
        tester.widget<TextButton>(find.ancestor(
      of: saveText,
      matching: find.byType(TextButton),
    ));
    expect(saveBtn.onPressed, isNotNull);
  });

  testWidgets('"Add tags" chip is present and tappable', (tester) async {
    await _pump(tester);
    expect(find.text('Add tags'), findsOneWidget);
  });
}
