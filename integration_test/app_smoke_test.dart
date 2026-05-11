// Baseline integration test.
//
// Run with: `flutter test integration_test/` (against a connected
// device — e.g. the moto g85 5G or the Windows desktop).
//
// This is intentionally a thin "the app boots" smoke test. As
// scenarios grow real integration coverage, add per-scenario files
// in `integration_test/scenarios/*.dart` and import the helpers
// from `test/helpers/` (yes — that folder is reachable from both
// test/ and integration_test/ via relative paths because it's
// pure Dart with no test-package dependencies that would conflict).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fula_files/app/app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app launches on device without throwing', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: FulaFilesApp()));
    expect(find.byType(FulaFilesApp), findsOneWidget);
  });
}
