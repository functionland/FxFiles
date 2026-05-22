// Widget tests for DumpFilterBar — chip taps update the
// `dumpFilterProvider` state, date chip surfaces selected range.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/features/dump/providers/dump_providers.dart';
import 'package:fula_files/features/dump/widgets/dump_filter_bar.dart';

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: DumpFilterBar()),
      ),
    ),
  );
}

void main() {
  testWidgets('renders the Date chip plus every DumpCategory',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(find.text('Date'), findsOneWidget);
    expect(find.text('Image'), findsOneWidget);
    expect(find.text('Screenshot'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Link'), findsOneWidget);
    expect(find.text('Note'), findsOneWidget);
    expect(find.text('Document'), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
  });

  testWidgets('tapping a category chip adds it to the filter',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pump(tester, container);

    expect(
      container.read(dumpFilterProvider).categories.contains(DumpCategory.image),
      isFalse,
    );
    await tester.tap(find.text('Image'));
    await tester.pump();
    expect(
      container.read(dumpFilterProvider).categories.contains(DumpCategory.image),
      isTrue,
    );
  });

  testWidgets('tapping a selected category removes it from the filter',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(dumpFilterProvider.notifier)
        .toggleCategory(DumpCategory.video);
    await _pump(tester, container);

    await tester.tap(find.text('Video'));
    await tester.pump();
    expect(
      container.read(dumpFilterProvider).categories.contains(DumpCategory.video),
      isFalse,
    );
  });

  testWidgets('Date chip surfaces a formatted range when set', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(dumpFilterProvider.notifier).setDateRange(
          DateTimeRange(
            start: DateTime(2026, 5, 1),
            end: DateTime(2026, 5, 10),
          ),
        );
    await _pump(tester, container);

    // The default "Date" label is replaced with a formatted range.
    expect(find.text('Date'), findsNothing);
    // The exact format depends on locale; assert that the chip body
    // contains the start month abbreviation.
    expect(find.textContaining('May'), findsAtLeastNWidgets(1));
  });
}
