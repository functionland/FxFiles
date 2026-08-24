import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/user_rank.dart';
import 'package:fula_files/web/widgets/web_rank_badge.dart';

/// These tests exist for two reasons.
///
/// 1. The badge lives in the AppBar title, and the requirement was that
///    it must not enlarge the header, push content down, or let the
///    header texts collide on a phone. Those are geometry claims, so
///    they are asserted as geometry rather than trusted.
/// 2. The hint has to be reachable on TOUCH. Desktop gets it on hover
///    for free; Tooltip's default touch trigger is a long press, which
///    nobody discovers — so tap-to-hint is pinned down here.
void main() {
  /// The header as it is actually assembled in web_home_screen.dart:
  /// the rank sits BELOW the profile avatar in the leading slot, not in
  /// the title.
  Widget header({
    UserRank? rank,
    String title = 'FxFiles',
    int paidStorageBytes = 600 * 1024 * 1024 * 1024,
    double leadingWidth = 132,
  }) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          leadingWidth: rank == null ? 56 : leadingWidth,
          leading: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const CircleAvatar(radius: 12),
                  const SizedBox(height: 2),
                  if (rank != null)
                    WebRankBadge(
                      rank: rank,
                      paidStorageBytes: paidStorageBytes,
                    ),
                ],
              ),
            ),
          ),
          title: Text(title, overflow: TextOverflow.ellipsis),
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

  testWidgets('every tier renders its pips and fits the toolbar',
      (tester) async {
    await setViewport(tester, 800);
    for (final rank in UserRank.values) {
      await tester.pumpWidget(header(rank: rank));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.star_rounded), findsNWidgets(userRankStars(rank)),
          reason: '${rank.name} pip count');

      // The badge must fit inside the fixed 56px toolbar. The stronger
      // claim — that it changes nothing — is asserted by the AppBar
      // height and body-offset tests above.
      final badgeHeight = tester.getSize(find.byType(WebRankBadge)).height;
      expect(badgeHeight, lessThanOrEqualTo(kToolbarHeight),
          reason: '${rank.name} badge is ${badgeHeight}px tall');
    }
  });

  testWidgets('the tap target is bigger than the glyph row', (tester) async {
    await setViewport(tester, 360);
    await tester.pumpWidget(header(rank: UserRank.gold));
    await tester.pumpAndSettle();

    // The glyph row is ~13px; without a padded hit area this is not
    // tappable, which would make tap-to-hint useless. Capped at 28 by
    // the 56px toolbar budget it shares with the avatar above it.
    final size = tester.getSize(find.byType(WebRankBadge));
    expect(size.height, greaterThanOrEqualTo(28));
  });

  testWidgets('avatar + badge together fit the fixed toolbar',
      (tester) async {
    await setViewport(tester, 800);
    await tester.pumpWidget(header(rank: UserRank.platinum));
    await tester.pumpAndSettle();

    // The whole reason the avatar is radius 12 and the badge target is
    // 28: the stacked column must not exceed the toolbar, or the header
    // grows.
    final avatar = tester.getRect(find.byType(CircleAvatar));
    final badge = tester.getRect(find.byType(WebRankBadge));
    final columnHeight = badge.bottom - avatar.top;
    expect(columnHeight, lessThanOrEqualTo(kToolbarHeight));
  });

  testWidgets('the badge sits BELOW the avatar, not beside it',
      (tester) async {
    await setViewport(tester, 800);
    await tester.pumpWidget(header(rank: UserRank.gold));
    await tester.pumpAndSettle();

    final avatar = tester.getRect(find.byType(CircleAvatar));
    final badge = tester.getRect(find.byType(WebRankBadge));
    expect(badge.top, greaterThanOrEqualTo(avatar.bottom - 1),
        reason: 'rank should be stacked under the profile icon');
    // CENTRED over the insignia, not parked at its left edge — the
    // avatar is ~24px against a much wider badge, so left-aligning puts
    // the icon in the corner instead of over the rank it belongs to.
    expect((badge.center.dx - avatar.center.dx).abs(), lessThan(2),
        reason: 'profile icon should sit centred above the rank');
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
      leadingWidth: 76,
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The badge keeps its natural size in the reserved leading slot.
    final badge = tester.getSize(find.byType(WebRankBadge));
    expect(badge.width, greaterThan(0));
    expect(badge.height, lessThanOrEqualTo(kToolbarHeight));
  });

  testWidgets('the rank never overlaps the title', (tester) async {
    await setViewport(tester, 360);
    await tester.pumpWidget(
        header(rank: UserRank.platinum, leadingWidth: 76));
    await tester.pumpAndSettle();

    // Pips-only at 360px must stay inside the reserved leading width.
    final badge = tester.getRect(find.byType(WebRankBadge));
    final titleLeft = tester.getRect(find.text('FxFiles')).left;
    expect(badge.right, lessThanOrEqualTo(titleLeft),
        reason: 'rank ran into the title');
  });

  group('the hint is reachable by TAP, not just hover', () {
    // Desktop gets the hint on hover for free. Touch does not — Tooltip's
    // default touch trigger is a long press, which nobody discovers — so
    // the badge sets triggerMode: tap. These tests pin that down.
    testWidgets('tapping shows what is needed for the next rank',
        (tester) async {
      await setViewport(tester, 360);
      await tester.pumpWidget(header(rank: UserRank.gold));
      await tester.pumpAndSettle();

      // Nothing before the tap (and at 360px the tier name is hidden
      // too, so any 'Gold' on screen must have come from the hint).
      expect(find.textContaining('Platinum'), findsNothing);

      await tester.tap(find.byType(WebRankBadge));
      await tester.pumpAndSettle();

      expect(find.textContaining('reach Platinum'), findsOneWidget);
      expect(find.textContaining('Gold'), findsOneWidget);
    });

    testWidgets('the hint names an amount, not just a tier', (tester) async {
      await setViewport(tester, 360);
      await tester.pumpWidget(header(rank: UserRank.gold));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(WebRankBadge));
      await tester.pumpAndSettle();

      // 600 GiB held, 2 TiB needed -> "add 1.4 TB of storage".
      expect(find.textContaining('add 1.4 TB'), findsOneWidget);
    });

    testWidgets('at the top rank it says so instead of asking for more',
        (tester) async {
      await setViewport(tester, 360);
      await tester.pumpWidget(header(
        rank: UserRank.platinum,
        paidStorageBytes: 4096 * 1024 * 1024 * 1024,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(WebRankBadge));
      await tester.pumpAndSettle();

      expect(find.textContaining('top rank'), findsOneWidget);
      expect(find.textContaining('add '), findsNothing);
    });

    testWidgets('showing the hint does not resize the header',
        (tester) async {
      await setViewport(tester, 360);
      await tester.pumpWidget(header(rank: UserRank.gold));
      await tester.pumpAndSettle();
      final before = tester.getSize(find.byType(AppBar)).height;
      final bodyBefore =
          tester.getTopLeft(find.byKey(const ValueKey('body'))).dy;

      await tester.tap(find.byType(WebRankBadge));
      await tester.pumpAndSettle();

      // The hint is an overlay; it must not reflow the header beneath it.
      expect(tester.getSize(find.byType(AppBar)).height, before);
      expect(tester.getTopLeft(find.byKey(const ValueKey('body'))).dy,
          bodyBefore);
    });
  });

  testWidgets('the label yields rather than overflowing its slot',
      (tester) async {
    // The reserved leading width is finite, and a large OS text scale
    // makes the tier name wider than it. The pips must survive and the
    // name must ellipsize — never overflow stripes in the header.
    await setViewport(tester, 800);
    await tester.pumpWidget(header(rank: UserRank.platinum, leadingWidth: 70));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.star_rounded), findsNWidgets(4));
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
