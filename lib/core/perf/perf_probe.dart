import 'package:flutter/foundation.dart';

/// P0 measurement probes for the web listing-cache plan
/// (docs/web-listing-prefetch-cache-plan.md).
///
/// Compiled OUT of normal builds: only `--dart-define=PERF=true` turns
/// [kPerfEnabled] on; with it off, [perfSpan] is a plain passthrough the
/// compiler can inline (const-folded branch), so instrumented call sites
/// cost nothing in production — native and web alike.
const bool kPerfEnabled = bool.fromEnvironment('PERF');

/// Run [fn], printing `[perf] <label> <ms>ms` when PERF builds are on.
/// The label convention is `<phase> <subject>`, e.g. `forest-load images-v8`.
Future<T> perfSpan<T>(String label, Future<T> Function() fn) async {
  if (!kPerfEnabled) return fn();
  final sw = Stopwatch()..start();
  try {
    return await fn();
  } finally {
    sw.stop();
    debugPrint('[perf] $label ${sw.elapsedMilliseconds}ms');
  }
}
