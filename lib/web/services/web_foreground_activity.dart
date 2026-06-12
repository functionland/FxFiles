import 'dart:async';
import 'dart:math';

/// Global counter of user-initiated network work
/// (docs/web-listing-prefetch-cache-plan.md §6.2). Screens and
/// download/upload paths wrap their awaited operations in [run]; the
/// prefetch scheduler dequeues only while [idle] — background warm-up
/// must never compete with something the user is actually waiting on
/// (bandwidth AND the wasm client's locks).
class WebForegroundActivity {
  WebForegroundActivity._();
  static final WebForegroundActivity instance = WebForegroundActivity._();

  int _count = 0;
  int get count => _count;
  bool get idle => _count == 0;

  final _changes = StreamController<int>.broadcast();
  Stream<int> get changes => _changes.stream;

  void begin() {
    _count++;
    _changes.add(_count);
  }

  void end() {
    _count = max(0, _count - 1);
    _changes.add(_count);
  }

  /// Wrap a user-initiated async operation. Exceptions pass through.
  Future<T> run<T>(Future<T> Function() fn) async {
    begin();
    try {
      return await fn();
    } finally {
      end();
    }
  }

  /// Completes when [idle] (immediately if already idle).
  ///
  /// Subscribe-BEFORE-recheck: grabbing `changes.first` first, then
  /// re-reading [idle], closes the lost-wakeup gap where the counter
  /// hits 0 between an idle check and the stream subscription (a
  /// waiter would otherwise park until the NEXT activity cycle —
  /// Gemini-flagged). Any counter change wakes the loop; the loop
  /// condition does the real check.
  Future<void> whenIdle() async {
    while (!idle) {
      final next = changes.first;
      if (idle) return;
      await next;
    }
  }
}
