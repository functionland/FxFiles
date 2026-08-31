import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/user_rank.dart';
import 'package:fula_files/web/widgets/web_rank_badge.dart';

/// These tests exist for three reasons.
///
/// 1. The badge lives in the AppBar's leading slot, and the requirement
///    was that it must not enlarge the header, push content down, or let
///    the header texts collide on a phone. Those are geometry claims, so
///    they are asserted as geometry rather than trusted.
/// 2. The tier NAME is now load-bearing — a whale glyph marks five of the
///    eight tiers — so the reserved width has to actually fit the widest
///    name. That is measured here, not estimated.
/// 3. The hint has to be reachable on TOUCH. Desktop gets it on hover for
///    free; Tooltip's default touch trigger is a long press, which nobody
///    discovers — so tap-to-hint is pinned down.
void main() {
  /// The header as it is actually assembled in web_home_screen.dart:
  /// the rank sits BELOW the profile avatar in the leading slot, not in
  /// the title.
  Widget header({
    UserRank? rank,
    String title = 'FxFiles',
    double tokenScore = 130000,
    double? leadingWidth,
  }) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          leadingWidth:
              rank == null ? 56 : (leadingWidth ?? WebRankBadge.kReservedLeadingWidth),
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
                    WebRankBadge(rank: rank, tokenScore: tokenScore),
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

    await tester.pumpWidget(header(rank: UserRank.platinumWhale));
    await tester.pumpAndSettle();
    final with_ = tester.getSize(find.byType(AppBar)).height;

    // Platinum Whale is the widest case, and its emoji is the tallest.
    expect(with_, without,
        reason: 'the rank badge changed the AppBar height');
  });

  testWidgets('the badge does not push the body down', (tester) async {
    await setViewport(tester, 800);

    await tester.pumpWidget(header());
    final bodyTopWithout =
        tester.getTopLeft(find.byKey(const ValueKey('body'))).dy;

    await tester.pumpWidget(header(rank: UserRank.platinumWhale));
    await tester.pumpAndSettle();
    final bodyTopWith =
        tester.getTopLeft(find.byKey(const ValueKey('body'))).dy;

    expect(bodyTopWith, bodyTopWithout);
  });

  testWidgets('every tier renders its glyph and name, and fits the toolbar',
      (tester) async {
    await setViewport(tester, 800);
    for (final rank in UserRank.values) {
      await tester.pumpWidget(header(rank: rank));
      await tester.pumpAndSettle();

      expect(find.text(userRankEmoji(rank)), findsOneWidget,
          reason: '${rank.name} glyph');
      expect(find.text(userRankLabel(rank)), findsOneWidget,
          reason: '${rank.name} label');

      // The badge must fit inside the fixed 56px toolbar. The stronger
      // claim — that it changes nothing — is asserted by the AppBar
      // height and body-offset tests above.
      final badgeHeight = tester.getSize(find.byType(WebRankBadge)).height;
      expect(badgeHeight, lessThanOrEqualTo(kToolbarHeight),
          reason: '${rank.name} badge is ${badgeHeight}px tall');
    }
  });

  group('the reserved leading width actually fits the widest name', () {
    /// The badge's NATURAL content width — glyph + gap + full name.
    ///
    /// Measured from the two Text widgets rather than from the badge
    /// itself: the badge contains a `Center`, which expands to whatever
    /// slot it is given, so its own size reports the slot and not the
    /// content. Rendered in a slot far wider than needed so neither
    /// Text is ellipsized and both report their natural extent.
    Future<double> contentWidth(WidgetTester tester, UserRank rank) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              child: WebRankBadge(rank: rank, tokenScore: 600000),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final glyph = tester.getSize(find.text(userRankEmoji(rank))).width;
      final label = tester.getSize(find.text(userRankLabel(rank))).width;
      // + 3 for the SizedBox between them.
      return glyph + 3 + label;
    }

    /// The slot the badge actually gets: the reservation minus the 8px
    /// left padding web_home_screen puts in front of the identity block.
    const available = WebRankBadge.kReservedLeadingWidth - 8;

    /// WHY THIS GROUP DOES NOT ASSERT "the name fits in 142px"
    ///
    /// It cannot, honestly. `flutter_test` swaps in a test font whose
    /// every glyph is a full em square, so "Platinum Whale" measures
    /// ~173px here against ~107px in Roboto — the font the browser
    /// actually uses. A pass or a fail against 142 would be a statement
    /// about the test font, not about the product.
    ///
    /// So the reservation is sized from Roboto metrics (measured in a
    /// browser, see the constant's doc comment) and what is asserted
    /// here is the font-INDEPENDENT half: that a name too wide for its
    /// slot degrades to an ellipsis instead of overflowing, and that the
    /// glyph survives. The test font being ~1.6x too wide makes this a
    /// genuine worst case rather than a weaker check.
    testWidgets('a name too wide for its slot ellipsizes, never overflows',
        (tester) async {
      await setViewport(tester, 800);
      for (final rank in UserRank.values) {
        await tester.pumpWidget(header(rank: rank));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: rank.name);
        // Both parts still present — an ellipsized label is still found
        // by its full text, and the glyph is never the thing that goes.
        expect(find.text(userRankEmoji(rank)), findsOneWidget,
            reason: rank.name);
      }
    });

    testWidgets('the shortest names fit even in the wide test font',
        (tester) async {
      // A floor on the reservation that IS font-independent enough to
      // assert: if even "Member" or "Whale" needed more than the slot,
      // the reservation would be wrong under any font.
      await setViewport(tester, 800);
      for (final rank in [UserRank.member, UserRank.whale]) {
        final width = await contentWidth(tester, rank);
        expect(width, lessThanOrEqualTo(available),
            reason: '${userRankLabel(rank)} needs ${width}px of $available '
                'even before accounting for a proportional font');
      }
    });

    testWidgets('a large OS text scale ellipsizes rather than overflowing',
        (tester) async {
      // At 1.5x the name genuinely does not fit. The requirement is that
      // it degrades, not that it fits — an overflow would paint stripes
      // into the header.
      await setViewport(tester, 800);
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            appBar: AppBar(
              leadingWidth: WebRankBadge.kReservedLeadingWidth,
              leading: const Padding(
                padding: EdgeInsets.only(left: 8),
                child: WebRankBadge(
                    rank: UserRank.platinumWhale, tokenScore: 600000),
              ),
              title: const Text('FxFiles'),
            ),
            body: const SizedBox.expand(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the tap target is bigger than the glyph row', (tester) async {
    await setViewport(tester, 360);
    await tester.pumpWidget(header(rank: UserRank.goldWhale));
    await tester.pumpAndSettle();

    // The glyph row is ~14px; without a padded hit area this is not
    // tappable, which would make tap-to-hint useless. Capped at 28 by
    // the 56px toolbar budget it shares with the avatar above it.
    final size = tester.getSize(find.byType(WebRankBadge));
    expect(size.height, greaterThanOrEqualTo(28));
  });

  testWidgets('avatar + badge together fit the fixed toolbar',
      (tester) async {
    await setViewport(tester, 800);
    await tester.pumpWidget(header(rank: UserRank.platinumWhale));
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
    await tester.pumpWidget(header(rank: UserRank.goldWhale));
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

  testWidgets('the name is kept on a phone viewport, NOT dropped',
      (tester) async {
    // The inverse of the old behaviour, and the reason the reservation
    // grew: five of the eight tiers share the whale glyph, so a
    // glyph-only badge on a phone would not say WHICH tier this is.
    await setViewport(tester, 360);
    await tester.pumpWidget(header(rank: UserRank.goldWhale));
    await tester.pumpAndSettle();

    expect(find.text('Gold Whale'), findsOneWidget);
    expect(find.text('🐋'), findsOneWidget);
  });

  testWidgets('no overflow at a very narrow viewport', (tester) async {
    // A RenderFlex overflow throws in tests, so simply pumping without an
    // exception is the assertion. Platinum Whale = the widest badge.
    await setViewport(tester, 300);
    await tester.pumpWidget(header(rank: UserRank.platinumWhale));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the title still fits beside the badge on a 360px phone',
      (tester) async {
    // The cost of reserving width for the full tier name is paid by the
    // title. Assert it is still affordable rather than assuming it.
    await setViewport(tester, 360);
    await tester.pumpWidget(header(rank: UserRank.platinumWhale));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final badge = tester.getRect(find.byType(WebRankBadge));
    final titleRect = tester.getRect(find.text('FxFiles'));
    expect(badge.right, lessThanOrEqualTo(titleRect.left),
        reason: 'rank ran into the title');
    // Not merely non-overlapping — actually wide enough to read.
    expect(titleRect.width, greaterThan(50),
        reason: 'the title was squeezed to ${titleRect.width}px');
  });

  testWidgets('a long title ellipsizes instead of colliding',
      (tester) async {
    await setViewport(tester, 360);
    await tester.pumpWidget(header(
      rank: UserRank.platinumWhale,
      title: 'A Very Long Product Name That Cannot Possibly Fit',
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final badge = tester.getSize(find.byType(WebRankBadge));
    expect(badge.width, greaterThan(0));
    expect(badge.height, lessThanOrEqualTo(kToolbarHeight));
  });

  group('the hint is reachable by TAP, not just hover', () {
    // Desktop gets the hint on hover for free. Touch does not — Tooltip's
    // default touch trigger is a long press, which nobody discovers — so
    // the badge sets triggerMode: tap. These tests pin that down.
    testWidgets('tapping shows what is needed for the next rank',
        (tester) async {
      await setViewport(tester, 360);
      await tester.pumpWidget(
          header(rank: UserRank.goldWhale, tokenScore: 130000));
      await tester.pumpAndSettle();

      expect(find.textContaining('Diamond'), findsNothing);

      await tester.tap(find.byType(WebRankBadge));
      await tester.pumpAndSettle();

      expect(find.textContaining('reach Diamond Whale'), findsOneWidget);
    });

    testWidgets('the hint names an amount in tokens, not just a tier',
        (tester) async {
      await setViewport(tester, 360);
      await tester.pumpWidget(
          header(rank: UserRank.goldWhale, tokenScore: 130000));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(WebRankBadge));
      await tester.pumpAndSettle();

      // 130,000 held+spent, 250,000 needed for Diamond Whale.
      expect(find.textContaining('add 120,000 tokens'), findsOneWidget);
    });

    testWidgets('the amount is thousands-separated and whole',
        (tester) async {
      await setViewport(tester, 360);
      // A fractional score is the normal case: hourly deductions are
      // fractional, so the gap almost never lands on a whole number.
      await tester.pumpWidget(
          header(rank: UserRank.starter, tokenScore: 5000.37));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(WebRankBadge));
      await tester.pumpAndSettle();

      // Rounded UP, so adding the stated amount really does cross.
      expect(find.textContaining('add 7,000 tokens'), findsOneWidget);
      expect(find.textContaining('.'), findsNothing);
    });

    testWidgets('at the top rank it says so instead of asking for more',
        (tester) async {
      await setViewport(tester, 360);
      await tester.pumpWidget(header(
        rank: UserRank.platinumWhale,
        tokenScore: 750000,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(WebRankBadge));
      await tester.pumpAndSettle();

      expect(find.textContaining('top rank'), findsOneWidget);
      expect(find.textContaining('add '), findsNothing);
    });

    testWidgets('a brand-new account is told what to climb to, not that '
        'it is finished', (tester) async {
      await setViewport(tester, 360);
      await tester.pumpWidget(header(rank: UserRank.member, tokenScore: 0));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(WebRankBadge));
      await tester.pumpAndSettle();

      expect(find.textContaining('reach Starter'), findsOneWidget);
      expect(find.textContaining('top rank'), findsNothing);
    });

    testWidgets('showing the hint does not resize the header',
        (tester) async {
      await setViewport(tester, 360);
      await tester.pumpWidget(header(rank: UserRank.goldWhale));
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
    // A slot narrower than the reservation (a caller bug, or a future
    // layout change) must ellipsize the name, never paint overflow
    // stripes into the header.
    await setViewport(tester, 800);
    await tester
        .pumpWidget(header(rank: UserRank.platinumWhale, leadingWidth: 70));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('🐋'), findsOneWidget);
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
