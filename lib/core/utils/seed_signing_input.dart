/// Canonical input strings for the seed-derived Ed25519 signing key
/// (audit fix #3, 2026-05-18).
///
/// **The bug this fixes** — `fula.deriveSigningSeed(seed)` returns a
/// 32-byte Ed25519 seed derived from `BLAKE3_derive_key(...NFC(seed))`.
/// Before this helper, FxFiles passed the user's raw password as the
/// seed for both Mode B and Mode C. Two Mode B users under DIFFERENT
/// OAuth identities but the SAME password ended up with IDENTICAL
/// signing keypairs — meaning a vault published in the global
/// users-index CBOR for one Mode B user could be signed in to by
/// another Mode B user who happens to use the same password (and
/// who can read the target's `effective_user_id` from the public
/// CBOR).
///
/// **The fix** — bind Mode B's signing-key derivation to the full
/// `(provider, oauth_sub, password)` tuple. Mode C stays seed-only
/// (no OAuth identity to bind to).
///
/// The encoding `'b' || NUL || provider || NUL || oauth_sub || NUL ||
/// password` is NFC-stable (the FFI applies NFC, and NUL bytes pass
/// through unchanged). Password injection of `\x00` would corrupt
/// the encoding, but the bytes are not typeable by any standard IME
/// — passwords with literal NUL are pathological inputs.
///
/// Mode B and Mode C signing inputs are mutually exclusive thanks to
/// the leading `'b\x00'` tag: a Mode C user's seed cannot collide
/// with any Mode B input regardless of what password they chose.
library;

/// Build the Mode B signing-key input string.
///
/// `provider` is the canonical tag (`'google'` or `'apple'`).
/// `oauthSub` is the IDP-issued opaque identifier.
/// `password` is the user-entered seed (NFC normalization happens
/// inside the Rust FFI; we just concatenate here).
String modeBSigningInput(String provider, String oauthSub, String password) {
  return 'b\x00$provider\x00$oauthSub\x00$password';
}

/// Build the Mode C signing-key input string. The seed alone — Mode C
/// has no OAuth identity to bind to. Identical to the seed parameter,
/// so callers can equivalently pass the seed directly to
/// `fula.deriveSigningSeed`.
String modeCSigningInput(String seed) {
  return seed;
}
