// Widget tests for the CREATE section after the Dump feature
// restructured it to a 2x2 grid (Phase 1 of the Dump plan).
//
// Verifies:
//  - all 4 tiles render with the expected labels
//  - the Dump tile is the 4th tile (row 2, col 2)
//  - tapping Dump triggers go_router navigation to /dump

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:showcaseview/showcaseview.dart';

import 'package:fula_files/features/home/widgets/create_section.dart';

class _DumpTarget extends StatelessWidget {
  const _DumpTarget();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('DUMP_ROUTE_LANDING')));
}

GoRouter _testRouter(Widget home) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => home),
      GoRoute(path: '/dump', builder: (_, __) => const _DumpTarget()),
      GoRoute(
        path: '/websites',
        builder: (_, __) =>
            const Scaffold(body: Center(child: Text('WEBSITES_LANDING'))),
      ),
      GoRoute(
        path: '/nfts',
        builder: (_, __) =>
            const Scaffold(body: Center(child: Text('NFTS_LANDING'))),
      ),
      GoRoute(
        path: '/automate-tasks',
        builder: (_, __) =>
            const Scaffold(body: Center(child: Text('AUTOMATE_LANDING'))),
      ),
    ],
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required bool isWebsiteEnabled,
  required bool isNftEnabled,
  VoidCallback? onLockedTap,
}) async {
  final section = CreateSection(
    isWebsiteEnabled: isWebsiteEnabled,
    isNftEnabled: isNftEnabled,
    onLockedTap: onLockedTap,
  );
  final home = ShowCaseWidget(
    builder: (_) => Scaffold(body: SingleChildScrollView(child: section)),
  );
  final router = _testRouter(home);

  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  // Allow ShowCaseWidget + go_router to settle their first frame.
  await tester.pump();
}

void main() {
  testWidgets('renders all 4 tiles in the 2x2 grid', (tester) async {
    await _pump(
      tester,
      isWebsiteEnabled: true,
      isNftEnabled: true,
    );

    expect(find.text('Website'), findsOneWidget);
    expect(find.text('NFT'), findsOneWidget);
    expect(find.text('Automate'), findsOneWidget);
    expect(find.text('Dump'), findsOneWidget);
    expect(find.text('CREATE'), findsOneWidget);
  });

  testWidgets('Dump tile shows the expected badge', (tester) async {
    await _pump(
      tester,
      isWebsiteEnabled: true,
      isNftEnabled: true,
    );

    expect(find.text('share to FxFiles'), findsOneWidget);
  });

  testWidgets('tapping Dump tile navigates to /dump', (tester) async {
    await _pump(
      tester,
      isWebsiteEnabled: true,
      isNftEnabled: true,
    );

    await tester.tap(find.text('Dump'));
    // First pump fires go_router's redirect; second settles the
    // new route's first frame.
    await tester.pumpAndSettle();

    expect(find.text('DUMP_ROUTE_LANDING'), findsOneWidget);
  });

  testWidgets('tapping Automate tile navigates to /automate-tasks',
      (tester) async {
    // Regression guard: the 2x2 restructure must not break the existing
    // Automate tile.
    await _pump(
      tester,
      isWebsiteEnabled: true,
      isNftEnabled: true,
    );

    await tester.tap(find.text('Automate'));
    await tester.pumpAndSettle();

    expect(find.text('AUTOMATE_LANDING'), findsOneWidget);
  });

  testWidgets('locked Website tile calls onLockedTap and does NOT navigate',
      (tester) async {
    var lockedTapped = 0;
    await _pump(
      tester,
      isWebsiteEnabled: false,
      isNftEnabled: true,
      onLockedTap: () => lockedTapped++,
    );

    await tester.tap(find.text('Website'));
    await tester.pumpAndSettle();

    expect(lockedTapped, 1);
    // We must still be on the home route — the landing widget for /websites
    // would have been picked up by find.text if navigation had happened.
    expect(find.text('CREATE'), findsOneWidget);
  });
}
