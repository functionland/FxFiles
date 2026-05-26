// Unit tests for ShelfDoodlePainter + Stroke. Verifies copyWith
// semantics on `Stroke` and that `shouldRepaint` only triggers on
// stroke-list mutations (preserves identity caching when nothing
// changed).

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/features/shelf/painters/shelf_doodle_painter.dart';

void main() {
  group('Stroke.copyWith', () {
    test('preserves untouched fields', () {
      const original = Stroke(
        color: Colors.red,
        width: 8,
        points: [Offset(1, 2), Offset(3, 4)],
      );
      final next = original.copyWith(color: Colors.blue);
      expect(next.color, Colors.blue);
      expect(next.width, 8);
      expect(next.points, original.points);
    });
  });

  group('ShelfDoodlePainter.shouldRepaint', () {
    test('returns false for the same list instance', () {
      final strokes = <Stroke>[
        const Stroke(color: Colors.red, width: 4, points: [Offset(0, 0)]),
      ];
      final painter = ShelfDoodlePainter(strokes: strokes);
      expect(painter.shouldRepaint(ShelfDoodlePainter(strokes: strokes)),
          isFalse);
    });

    test('returns true for a different list instance', () {
      final a = <Stroke>[
        const Stroke(color: Colors.red, width: 4, points: [Offset(0, 0)]),
      ];
      final b = List<Stroke>.from(a);
      final painter = ShelfDoodlePainter(strokes: a);
      expect(painter.shouldRepaint(ShelfDoodlePainter(strokes: b)), isTrue);
    });
  });

  group('ShelfDoodlePainter.paint', () {
    test('runs without throwing on empty stroke list', () {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      const painter = ShelfDoodlePainter(strokes: <Stroke>[]);
      painter.paint(canvas, const Size(100, 100));
      // No assertions — the value is "didn't throw".
      recorder.endRecording();
    });

    test('runs without throwing on a single-point stroke (tap, not drag)',
        () {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      const painter = ShelfDoodlePainter(strokes: [
        Stroke(color: Colors.red, width: 6, points: [Offset(10, 10)]),
      ]);
      painter.paint(canvas, const Size(100, 100));
      recorder.endRecording();
    });

    test('runs without throwing on a multi-point stroke', () {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      const painter = ShelfDoodlePainter(strokes: [
        Stroke(
          color: Colors.blue,
          width: 4,
          points: [Offset(0, 0), Offset(50, 50), Offset(100, 0)],
        ),
      ]);
      painter.paint(canvas, const Size(100, 100));
      recorder.endRecording();
    });
  });
}
