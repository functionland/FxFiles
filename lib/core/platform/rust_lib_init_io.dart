import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;
import 'package:fula_client/fula_client.dart' show RustLib;

bool _initialized = false;

/// Mark RustLib as initialized (called after a successful external init,
/// e.g. main.dart's startup path or a background isolate entrypoint).
void markRustLibInitialized() => _initialized = true;

/// Ensure RustLib (flutter_rust_bridge) is initialized in this isolate.
/// RustLib.init() may fail at startup (e.g. timeout, linking issues) but
/// succeed on retry; this allows lazy re-initialization before any
/// fula_client call.
Future<void> ensureRustLibInitialized() async {
  if (_initialized) return;

  debugPrint('rust_lib_init: RustLib not initialized, attempting lazy init...');
  try {
    // Platform-conditional pattern: iOS uses `ExternalLibrary.process`
    // because the bridge is statically linked into the app binary;
    // Android uses bare `RustLib.init()` which internally opens the
    // dylib by name (dlopen returns the existing handle if already
    // loaded). Using `ExternalLibrary.process` on Android fails
    // because Android's `System.loadLibrary` defaults to RTLD_LOCAL,
    // so the symbols aren't visible via `DynamicLibrary.process()`.
    if (Platform.isIOS) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
      );
    } else {
      await RustLib.init();
    }
    _initialized = true;
    debugPrint('rust_lib_init: RustLib initialized successfully on retry');
  } catch (e) {
    // FRB throws `Bad state: Should not initialize flutter_rust_bridge
    // twice` when a SECOND init runs in the SAME isolate. That can
    // happen if some other code path (background entrypoint, plugin
    // init order) called `RustLib.init` before us in this isolate but
    // didn't call `markRustLibInitialized()`. The library IS usable
    // either way, so treat the duplicate-init signal as success.
    final msg = e.toString().toLowerCase();
    if (msg.contains('should not initialize flutter_rust_bridge twice') ||
        msg.contains('already initialized')) {
      debugPrint(
        'rust_lib_init: RustLib already initialized in this isolate; '
        'flipping flag and continuing',
      );
      _initialized = true;
      return;
    }
    debugPrint('rust_lib_init: RustLib init retry failed: $e');
    rethrow;
  }
}
