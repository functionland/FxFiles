// Native (dart:io / VM) stub for the Blox auto-pin return capture.
//
// Exists ONLY so the shared graph compiles for native and under `flutter test`
// (the VM compiles THIS branch of the conditional export, never the
// `package:web` impl). There is no browser URL to read, so CAPTURE is inert;
// the stash/take pair still works against the memory holder so widget tests
// and the router fallback behave the same way on both branches.
//
// Imports nothing web-specific.

import 'package:fula_files/core/services/blox_pairing_links.dart';
import 'package:fula_files/web/services/web_autopin_return_logic.dart';

/// CAPTURE (native stub): no browser URL — nothing to capture.
void captureAutopinReturn() {}

/// Park [params] for the post-login hand-off (memory only on the VM).
void stashPendingAutopinReturn(AutopinCompleteParams? params) =>
    stashPendingAutopinReturnInMemory(params);

/// Atomic read-and-clear of the memory holder.
AutopinCompleteParams? takePendingAutopinReturn() =>
    takePendingAutopinReturnFromMemory();
