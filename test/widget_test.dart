// Basic Flutter widget test for FulaFiles app.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/app/app.dart';

void main() {
  testWidgets('App launches smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(
      const ProviderScope(
        child: FulaFilesApp(),
      ),
    );

    // Verify the app launches without errors
    expect(find.byType(FulaFilesApp), findsOneWidget);
  });
}
