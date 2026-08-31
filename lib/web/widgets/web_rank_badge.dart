import 'package:flutter/material.dart';

import 'package:fula_files/core/models/user_rank.dart';

/// Status insignia shown beneath the profile avatar: the tier's glyph
/// plus its full name.
///
/// LAYOUT CONTRACT — the whole point of this widget
/// ------------------------------------------------
/// It sits in the AppBar's leading slot, so it must be incapable of
/// changing the header's geometry:
///
///  * **Never taller than the toolbar allows.** The glyph is
///    [_kEmojiSize] and the label [_kLabelSize], inside a
///    [_kTapTargetHeight] box — against a fixed 56px toolbar it shares
///    with the avatar above it.
///  * **Never wraps or overflows.** `mainAxisSize: MainAxisSize.min` and
///    a single line; the label is `Flexible` with an ellipsis, so a
///    large OS text scale shortens the name instead of painting overflow
///    stripes into the header.
///  * **The label is NOT optional.** An earlier version of this badge
///    dropped its name on narrow viewports and let star pips carry the
///    rank. That is no longer possible: a whale marks five of the eight
///    tiers (see [userRankEmoji]), so the glyph alone cannot say WHICH
///    tier this is. The caller reserves enough width for the name at
///    every viewport instead.
///  * **Nothing while loading.** The caller renders this only once the
///    billing fetch resolves — no spinner, because a spinner in the
///    header is exactly the layout shift this is trying to avoid.
class WebRankBadge extends StatelessWidget {
  final UserRank rank;

  /// The user's status score — tokens held plus tokens spent in the last
  /// 12 months. Drives the "x to go" line in the tooltip.
  final double tokenScore;

  const WebRankBadge({
    super.key,
    required this.rank,
    required this.tokenScore,
  });

  /// Glyph size. Kept small enough that the badge plus the avatar above
  /// it still fits the fixed toolbar.
  static const double _kEmojiSize = 12;

  /// Label size.
  static const double _kLabelSize = 11;

  /// Tap-target height. The glyph row is only ~14px, far below a usable
  /// touch target, so the hit area is padded out vertically.
  ///
  /// 28 rather than the ideal 48: the badge is stacked UNDER the profile
  /// avatar inside a fixed 56px toolbar, so the whole column (avatar 24 +
  /// gap 2 + badge 28 = 54) has to fit without growing the header. The
  /// header height was an explicit requirement, so it wins over the
  /// larger target — but the tap area is still twice the glyph row.
  static const double _kTapTargetHeight = 28;

  /// Width the caller must reserve in the AppBar's leading slot: the
  /// widest tier name at a normal text scale, plus the glyph, the gap
  /// and the 8px leading padding.
  ///
  /// Exported so `web_home_screen.dart` cannot drift from it — the
  /// reservation and the thing being reserved for belong together.
  ///
  /// SIZED FROM MEASURED ROBOTO, NOT ESTIMATED. Rendering the labels in
  /// Roboto (Flutter's default, and what the browser uses — the app sets
  /// no `fontFamily`) at the sizes above gives, for the widest tier:
  ///
  ///     "Platinum Whale"  80.9 + glyph 16.5 + gap 3  =  100.4px
  ///
  /// against the 142px this reservation leaves after the padding. The
  /// ~41px of slack is deliberate headroom: it absorbs an OS text scale
  /// up to ~1.4x before the name starts to ellipsize.
  ///
  /// Do NOT re-derive this from a widget test. `flutter_test` swaps in a
  /// font whose every glyph is a full em square, which measures the same
  /// label at ~173px — a number about the test font, not about the
  /// product.
  ///
  /// The cost of every px here is paid by the title, which is why this
  /// is 150 and not more: on a 360px phone the two action icons take
  /// ~100px, leaving ~94px for a title that measures 60px.
  static const double kReservedLeadingWidth = 150;

  static Color colorFor(UserRank rank) => switch (rank) {
        // Distinct HUES, not just distinct lightness. Silver/Gold/
        // Platinum are close enough as metals that separating them by
        // brightness alone would be unreadable in a screenshot or to a
        // colour-blind user — so Diamond takes violet rather than
        // another icy blue, and the lower tiers take clearly separate
        // hues. The label carries the real meaning; colour is support.
        UserRank.member => const Color(0xFF94A3B8), //        slate
        UserRank.starter => const Color(0xFFFB923C), //       orange
        UserRank.growth => const Color(0xFF60A5FA), //        blue
        UserRank.whale => const Color(0xFF06B597), //         brand teal
        UserRank.silverWhale => const Color(0xFFBFC7CF), //   silver
        UserRank.goldWhale => const Color(0xFFE8B923), //     gold
        UserRank.diamondWhale => const Color(0xFFC084FC), //  violet
        UserRank.platinumWhale => const Color(0xFFE5E4E2), // platinum
      };

  /// The hint: what this rank is, and what it takes to reach the next
  /// one. Phrased as an action ("add X") rather than a bare number,
  /// because the whole point is telling the user what to DO.
  String hintText() {
    final label = userRankLabel(rank);
    final remaining = tokensToNextRank(tokenScore);
    final next = nextRankAfter(rank);
    if (remaining == null || next == null) {
      return '$label — the top rank. Nothing left to unlock.';
    }
    return '$label — add ${_fmtTokens(remaining)} tokens to reach '
        '${userRankLabel(next)}';
  }

  /// Thousands-separated whole tokens.
  ///
  /// Whole, because the thresholds are whole round numbers and a
  /// fractional "add 4,999.73 tokens" reads as a bug rather than as
  /// precision. Rounded UP so the figure shown is always enough to
  /// actually cross the threshold — rounding down would tell the user to
  /// add an amount that leaves them one fraction short.
  static String _fmtTokens(double tokens) {
    final whole = tokens.ceil();
    final digits = whole.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFor(rank);

    return Tooltip(
      message: hintText(),
      // Desktop shows this on hover for free. Touch does NOT — Tooltip's
      // default touch trigger is a LONG PRESS, which nobody discovers.
      // `tap` adds the tap trigger without removing hover, so the same
      // hint is reachable both ways.
      triggerMode: TooltipTriggerMode.tap,
      // Long enough to actually read on a phone; the default (1.5s) is
      // tuned for a hover the user can simply hold.
      showDuration: const Duration(seconds: 5),
      child: SizedBox(
        // A taller TAP TARGET than the glyph row, because a 14px target
        // is not tappable on a phone. This does NOT grow the header: an
        // AppBar is a fixed `toolbarHeight` (56) and centres its leading
        // inside, so a 28px child changes no geometry — the widget tests
        // assert exactly that.
        height: _kTapTargetHeight,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Text(
                userRankEmoji(rank),
                style: const TextStyle(
                  fontSize: _kEmojiSize,
                  // Emoji glyphs overshoot their nominal box far more
                  // than latin text does, so this does NOT pin height to
                  // 1.0 the way the label does — that clips the bottom
                  // of the glyph. `even` splits the extra leading top and
                  // bottom so the glyph sits centred in its line box.
                  height: 1.2,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
              const SizedBox(width: 3),
              // Flexible + ellipsis so the label can NEVER overflow the
              // width it is given. This is not theoretical: an OS-level
              // text-scale setting makes "Platinum Whale" wider than the
              // reserved leading slot, and an unconstrained Row would
              // paint the overflow stripes into the header.
              Flexible(
                child: Text(
                  userRankLabel(rank),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _kLabelSize,
                    // height 1.0 keeps the text box exactly the glyph
                    // height, so the label cannot grow the toolbar.
                    height: 1.0,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
