// Captures diagnostic context to surface on test failure.
//
// When an integration test fails on a real device, the test harness
// often loses crucial context: which endpoint was active? which
// bucket? which key? which step did we last complete? This logger
// accumulates breadcrumbs that the test reports verbatim on failure.

import 'package:flutter/foundation.dart';

/// Append-only log of test steps. Reset per-test via [reset] in
/// `setUp`.
class FailureLogger {
  static final FailureLogger _instance = FailureLogger._();
  factory FailureLogger() => _instance;
  FailureLogger._();

  final List<String> _breadcrumbs = <String>[];

  void reset() {
    _breadcrumbs.clear();
  }

  /// Add a single line. Also `debugPrint`s so the line shows up in
  /// `flutter test integration_test/` output even when the test passes.
  void step(String message) {
    final stamp = DateTime.now().toIso8601String().substring(11, 23);
    final line = '[$stamp] $message';
    _breadcrumbs.add(line);
    debugPrint('TEST: $line');
  }

  /// Format all breadcrumbs as a single string for inclusion in an
  /// `expect` reason or `fail` message.
  String dump() {
    if (_breadcrumbs.isEmpty) return '(no breadcrumbs)';
    return _breadcrumbs.join('\n');
  }
}
