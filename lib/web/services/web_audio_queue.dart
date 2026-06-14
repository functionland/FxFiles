import 'dart:math';

/// Pure, VM-testable queue / repeat / shuffle logic for the web audio player
/// (#21), mirroring the framework-agnostic core of the native
/// `audio_player_service.dart`. No `package:web` / just_audio imports so this
/// — and its unit tests — run under the VM; the playback glue (blob URLs,
/// just_audio) lives in `web_audio_controller.dart`.

/// Repeat behaviour, matching native `RepeatMode` (off → one → all).
enum WebRepeatMode { off, one, all }

/// Cycle order for the repeat button: off → one → all → off (native order).
WebRepeatMode nextRepeatMode(WebRepeatMode m) {
  switch (m) {
    case WebRepeatMode.off:
      return WebRepeatMode.one;
    case WebRepeatMode.one:
      return WebRepeatMode.all;
    case WebRepeatMode.all:
      return WebRepeatMode.off;
  }
}

/// Index to play when the current track finishes, or null to stop.
/// (one → replay current; all → wrap; off → next or stop at the end.)
int? nextIndexOnComplete(int current, int length, WebRepeatMode mode) {
  if (length <= 0) return null;
  switch (mode) {
    case WebRepeatMode.one:
      return current;
    case WebRepeatMode.all:
      return (current + 1) % length;
    case WebRepeatMode.off:
      return current + 1 < length ? current + 1 : null;
  }
}

/// Index for a manual "next" tap, or null if at the end without repeat-all.
/// (Manual next ignores repeat-one — it advances, like native skipToNext.)
int? nextIndexManual(int current, int length, WebRepeatMode mode) {
  if (length <= 0) return null;
  if (current >= length - 1) return mode == WebRepeatMode.all ? 0 : null;
  return current + 1;
}

/// Index for a manual "previous" tap (wraps to the last track under
/// repeat-all, else clamps at the first).
int prevIndexManual(int current, int length, WebRepeatMode mode) {
  if (length <= 0) return 0;
  if (current > 0) return current - 1;
  return mode == WebRepeatMode.all ? length - 1 : 0;
}

/// A shuffle of the indices `[0, length)` with [current] moved to the front,
/// so the playing track stays put when shuffle is toggled on (mirrors native
/// `_shufflePlaylist(keepCurrent: true)`). [rng] is injected for testability.
List<int> buildShuffleOrder(int length, int current, Random rng) {
  final order = List<int>.generate(length, (i) => i)..shuffle(rng);
  if (current >= 0 && current < length) {
    order.remove(current);
    order.insert(0, current);
  }
  return order;
}

/// `m:ss` like the native player's time labels.
String fmtDuration(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
