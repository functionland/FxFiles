import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/shared/legal/terms_content.dart';
import 'package:fula_files/shared/widgets/beta_upload_dialog.dart';
import 'package:fula_files/shared/widgets/ipfs_public_disclaimer_dialog.dart';

/// Pumps a button that opens [open] and records what the dialog returned.
Future<List<Object?>> _host(
  WidgetTester tester,
  Future<Object?> Function(BuildContext) open,
) async {
  final results = <Object?>[];
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async => results.add(await open(context)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

FilledButton _agree(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Agree'));

/// Tick a box the way a user would: the dialog scrolls on a small window, so
/// bring the box into view first.
Future<void> _tick(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pump();
}

void main() {
  group('beta upload dialog', () {
    testWidgets('Agree stays disabled until the acknowledgement is ticked',
        (tester) async {
      final results = await _host(tester, (c) => showBetaUploadDialog(c));

      expect(find.text(kBetaUploadAcknowledgement), findsOneWidget);
      expect(_agree(tester).onPressed, isNull);

      await _tick(tester, kBetaUploadAcknowledgement);
      expect(_agree(tester).onPressed, isNotNull);

      await tester.tap(find.text('Agree'));
      await tester.pumpAndSettle();
      expect(results, [true]);
    });

    testWidgets('Cancel means no upload', (tester) async {
      final results = await _host(tester, (c) => showBetaUploadDialog(c));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(results, [false]);
    });

    testWidgets('the barrier does not dismiss it', (tester) async {
      final results = await _host(tester, (c) => showBetaUploadDialog(c));
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text(kBetaUploadAcknowledgement), findsOneWidget);
      expect(results, isEmpty);
    });
  });

  group('generation disclaimer', () {
    testWidgets('needs BOTH the terms box and the beta box', (tester) async {
      final results =
          await _host(tester, (c) => showIpfsPublicDisclaimerDialog(c));

      expect(find.text(kBetaGenerateAcknowledgement), findsOneWidget);
      expect(_agree(tester).onPressed, isNull);

      await _tick(tester, 'I understand and accept these terms');
      expect(_agree(tester).onPressed, isNull,
          reason: 'the terms box alone must not be enough');

      await _tick(tester, kBetaGenerateAcknowledgement);
      expect(_agree(tester).onPressed, isNotNull);

      await tester.tap(find.text('Agree'));
      await tester.pumpAndSettle();
      expect(results, [true]);
    });

    testWidgets('the beta box alone is not enough either', (tester) async {
      await _host(tester, (c) => showIpfsPublicDisclaimerDialog(c));
      await _tick(tester, kBetaGenerateAcknowledgement);
      expect(_agree(tester).onPressed, isNull);
    });

    testWidgets('a caller publishing a user file shows the upload wording',
        (tester) async {
      await _host(
        tester,
        (c) => showIpfsPublicDisclaimerDialog(
          c,
          betaAcknowledgement: kBetaUploadAcknowledgement,
        ),
      );
      expect(find.text(kBetaUploadAcknowledgement), findsOneWidget);
      expect(find.text(kBetaGenerateAcknowledgement), findsNothing);
    });

    testWidgets('the social variant carries the beta box too', (tester) async {
      await _host(
        tester,
        (c) => showIpfsPublicDisclaimerDialog(
          c,
          variant: PublicDisclaimerVariant.social,
        ),
      );
      expect(find.text(kBetaGenerateAcknowledgement), findsOneWidget);
    });
  });
}
