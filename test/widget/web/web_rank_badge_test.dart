import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/user_rank.dart';
import 'package:fula_files/web/widgets/web_rank_badge.dart';

/// These tests exist for one reason: the badge lives in the AppBar title,
/// and the requirement was that it must not enlarge the header, push
/// content down, or let the header texts collide on a phone. Those are
/// geometry claims, so they are asserted as geometry rather than trusted.
void main() {
  /// The header as it is actually assembled in web_home_screen.dart.
  Widget header({UserRank? rank, String title = 'FxFiles'}) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          leading: const Icon(Icons.account_circle_outlined),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(title, overflow: TextOverflow.ellipsis),
              ),
              if (rank != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: WebRankBadge(
                    rank: rank,
                    paidStorageBytes: 600 * 1024 * 1024 * 1024,
                  ),
                ),
            ],
          ),
          actions: const [
            Icon(Icons.search),
            Icon(Icons.settings_outlined),
            SizedBox(width: 4),
          ],
        ),
        body: const SizedBox.expand(key: ValueKey('body')),
      ),
    );
  }

  Future<void> setViewport(WidgetTester tester, double width) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.reset);
  }

  testWidgets('the badge does not make the header taller', (tester) async {
    await setViewport(tester, 800);

    await tester.pumpWidget(header());
    final without = tester.getSize(find.byType(AppBar)).height;

    await tester.pumpWidget(header(rank: UserRank.platinum));
    await tester.pumpAndSettle();
    final with_ = tester.getSize(find.byType(AppBar)).height;

    // Platinum is the widest AND tallest case (4 stars + label).
    expect(with_, without,
        reason: 'the rank badge changed the AppBar height');
  });

  testWidgets('the badge does not push the body down', (tester) async {
    await setViewport(tester, 800);

    await tester.pumpWidget(header());
    final bodyTopWithout =
        tester.getTopLeft(find.byKey(const ValueKey('body'))).dy;

    await tester.pumpWidget(header(rank: UserRank.platinum));
    await tester.pumpAndSettle();
    final bodyTopWith =
        tester.getTopLeft(find.byKey(const ValueKey('body'))).dy;

    expect(bodyTopWith, bodyTopWithout);
  });

  testWidgets('every tier renders its pips and stays short', (tester) async {
    await setViewport(tester, 800);
    for (final rank in UserRank.values) {
      await tester.pumpWidget(header(rank: rank));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.star_rounded), findsNWidgets(userRankStars(rank)),
          reason: '${rank.name} pip count');

      // The badge must stay under the AppBar title's own line box.
      final badgeHeight =
          tester.getSize(find.byType(WebRankBadge)).height;
      expect(badgeHeight, lessThanOrEqualTo(20),
          reason: '${rank.name} badge is ${badgeHeight}px tall');
    }
  });

  testWidgets('on a phone viewport the label drops, pips remain',
      (tester) async {
    await setViewport(tester, 360);
    await tester.pumpWidget(header(rank: UserRank.gold));
    await tester.pumpAndSettle();

    // The name is what would run into the action icons, so it goes.
    expect(find.text('Gold'), findsNothing);
    expect(find.byIcon(Icons.star_rounded), findsNWidgets(3));
  });

  testWidgets('on a wide viewport the label is shown', (tester) async {
    await setViewport(tester, 800);
    await tester.pumpWidget(header(rank: UserRank.gold));
    await tester.pumpAndSettle();

    expect(find.text('Gold'), findsOneWidget);
  });

  testWidgets('no overflow at a very narrow viewport', (tester) async {
    // A RenderFlex overflow throws in tests, so simply pumping without an
    // exception is the assertion. Platinum = the widest badge.
    await setViewport(tester, 300);
    await tester.pumpWidget(header(rank: UserRank.platinum));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long title ellipsizes instead of colliding',
      (tester) async {
    await setViewport(tester, 360);
    await tester.pumpWidget(header(
      rank: UserRank.platinum,
      title: 'A Very Long Product Name That Cannot Possibly Fit',
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The badge keeps its natural width; the title is the flexible part.
    final badge = tester.getSize(find.byType(WebRankBadge));
    expect(badge.width, greaterThan(0));
    expect(badge.height, lessThanOrEqualTo(20));
  });

  testWidgets('each tier has a distinct colour', (tester) async {
    final seen = <Color>{};
    for (final rank in UserRank.values) {
      seen.add(WebRankBadge.colorFor(rank));
    }
    expect(seen.length, UserRank.values.length,
        reason: 'two tiers share a colour and are indistinguishable');
  });
}
