/// Canonical encoding of the master-KEK input for Mode B / Mode C
/// vaults (audit F-A1 / F-A3 redesign).
///
/// Two callers running on different devices MUST produce byte-equal
/// inputs from the same conceptual (provider, oauth_sub, seed) /
/// (seed) tuple — otherwise the user's master KEK diverges and
/// cross-device decryption fails silently.
///
/// **Audit fix #2 (2026-05-18)**: the previous implementation passed
/// `utf8.encode(seed)` raw to the Argon2id input. But the matching
/// `compute_effective_user_id_mode_b/c` and `derive_signing_seed`
/// FFI functions NFC-normalize the seed inside Rust. Result: a Mode B
/// user typing `café` as precomposed (NFC) on Device A vs decomposed
/// (NFD) on Device B got the SAME `effective_user_id` (same vault on
/// the server) but DIFFERENT master KEKs → permanent cross-device
/// decryption failure.
///
/// This helper applies NFC (matching the Rust `.nfc()` call) before
/// encoding, so a non-ASCII password typed via different IMEs
/// converges on identical KEK bytes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Build the Mode B master-KEK input bytes. Length-prefixed (u32 LE)
/// concatenation: `provider || oauth_sub || NFC(seed)`. Defeats
/// separator-injection ambiguity that naive colon-joining would
/// have.
Uint8List canonicalKekInputModeB(String provider, String oauthSub, String seed) {
  final providerBytes = utf8.encode(provider);
  final subBytes = utf8.encode(oauthSub);
  final seedBytes = utf8.encode(unorm.nfc(seed));
  final out = BytesBuilder();
  out.add(_u32le(providerBytes.length));
  out.add(providerBytes);
  out.add(_u32le(subBytes.length));
  out.add(subBytes);
  out.add(_u32le(seedBytes.length));
  out.add(seedBytes);
  return out.toBytes();
}

/// Build the Mode C master-KEK input bytes. Length-prefixed
/// `NFC(seed)` only — no OAuth identity.
Uint8List canonicalKekInputModeC(String seed) {
  final seedBytes = utf8.encode(unorm.nfc(seed));
  final out = BytesBuilder();
  out.add(_u32le(seedBytes.length));
  out.add(seedBytes);
  return out.toBytes();
}

Uint8List _u32le(int v) {
  final b = ByteData(4);
  b.setUint32(0, v, Endian.little);
  return b.buffer.asUint8List();
}
