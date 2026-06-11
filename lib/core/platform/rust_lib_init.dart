// Platform seam for one-shot flutter_rust_bridge initialization.
//
// The IO implementation needs dart:io Platform + the FRB io-only
// ExternalLibrary (iOS statically links the Rust lib, so it must use
// DynamicLibrary.process); the web implementation is a bare
// RustLib.init() that loads web/pkg/fula_flutter.js + wasm. Both share
// the duplicate-init tolerance: FRB throws on a second init in the same
// isolate, which callers must treat as success.
export 'rust_lib_init_io.dart'
    if (dart.library.js_interop) 'rust_lib_init_web.dart';
