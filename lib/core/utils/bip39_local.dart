/// Minimal BIP39 mnemonic generator / validator.
///
/// Pure Dart, depends only on `package:cryptography` for SHA-256 and
/// the embedded English wordlist in `bip39_english_wordlist.dart`.
/// Implemented locally because the upstream `bip39` Dart package
/// pins `pointycastle ^3.0.0`, which conflicts with `web3dart ^3.0.2`'s
/// `pointycastle ^4.0.0`. The output is byte-compatible with the BIP39
/// specification — any BIP39 wallet can import a phrase generated
/// here, and vice versa.
///
/// Used by the Mode C (passphrase-only) onboarding flow — see
/// `features/onboarding/screens/mode_c_signin_screen.dart`.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'bip39_english_wordlist.dart';

/// Generate a BIP39 mnemonic of the given entropy strength (bits).
/// Valid strengths: 128 → 12 words, 160 → 15, 192 → 18, 224 → 21,
/// 256 → 24 words. Returns the space-separated word string.
Future<String> generateBip39Mnemonic({int strength = 256}) async {
  if (strength % 32 != 0 || strength < 128 || strength > 256) {
    throw ArgumentError(
      'BIP39 strength must be one of 128, 160, 192, 224, 256 (got $strength)',
    );
  }
  final entropyLen = strength ~/ 8;
  final entropy = Uint8List(entropyLen);
  final rng = Random.secure();
  for (var i = 0; i < entropyLen; i++) {
    entropy[i] = rng.nextInt(256);
  }
  return _entropyToMnemonic(entropy);
}

/// Validate a BIP39 mnemonic. Returns true iff:
/// - Word count is one of 12 / 15 / 18 / 21 / 24.
/// - Every word is in the BIP39 English wordlist.
/// - The trailing checksum bits match `SHA-256(entropy)` prefix.
///
/// Whitespace tolerant — `"abandon  ability  ..."` parses identically
/// to the single-space canonical form. Case-insensitive on inputs;
/// the standard wordlist is all lowercase.
Future<bool> validateBip39Mnemonic(String mnemonic) async {
  final words = mnemonic.trim().toLowerCase().split(RegExp(r'\s+'));
  if (!const {12, 15, 18, 21, 24}.contains(words.length)) return false;

  // Words → 11-bit indices → contiguous bit string.
  final bits = StringBuffer();
  for (final word in words) {
    final idx = bip39EnglishWordlist.indexOf(word);
    if (idx < 0) return false;
    bits.write(idx.toRadixString(2).padLeft(11, '0'));
  }

  final bitStr = bits.toString();
  // entropy_bits + checksum_bits = bitStr.length
  // checksum_bits = entropy_bits / 32
  // → entropy_bits = bitStr.length * 32 / 33
  final entropyBits = (bitStr.length * 32) ~/ 33;
  if (entropyBits % 8 != 0) return false;

  final entropyBitStr = bitStr.substring(0, entropyBits);
  final checksumBitStr = bitStr.substring(entropyBits);

  final entropy = Uint8List(entropyBits ~/ 8);
  for (var i = 0; i < entropy.length; i++) {
    entropy[i] = int.parse(
      entropyBitStr.substring(i * 8, i * 8 + 8),
      radix: 2,
    );
  }

  final hash = await Sha256().hash(entropy);
  final hashBits = StringBuffer();
  for (final b in hash.bytes) {
    hashBits.write(b.toRadixString(2).padLeft(8, '0'));
  }
  final expectedChecksum = hashBits.toString().substring(0, checksumBitStr.length);
  return expectedChecksum == checksumBitStr;
}

Future<String> _entropyToMnemonic(Uint8List entropy) async {
  // Entropy bytes → bit string + appended checksum prefix.
  final entropyBits = StringBuffer();
  for (final b in entropy) {
    entropyBits.write(b.toRadixString(2).padLeft(8, '0'));
  }
  final hash = await Sha256().hash(entropy);
  final hashBits = StringBuffer();
  for (final b in hash.bytes) {
    hashBits.write(b.toRadixString(2).padLeft(8, '0'));
  }
  final checksumLen = entropy.length * 8 ~/ 32;
  final combined = entropyBits.toString() + hashBits.toString().substring(0, checksumLen);

  // Walk in 11-bit groups → wordlist indices.
  final words = <String>[];
  for (var i = 0; i < combined.length; i += 11) {
    final idx = int.parse(combined.substring(i, i + 11), radix: 2);
    words.add(bip39EnglishWordlist[idx]);
  }
  return words.join(' ');
}
