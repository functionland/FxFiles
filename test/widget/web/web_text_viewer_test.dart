import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/web/widgets/web_text_viewer.dart';

/// Widget tests for the web inline text/code viewer (#19). The pure logic is
/// covered in test/unit/web/web_text_viewer_logic_test.dart; this exercises
/// the StatefulWidget — in particular the HIGH-severity path Codex flagged:
/// toggling wrap while a search match is active must NOT trip a
/// ScrollController "used in multiple positions" assertion (the fix is two
/// separate controllers, one per mode). VM-testable because the widget takes
/// an `onDownload` callback instead of importing the browser-only web_save.
void main() {
  Uint8List sample(int lines) => Uint8List.fromList(
        utf8.encode([for (var i = 0; i < lines; i++) 'line $i alpha'].join('\n')),
      );

  Widget host(Widget child) => MaterialApp(home: child);

  testWidgets('renders title, line count and content', (tester) async {
    await tester.pumpWidget(host(WebTextViewer(
      fileName: 'sample.dart',
      bytes: sample(100),
      onDownload: () {},
    )));
    expect(find.text('sample.dart'), findsOneWidget);
    expect(find.textContaining('100 lines'), findsOneWidget);
    expect(find.textContaining('line 0 alpha'), findsWidgets);
  });

  testWidgets('download button invokes the callback', (tester) async {
    var calls = 0;
    await tester.pumpWidget(host(WebTextViewer(
      fileName: 'a.txt',
      bytes: sample(3),
      onDownload: () => calls++,
    )));
    await tester.tap(find.byTooltip('Download'));
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('search shows a match counter', (tester) async {
    await tester.pumpWidget(host(WebTextViewer(
      fileName: 'a.dart',
      bytes: sample(10),
      onDownload: () {},
    )));
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pumpAndSettle();
    // All 10 lines contain "alpha".
    expect(find.text('1/10'), findsOneWidget);
  });

  testWidgets(
      'toggling wrap during an active search does not throw (HIGH: scroll controllers)',
      (tester) async {
    await tester.pumpWidget(host(WebTextViewer(
      fileName: 'a.dart',
      bytes: sample(60),
      onDownload: () {},
    )));
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pumpAndSettle();

    // Wrap OFF (settings → Wrap text) while a match is active — this is the
    // rebuild that, with a shared controller, would attach it to a second
    // ListView and assert.
    await tester.tap(find.byIcon(LucideIcons.settings2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wrap text'));
    await tester.pumpAndSettle();

    // Wrap back ON.
    await tester.tap(find.byIcon(LucideIcons.settings2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wrap text'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
