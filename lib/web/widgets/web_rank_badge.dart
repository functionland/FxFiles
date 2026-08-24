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

  static Color colorFor(UserRank rank) => switch (rank) {
        // Chosen to read on the app's dark surface, and to keep Silver
        // and Platinum apart: Silver is neutral grey, Platinum is a
        // brighter icy tint rather than "slightly lighter grey".
        UserRank.bronze => const Color(0xFFCD7F32),
        UserRank.silver => const Color(0xFFBFC7CF),
        UserRank.gold => const Color(0xFFE8B923),
        UserRank.platinum => const Color(0xFF9FE3F0),
      };

  String _tooltip() {
    final label = userRankLabel(rank);
    final remaining = bytesToNextRank(paidStorageBytes);
    final next = nextRankAfter(rank);
    if (remaining == null || next == null) {
      return '$label — top rank';
    }
    return '$label · ${_fmtBytes(remaining)} more storage for '
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
      message: _tooltip(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          for (var i = 0; i < stars; i++)
            Icon(Icons.star_rounded, size: _kStarSize, color: color),
          if (showLabel) ...[
            const SizedBox(width: 4),
            Text(
              userRankLabel(rank),
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: _kLabelSize,
                // height 1.0 keeps the text box exactly the glyph height,
                // so the label cannot be what grows the toolbar.
                height: 1.0,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: color,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
