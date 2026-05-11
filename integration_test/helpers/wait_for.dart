// Async wait-for-condition helper.
//
// `pumpAndSettle` doesn't help when the condition lives outside
// Flutter's widget tree (e.g. waiting for `FulaApiService.isConfigured`
// to flip after a Riverpod-driven init). This polls at a fixed
// interval and gives up after [timeout] with a descriptive failure.

import 'package:flutter_test/flutter_test.dart';

/// Polls [predicate] every [pollInterval] until it returns `true`,
/// or fails with [message] after [timeout].
///
/// Designed for integration tests where the condition is updated
/// asynchronously by background work (network calls, FRB callbacks,
/// SecureStorage reads, etc.).
Future<void> waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 30),
  Duration pollInterval = const Duration(milliseconds: 200),
  required String message,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(pollInterval);
  }
  fail('waitFor timed out after ${timeout.inSeconds}s: $message');
}

/// Same as [waitFor] but the predicate is async (it makes a network
/// call or awaits something internally).
Future<void> waitForAsync(
  Future<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 30),
  Duration pollInterval = const Duration(milliseconds: 500),
  required String message,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(pollInterval);
  }
  fail('waitForAsync timed out after ${timeout.inSeconds}s: $message');
}
