import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/shared/legal/terms_content.dart';
import 'package:fula_files/shared/widgets/terms_of_service_view.dart';

FilledButton _accept(WidgetTester tester) => tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, 'I Accept the Terms of Service'));

void main() {
  testWidgets('Accept unlocks only after reading to the end', (tester) async {
    var accepted = 0;
    await tester.pumpWidget(MaterialApp(
      home: TermsAcceptanceScreen(onAccept: () async => accepted++),
    ));
    await tester.pump();

    expect(find.text('Terms of Service'), findsOneWidget);
    expect(_accept(tester).onPressed, isNull);

    await tester.dragUntilVisible(
      find.text('Last updated: $kTermsLastUpdated'),
      find.byType(SingleChildScrollView),
      const Offset(0, -400),
    );
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(_accept(tester).onPressed, isNotNull);

    await tester.tap(find.text('I Accept the Terms of Service'));
    await tester.pumpAndSettle();
    expect(accepted, 1);
  });

  testWidgets('shows the new beta section', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TermsOfServicePage()));
    await tester.dragUntilVisible(
      find.text('2. Beta Software and FULA Token'),
      find.byType(SingleChildScrollView),
      const Offset(0, -200),
    );
    expect(find.text('2. Beta Software and FULA Token'), findsOneWidget);
  });

  // A window tall enough to show everything never scrolls: the button must
  // not stay disabled for good.
  testWidgets('a window that shows everything unlocks without scrolling',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 40000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: TermsAcceptanceScreen(onAccept: () async {}),
    ));
    await tester.pumpAndSettle();
    expect(_accept(tester).onPressed, isNotNull);
  });

  testWidgets('an update is labelled as one', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: TermsAcceptanceScreen(isUpdate: true, onAccept: () async {}),
    ));
    expect(find.text('Updated Terms of Service'), findsOneWidget);
  });
}
