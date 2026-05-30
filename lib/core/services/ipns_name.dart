import 'dart:typed_data';

/// Pure, dependency-free helpers to derive an IPNS *name* (the `k51…` string)
/// from an Ed25519 public key, and to decode a name back to its raw bytes.
///
/// An IPNS name is the libp2p peer ID of the key, encoded as a CIDv1 with the
/// `libp2p-key` multicodec (0x72) and multibase `base36` (lowercase, prefix
/// `k`). For Ed25519 the peer ID uses an **identity** multihash of the
/// marshalled public-key protobuf (the key is small, so it is inlined whole and
/// no hashing happens). This matches the names produced by kubo / go-ipfs and
/// js-libp2p, and is the form public gateways resolve at
/// `https://{name}.ipns.dweb.link/`.
///
/// Byte layout that gets base36-encoded (40 bytes for Ed25519):
/// ```
///   01 72            CIDv1 version + libp2p-key codec
///   00 24            identity multihash: code 0x00, length 0x24 (36)
///   08 01 12 20      libp2p PublicKey protobuf (Type=Ed25519, Data len=32)
///   <32-byte pubkey>
/// ```
///
/// The base36 codec is the Bitcoin-style big-integer baseX (NOT RFC-4648), the
/// same algorithm `multiformats` uses for `base36btc`. It is validated in tests
/// by round-tripping a real IPNS name shipped in the app.
class IpnsName {
  IpnsName._();

  /// multibase `base36btc` alphabet (lowercase).
  static const String _base36Alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';

  /// Fixed header of a marshalled libp2p Ed25519 `PublicKey` protobuf:
  ///   field 1 (Type, varint)      = 1   -> 0x08 0x01
  ///   field 2 (Data, len-delim 32)      -> 0x12 0x20
  static const List<int> _ed25519PubKeyProtoHeader = [0x08, 0x01, 0x12, 0x20];

  /// Header bytes that precede the raw public key inside the decoded CID for an
  /// Ed25519 identity-hash libp2p-key name: CIDv1 + codec + identity multihash
  /// + pubkey protobuf header.
  static const List<int> _ed25519CidHeader = [
    0x01, 0x72, // CIDv1, libp2p-key
    0x00, 0x24, // identity multihash, length 36
    0x08, 0x01, 0x12, 0x20, // Ed25519 PublicKey protobuf header
  ];

  /// Derive the `k51…` IPNS name from a raw 32-byte Ed25519 public key.
  static String fromEd25519PublicKey(Uint8List publicKey) {
    if (publicKey.length != 32) {
      throw ArgumentError(
        'Ed25519 public key must be 32 bytes, got ${publicKey.length}',
      );
    }
    final keyProto = <int>[..._ed25519PubKeyProtoHeader, ...publicKey]; // 36
    final multihash = <int>[0x00, keyProto.length, ...keyProto]; // identity
    final cid = <int>[0x01, 0x72, ...multihash]; // CIDv1 + libp2p-key
    return 'k${_base36Encode(Uint8List.fromList(cid))}';
  }

  /// Decode an IPNS name (multibase base36, `k` prefix) back to its CID bytes.
  /// Throws [ArgumentError] if the multibase prefix isn't base36 (`k`).
  static Uint8List decodeToCidBytes(String name) {
    if (name.isEmpty || name[0] != 'k') {
      throw ArgumentError("Expected a base36 multibase name with 'k' prefix");
    }
    return _base36Decode(name.substring(1));
  }

  /// Extract the raw 32-byte Ed25519 public key encoded in [name], or null if
  /// [name] is not a well-formed Ed25519 identity-hash libp2p-key CID.
  static Uint8List? ed25519PublicKeyFromName(String name) {
    final Uint8List cid;
    try {
      cid = decodeToCidBytes(name);
    } catch (_) {
      return null;
    }
    if (cid.length != _ed25519CidHeader.length + 32) return null;
    for (var i = 0; i < _ed25519CidHeader.length; i++) {
      if (cid[i] != _ed25519CidHeader[i]) return null;
    }
    return Uint8List.sublistView(cid, _ed25519CidHeader.length);
  }

  // --- base36 (Bitcoin-style baseX, big-endian, leading-zero preserving) ---

  static String _base36Encode(Uint8List input) {
    if (input.isEmpty) return '';
    final digits = <int>[0];
    for (final byte in input) {
      var carry = byte;
      for (var j = 0; j < digits.length; j++) {
        carry += digits[j] << 8;
        digits[j] = carry % 36;
        carry = carry ~/ 36;
      }
      while (carry > 0) {
        digits.add(carry % 36);
        carry = carry ~/ 36;
      }
    }
    final sb = StringBuffer();
    for (var k = 0; k < input.length && input[k] == 0; k++) {
      sb.write(_base36Alphabet[0]); // leading zero byte -> '0'
    }
    for (var i = digits.length - 1; i >= 0; i--) {
      sb.write(_base36Alphabet[digits[i]]);
    }
    return sb.toString();
  }

  static Uint8List _base36Decode(String input) {
    if (input.isEmpty) return Uint8List(0);
    final bytes = <int>[0];
    for (var c = 0; c < input.length; c++) {
      final val = _base36Alphabet.indexOf(input[c]);
      if (val < 0) {
        throw ArgumentError('Invalid base36 character: "${input[c]}"');
      }
      var carry = val;
      for (var j = 0; j < bytes.length; j++) {
        carry += bytes[j] * 36;
        bytes[j] = carry & 0xff;
        carry >>= 8;
      }
      while (carry > 0) {
        bytes.add(carry & 0xff);
        carry >>= 8;
      }
    }
    final out = <int>[];
    for (var k = 0;
        k < input.length && input[k] == _base36Alphabet[0];
        k++) {
      out.add(0); // leading '0' -> leading zero byte
    }
    for (var i = bytes.length - 1; i >= 0; i--) {
      out.add(bytes[i]);
    }
    return Uint8List.fromList(out);
  }
}
