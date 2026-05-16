import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// On-device crash + breadcrumb log. Lets users on devices we don't control
/// (e.g. customer Android 9 reports where ADB is impractical) ship us a log
/// after a reproducible crash via Settings → Send diagnostic log.
///
/// - Persists everything to `<app-docs>/crash.log` (append-only).
/// - Caps the file at [_maxBytes]; older bytes are truncated so the log
///   never grows unbounded.
/// - Survives process death because every write is flushed before return.
/// - Captures Flutter framework errors, uncaught async errors, and
///   explicit `record*` calls placed at suspected breakpoints.
class CrashLogService {
  CrashLogService._();
  static final CrashLogService instance = CrashLogService._();

  /// Hard cap. ~200 KB is plenty for a few weeks of breadcrumbs + several
  /// full stack traces without paying meaningful disk cost.
  static const int _maxBytes = 200 * 1024;

  static const String _fileName = 'crash.log';

  File? _file;
  bool _isInitialized = false;
  final _writeLock = _AsyncLock();

  /// Initialize. Must be called from `main()` BEFORE [runApp] so the global
  /// error handlers are in place by the time UI starts building.
  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File(p.join(dir.path, _fileName));
      if (!await _file!.exists()) {
        await _file!.create(recursive: true);
      }
      await _writeRaw('\n=== app started: ${DateTime.now().toIso8601String()} ===\n');
    } catch (e) {
      debugPrint('CrashLogService: init failed: $e');
      _file = null;
    }

    FlutterError.onError = (details) {
      // Forward to the default presenter (still red-screen in debug).
      FlutterError.presentError(details);
      recordError(
        details.exceptionAsString(),
        details.stack,
        context: 'FlutterError',
        library: details.library,
      );
    };

    // dart:async uncaught errors that escape the framework.
    PlatformDispatcher.instance.onError = (error, stack) {
      recordError(error.toString(), stack, context: 'PlatformDispatcher');
      return true; // mark as handled so the engine doesn't tear down
    };
  }

  /// Record a free-form breadcrumb. Cheap — call at suspected pinch points
  /// (audio init, screen open, plugin call) so a later crash has context.
  void recordEvent(String message) {
    if (_file == null) {
      debugPrint('CrashLogService [event]: $message');
      return;
    }
    final ts = DateTime.now().toIso8601String();
    unawaited(_writeRaw('[$ts] $message\n'));
  }

  /// Record an error + stack. Used by the global handlers but can also be
  /// called from a manual try/catch.
  void recordError(
    String message,
    StackTrace? stack, {
    String? context,
    String? library,
  }) {
    if (_file == null) {
      debugPrint('CrashLogService [error]: $message\n$stack');
      return;
    }
    final ts = DateTime.now().toIso8601String();
    final buf = StringBuffer()
      ..writeln('[$ts] ERROR'
          '${context != null ? ' ($context)' : ''}'
          '${library != null ? ' [$library]' : ''}: $message');
    if (stack != null) {
      buf.writeln(stack.toString());
    }
    buf.writeln('---');
    unawaited(_writeRaw(buf.toString()));
  }

  /// Absolute path to the log file (null when init failed). Used by the
  /// Settings "Send diagnostic log" action.
  String? get logFilePath => _file?.path;

  /// Current log file size in bytes, or 0 when unavailable.
  Future<int> currentSize() async {
    if (_file == null) return 0;
    try {
      return await _file!.length();
    } catch (_) {
      return 0;
    }
  }

  /// Delete the log file. Used by the "Clear log" affordance.
  Future<void> clear() async {
    if (_file == null) return;
    try {
      if (await _file!.exists()) {
        await _file!.writeAsString('', flush: true);
      }
    } catch (e) {
      debugPrint('CrashLogService: clear failed: $e');
    }
  }

  Future<void> _writeRaw(String text) async {
    final file = _file;
    if (file == null) return;
    await _writeLock.run(() async {
      try {
        await file.writeAsString(text, mode: FileMode.append, flush: true);
        final len = await file.length();
        if (len > _maxBytes) {
          // Read tail, rewrite. Truncation keeps the most recent ~75% so the
          // crash that just happened isn't lost to the rotation.
          final retainBytes = (_maxBytes * 0.75).toInt();
          final raf = await file.open(mode: FileMode.read);
          try {
            await raf.setPosition(len - retainBytes);
            final tail = await raf.read(retainBytes);
            await file.writeAsBytes(tail, flush: true);
          } finally {
            await raf.close();
          }
        }
      } catch (e) {
        debugPrint('CrashLogService: write failed: $e');
      }
    });
  }
}

/// Tiny serialising lock so concurrent breadcrumb writes don't interleave.
class _AsyncLock {
  Future<void>? _last;

  Future<T> run<T>(Future<T> Function() body) {
    final prev = _last ?? Future<void>.value();
    final completer = Completer<void>();
    _last = completer.future;
    return prev.then((_) async {
      try {
        return await body();
      } finally {
        completer.complete();
      }
    });
  }
}
