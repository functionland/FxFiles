import 'package:flutter/foundation.dart';
import 'package:fula_client/fula_client.dart' show RustLib;

bool _initialized = false;

/// Mark RustLib as initialized (called after a successful external init,
/// e.g. the web entrypoint's boot sequence).
void markRustLibInitialized() => _initialized = true;

/// Ensure RustLib (flutter_rust_bridge) is initialized.
/// On web this loads `pkg/fula_flutter.js` + `pkg/fula_flutter_bg.wasm`
/// from the app's web/ folder via the FRB loader (no platform branches).
Future<void> ensureRustLibInitialized() async {
  if (_initialized) return;

  debugPrint('rust_lib_init(web): loading FRB wasm...');
  try {
    await RustLib.init();
    _initialized = true;
    debugPrint('rust_lib_init(web): RustLib initialized');
  } catch (e) {
    // Same duplicate-init tolerance as the IO implementation: a second
    // init in the same page context throws but the library is usable.
    final msg = e.toString().toLowerCase();
    if (msg.contains('should not initialize flutter_rust_bridge twice') ||
        msg.contains('already initialized')) {
      _initialized = true;
      return;
    }
    debugPrint('rust_lib_init(web): init failed: $e');
    rethrow;
  }
}
