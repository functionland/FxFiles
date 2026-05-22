// Widget tests for DumpScreen — empty / populated / search / filtered
// empty / tile-tap navigation.
//
// To stay decoupled from Hive's stream lifecycle (which under
// `flutter test` on this SDK build doesn't cleanly tear down inside
// the test-completion window), `dumpItemsProvider` is overridden
// directly. The storage layer is exercised by its own unit tests.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/features/dump/providers/dump_providers.dart';
import 'package:fula_files/features/dump/screens/dump_screen.dart';

class _NavSpy extends StatelessWidget {
  final String tag;
  const _NavSpy({required this.tag});
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('NAV:$tag')));
}

DumpItem _item({
  required String id,
  String originalName = 'photo.jpg',
  DumpCategory category = DumpCategory.image,
  DumpUploadStatus uploadStatus = DumpUploadStatus.uploaded,
  String? autoTitle,
  String? autoDescription,
  DateTime? receivedAt,
}) {
  return DumpItem(
    id: id,
    receivedAt: receivedAt ?? DateTime.utc(2026, 5, 21, 12, 0),
    originalName: originalName,
    mimeType: 'image/jpeg',
    sizeBytes: 1024,
    localCachePath: '/tmp/$id',
    category: category,
    uploadStatus: uploadStatus,
    contentSha: 'sha-$id',
    autoTitle: autoTitle,
    autoDescription: autoDescription,
  );
}

GoRouter _router() {
  return GoRouter(
    initialLocation: '/dump',
    routes: [
      GoRoute(path: '/dump', builder: (_, __) => const DumpScreen()),
      GoRoute(
        path: '/dump/:id',
        builder: (_, state) =>
            _NavSpy(tag: 'item-${state.pathParameters['id']}'),
      ),
    ],
  );
}

Future<void> pump(
  WidgetTester tester, {
  List<DumpItem> items = const <DumpItem>[],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dumpItemsProvider.overrideWith(
          (ref) => Stream<List<DumpItem>>.value(items),
        ),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  // Two extra pumps drain the Stream microtask + let the router
  // build the route's first frame.
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows empty state when no items', (tester) async {
    await pump(tester);
    expect(find.text('No dumps yet'), findsOneWidget);
    expect(
      find.textContaining('Share content from any app'),
      findsOneWidget,
    );
  });

  testWidgets('populated grid renders every item', (tester) async {
    await pump(tester, items: [
      _item(id: 'a', autoTitle: 'First'),
      _item(id: 'b', autoTitle: 'Second'),
    ]);
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('tapping a tile pushes /dump/:id', (tester) async {
    await pump(tester, items: [
      _item(id: 'tap-target', autoTitle: 'Tap me'),
    ]);

    await tester.tap(find.text('Tap me'));
    await tester.pumpAndSettle();
    expect(find.text('NAV:item-tap-target'), findsOneWidget);
  });

  testWidgets('search icon opens a search TextField; close X clears it',
      (tester) async {
    await pump(tester);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.byTooltip('Close search'));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('search query (after debounce) filters the grid',
      (tester) async {
    await pump(tester, items: [
      _item(id: 'a', autoTitle: 'Sunset photo', autoDescription: 'sky, dusk'),
      _item(id: 'b', autoTitle: 'Receipt scan', autoDescription: 'text, paper'),
    ]);

    expect(find.text('Sunset photo'), findsOneWidget);
    expect(find.text('Receipt scan'), findsOneWidget);

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'receipt');
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();

    expect(find.text('Sunset photo'), findsNothing);
    expect(find.text('Receipt scan'), findsOneWidget);
  });

  testWidgets('filter-empty state shows a "Clear filters" button',
      (tester) async {
    await pump(tester, items: [_item(id: 'a', autoTitle: 'A')]);

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'xyz-no-match');
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();

    expect(find.text('No matches'), findsOneWidget);
    expect(find.text('Clear filters'), findsOneWidget);
  });
}
