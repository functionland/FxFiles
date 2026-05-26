import 'package:flutter/material.dart';

/// One continuous pen stroke laid down by the user in the doodle
/// overlay. Immutable; the screen replaces the whole list when the
/// user adds, undoes, or redoes a stroke.
@immutable
class Stroke {
  final Color color;
  final double width;
  final List<Offset> points;

  const Stroke({
    required this.color,
    required this.width,
    required this.points,
  });

  Stroke copyWith({
    Color? color,
    double? width,
    List<Offset>? points,
  }) {
    return Stroke(
      color: color ?? this.color,
      width: width ?? this.width,
      points: points ?? this.points,
    );
  }
}

/// CustomPainter that lays each [Stroke] over the captured photo. The
/// painter renders in image-coordinate space; the doodle screen wraps
/// both the photo and the gesture-capture overlay in a fixed-aspect
/// `SizedBox` inside a `FittedBox` so the pointer offsets are already
/// in image coords (revision H3 in the Shelf plan).
class ShelfDoodlePainter extends CustomPainter {
  final List<Stroke> strokes;

  const ShelfDoodlePainter({required this.strokes});

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      _paintStroke(canvas, stroke);
    }
  }

  void _paintStroke(Canvas canvas, Stroke stroke) {
    if (stroke.points.isEmpty) return;
    final paint = Paint()
      ..color = stroke.color
      ..strokeWidth = stroke.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    if (stroke.points.length == 1) {
      // Single dot — draw as a small filled circle so taps without a
      // drag leave a visible mark.
      canvas.drawCircle(
        stroke.points.first,
        stroke.width / 2,
        Paint()
          ..color = stroke.color
          ..style = PaintingStyle.fill,
      );
      return;
    }

    final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
    for (var i = 1; i < stroke.points.length; i++) {
      path.lineTo(stroke.points[i].dx, stroke.points[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant ShelfDoodlePainter old) {
    // List identity is the trigger — the screen state replaces the
    // `strokes` reference whenever a stroke is added / undone / redone.
    return !identical(old.strokes, strokes);
  }
}
