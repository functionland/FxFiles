import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/web/services/web_audio_queue.dart';

/// Unit tests for the pure web-audio queue / repeat / shuffle logic (#21).
/// The just_audio + blob-URL playback glue (web_audio_controller.dart) is
/// browser-only and verified live; these transitions are the VM-safe core.
void main() {
  group('nextRepeatMode', () {
    test('cycles off -> one -> all -> off', () {
      expect(nextRepeatMode(WebRepeatMode.off), WebRepeatMode.one);
      expect(nextRepeatMode(WebRepeatMode.one), WebRepeatMode.all);
      expect(nextRepeatMode(WebRepeatMode.all), WebRepeatMode.off);
    });
  });

  group('nextIndexOnComplete', () {
    test('repeat one replays current', () {
      expect(nextIndexOnComplete(2, 5, WebRepeatMode.one), 2);
    });
    test('repeat all wraps at the end', () {
      expect(nextIndexOnComplete(4, 5, WebRepeatMode.all), 0);
      expect(nextIndexOnComplete(1, 5, WebRepeatMode.all), 2);
    });
    test('repeat off advances then stops at the end', () {
      expect(nextIndexOnComplete(1, 5, WebRepeatMode.off), 2);
      expect(nextIndexOnComplete(4, 5, WebRepeatMode.off), isNull);
    });
    test('empty queue stops', () {
      expect(nextIndexOnComplete(0, 0, WebRepeatMode.all), isNull);
    });
  });

  group('nextIndexManual', () {
    test('advances mid-list regardless of repeat mode', () {
      expect(nextIndexManual(1, 5, WebRepeatMode.off), 2);
      expect(nextIndexManual(1, 5, WebRepeatMode.one), 2);
    });
    test('at the end wraps only under repeat-all', () {
      expect(nextIndexManual(4, 5, WebRepeatMode.all), 0);
      expect(nextIndexManual(4, 5, WebRepeatMode.off), isNull);
      expect(nextIndexManual(4, 5, WebRepeatMode.one), isNull);
    });
  });

  group('prevIndexManual', () {
    test('steps back mid-list', () {
      expect(prevIndexManual(3, 5, WebRepeatMode.off), 2);
    });
    test('at the start wraps only under repeat-all', () {
      expect(prevIndexManual(0, 5, WebRepeatMode.all), 4);
      expect(prevIndexManual(0, 5, WebRepeatMode.off), 0);
    });
  });

  group('buildShuffleOrder', () {
    test('is a permutation with the current index first', () {
      final order = buildShuffleOrder(6, 3, Random(42));
      expect(order.first, 3);
      expect(order.toSet(), {0, 1, 2, 3, 4, 5});
      expect(order.length, 6);
    });
    test('tolerates a current index out of range', () {
      final order = buildShuffleOrder(4, -1, Random(1));
      expect(order.toSet(), {0, 1, 2, 3});
    });
  });

  group('fmtDuration', () {
    test('formats m:ss with a zero-padded seconds field', () {
      expect(fmtDuration(Duration.zero), '0:00');
      expect(fmtDuration(const Duration(seconds: 65)), '1:05');
      expect(fmtDuration(const Duration(minutes: 12, seconds: 9)), '12:09');
    });
  });
}
