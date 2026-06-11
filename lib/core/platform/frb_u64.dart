import 'package:flutter/foundation.dart';

// flutter_rust_bridge maps Rust u64 to `int` in the IO bindings but to
// `BigInt` in the web bindings (JS numbers can't hold 64 bits), so the
// STATIC type of u64-backed fields/params differs per platform. Shared
// code crossing that boundary goes through these two helpers: `dynamic`
// erases the per-platform static type at the call site, and kIsWeb
// const-folds so each platform compiles only its own branch.

/// Normalize a u64-backed FRB value (int on IO, BigInt on web) to int.
/// Safe for timestamps/sizes (< 2^53 in practice on web).
int? frbU64ToInt(dynamic v) =>
    v == null ? null : (v is BigInt ? v.toInt() : v as int);

/// Convert an int to whatever the platform's FRB binding expects for a
/// u64 parameter (int on IO, BigInt on web).
dynamic intToFrbU64(int? v) =>
    v == null ? null : (kIsWeb ? BigInt.from(v) : v);
