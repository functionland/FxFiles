import 'package:flutter/material.dart';

import 'package:fula_files/core/models/user_rank.dart';

/// Rank insignia shown beside the "FxFiles" title: N small stars plus the
/// tier name.
///
/// LAYOUT CONTRACT — the whole point of this widget
/// ------------------------------------------------
/// It sits inside an AppBar title, so it must be incapable of changing
/// the header's geometry:
///
///  * **Never taller than the title text.** The stars are [_kStarSize]
///    (13) and the label is [_kLabelSize] (11) with `height: 1.0`, so the
///    row is ~13px against a ~20px title line. There is no vertical
///    padding and no `Container` with a border that could add to it — an
///    AppBar sizes its title to the tallest child, so anything taller
///    here would grow the toolbar.
///  * **Never wraps or overflows.** `mainAxisSize: MainAxisSize.min` and
///    a single line; the *title* is the flexible part, so on a narrow
///    viewport "FxFiles" ellipsizes and the badge keeps its size rather
///    than the two colliding.
///  * **Label drops out below [_kLabelMinWidth].** On a phone viewport
///    the stars alone carry the rank; the name would be the thing that
///    runs into the action icons. The tooltip still names the tier.
///  * **Nothing while loading.** The caller renders this only once the
///    billing fetch resolves — no spinner, because a spinner in the
///    title is exactly the layout shift this is trying to avoid.
class WebRankBadge extends StatelessWidget {
  final UserRank rank;

  /// Drives the "x to go" line in the tooltip.
  final int paidStorageBytes;

  const WebRankBadge({
    super.key,
    required this.rank,
    required this.paidStorageBytes,
  });

  /// Star glyph size. Kept below the AppBar title's line height.
  static const double _kStarSize = 13;

  /// Label size, with height: 1.0 so it adds no leading.
  static const double _kLabelSize = 11;

  /// Below this viewport width the tier name is dropped and only the
  /// stars remain. 420 clears a 360px phone with room for the avatar,
  /// the title and two action icons.
  static const double _kLabelMinWidth = 420;

  /// Tap-target height. The glyph row is only ~13px, far below a usable
  /// touch target, so the hit area is padded out vertically.
  ///
  /// 28 rather than the ideal 48: the badge is stacked UNDER the profile
  /// avatar inside a fixed 56px toolbar, so the whole column (avatar 24 +
  /// gap 2 + badge 28 = 54) has to fit without growing the header. The
  /// header height was an explicit requirement, so it wins over the
  /// larger target — but the tap area is still more than twice the
  /// glyph row.
  static const double _kTapTargetHeight = 28;

  static Color colorFor(UserRank rank) => switch (rank) {
        // Chosen to read on the app's dark surface, and to keep Silver
        // and Platinum apart: Silver is neutral grey, Platinum is a
        // brighter icy tint rather than "slightly lighter grey".
        UserRank.bronze => const Color(0xFFCD7F32),
        UserRank.silver => const Color(0xFFBFC7CF),
        UserRank.gold => const Color(0xFFE8B923),
        UserRank.platinum => const Color(0xFF9FE3F0),
      };

  /// The hint: what this rank is, and what it takes to reach the next
  /// one. Phrased as an action ("add X") rather than a bare number,
  /// because the whole point is telling the user what to DO.
  String hintText() {
    final label = userRankLabel(rank);
    final remaining = bytesToNextRank(paidStorageBytes);
    final next = nextRankAfter(rank);
    if (remaining == null || next == null) {
      return '$label — the top rank. Nothing left to unlock.';
    }
    return '$label — add ${_fmtBytes(remaining)} of storage to reach '
        '${userRankLabel(next)}';
  }

  static String _fmtBytes(int bytes) {
    const gib = 1024 * 1024 * 1024;
    if (bytes >= 1024 * gib) {
      return '${(bytes / (1024 * gib)).toStringAsFixed(1)} TB';
    }
    if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(0)} GB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFor(rank);
    final showLabel =
        MediaQuery.sizeOf(context).width >= _kLabelMinWidth;
    final stars = userRankStars(rank);

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
        // A taller TAP TARGET than the 13px glyph row, because a 13px
        // target is not tappable on a phone. This does NOT grow the
        // header: an AppBar is a fixed `toolbarHeight` (56) and centres
        // its title inside, so a 36px title child changes no geometry —
        // the widget tests assert exactly that.
        height: _kTapTargetHeight,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              for (var i = 0; i < stars; i++)
                Icon(Icons.star_rounded, size: _kStarSize, color: color),
              if (showLabel) ...[
                const SizedBox(width: 4),
                // Flexible + ellipsis so the label can NEVER overflow the
                // width it is given. The pips are the rank signal and stay
                // fixed; the name is what yields. This is not theoretical:
                // an OS-level text-scale setting makes "Platinum" wider
                // than the reserved leading slot, and an unconstrained Row
                // would paint the overflow stripes into the header.
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
            ],
          ),
        ),
      ),
    );
  }
}
