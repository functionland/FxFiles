import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Builds and serialises an **IPNS V2 record** — the signed pointer published to
/// the w3name service / IPFS for a stable per-group link.
///
/// Hand-encodes both the DAG-CBOR `data` field and the `IpnsEntry` protobuf so
/// we control canonical determinism exactly and avoid pulling in
/// protobuf/cborg/codegen dependencies (this repo is deliberately dep-minimal).
///
/// Layout (validated against specs.ipfs.tech/ipns/ipns-record + js-ipns, and
/// confirmed end-to-end: w3name accepts the record and resolves the name to the
/// CID, including after a sequence-incremented update):
///  * `data` = DAG-CBOR map, keys in canonical (length-then-bytewise) order:
///    `TTL`(uint), `Value`(bytes), `Sequence`(uint), `Validity`(bytes),
///    `ValidityType`(uint). `Value` = `/ipfs/<cid>` UTF-8; `Validity` =
///    RFC3339-nanos EOL UTF-8.
///  * signature = Ed25519 over `"ipns-signature:"` ++ `data` → protobuf field 8.
///  * `IpnsEntry` protobuf sets fields 1 value, 3 validityType, 4 validity,
///    5 sequence, 6 ttl, 8 signatureV2, 9 data. Fields 2 (signatureV1) and
///    7 (pubKey) are omitted — for Ed25519 the key is embedded in the name.
///
/// The protobuf scalar fields (1/3/4/5/6) are kept strictly equal to their CBOR
/// `data` counterparts (strict validators cross-check them); both are built
/// from the same locals, so they cannot desync.
class IpnsRecord {
  IpnsRecord._();

  /// ASCII prefix the V2 signature covers, ahead of the raw CBOR `data` bytes.
  static const String signaturePrefix = 'ipns-signature:';

  /// EOL — the only IPNS validity type.
  static const int validityTypeEol = 0;

  static final Ed25519 _ed25519 = Ed25519();

  /// Build the marshalled `IpnsEntry` protobuf bytes mapping the key's name to
  /// `/ipfs/{cid}`.
  ///
  /// [sequence] MUST be non-negative and strictly greater than any value
  /// previously published for this key (older-or-equal records are ignored by
  /// resolvers). [ttl] is a resolver cache hint (kept short so regenerations
  /// propagate); [lifetime] is the EOL after which the record expires (kept
  /// long so a shared link survives between regenerations — safe because the
  /// app fetches the live sequence before each publish, so a long-lived old
  /// record can never strand a fresh one).
  static Future<Uint8List> build({
    required SimpleKeyPair keyPair,
    required String cid,
    required int sequence,
    Duration ttl = const Duration(minutes: 1),
    Duration lifetime = const Duration(days: 3650),
    DateTime? now,
  }) async {
    if (sequence < 0) {
      throw ArgumentError.value(sequence, 'sequence', 'must be non-negative');
    }
    final value = Uint8List.fromList(utf8.encode('/ipfs/$cid'));
    final eol = (now ?? DateTime.now()).toUtc().add(lifetime);
    final validity = Uint8List.fromList(ascii.encode(_formatRfc3339Nanos(eol)));
    final ttlNs = ttl.inMicroseconds * 1000;

    final data = _encodeCborData(
      value: value,
      validity: validity,
      sequence: sequence,
      ttlNs: ttlNs,
    );

    final signingInput = Uint8List.fromList(
      <int>[...ascii.encode(signaturePrefix), ...data],
    );
    final signature = await _ed25519.sign(signingInput, keyPair: keyPair);
    final signatureV2 = Uint8List.fromList(signature.bytes);

    return _marshalIpnsEntry(
      value: value,
      validity: validity,
      sequence: sequence,
      ttlNs: ttlNs,
      signatureV2: signatureV2,
      data: data,
    );
  }

  /// Defensive self-check + test hook: re-parse a marshalled record, rebuild the
  /// signing input from its `data` field, and verify the Ed25519 signature
  /// against [ed25519PublicKey] (the 32 bytes embedded in the IPNS name).
  static Future<bool> verify(
    Uint8List recordBytes,
    Uint8List ed25519PublicKey,
  ) async {
    final fields = _scanProtobuf(recordBytes);
    final data = fields[9];
    final sig = fields[8];
    if (data == null || sig == null || sig.length != 64) return false;
    final signingInput = Uint8List.fromList(
      <int>[...ascii.encode(signaturePrefix), ...data],
    );
    return _ed25519.verify(
      signingInput,
      signature: Signature(
        sig,
        publicKey: SimplePublicKey(ed25519PublicKey, type: KeyPairType.ed25519),
      ),
    );
  }

  /// Read the protobuf `sequence` (field 5, uint64 varint) from a marshalled
  /// record, or null if absent/malformed. Used for fetch-before-publish so the
  /// app can out-sequence whatever record is currently live.
  static int? sequenceOf(Uint8List recordBytes) {
    var i = 0;
    int readVarint() {
      var result = 0;
      var shift = 0;
      while (i < recordBytes.length && shift < 64) {
        final byte = recordBytes[i++];
        result |= (byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) break;
        shift += 7;
      }
      return result;
    }

    while (i < recordBytes.length) {
      final tag = readVarint();
      final field = tag >> 3;
      final wire = tag & 0x7;
      if (wire == 0) {
        final v = readVarint();
        if (field == 5) return v;
      } else if (wire == 2) {
        final len = readVarint();
        if (i + len > recordBytes.length) break;
        i += len;
      } else if (wire == 5) {
        i += 4;
      } else if (wire == 1) {
        i += 8;
      } else {
        break;
      }
    }
    return null;
  }

  // --- RFC3339 with nanosecond precision (whole-second EOL, zero nanos) ---

  static String _formatRfc3339Nanos(DateTime dtUtc) {
    final d = dtUtc.toUtc();
    String p(int v, int w) => v.toString().padLeft(w, '0');
    return '${p(d.year, 4)}-${p(d.month, 2)}-${p(d.day, 2)}'
        'T${p(d.hour, 2)}:${p(d.minute, 2)}:${p(d.second, 2)}.000000000Z';
  }

  // --- DAG-CBOR data field (canonical: keys length-then-bytewise) ---

  static Uint8List _encodeCborData({
    required Uint8List value,
    required Uint8List validity,
    required int sequence,
    required int ttlNs,
  }) {
    final b = BytesBuilder();
    b.addByte(0xA0 | 5); // map, 5 pairs
    // Canonical key order (cborg default = length-then-bytewise on encoded
    // keys): TTL(3) < Value(5) < Sequence(8,'S') < Validity(8,'V') <
    // ValidityType(12).
    _cborTextKey(b, 'TTL');
    _cborUint(b, ttlNs);
    _cborTextKey(b, 'Value');
    _cborByteString(b, value);
    _cborTextKey(b, 'Sequence');
    _cborUint(b, sequence);
    _cborTextKey(b, 'Validity');
    _cborByteString(b, validity);
    _cborTextKey(b, 'ValidityType');
    _cborUint(b, validityTypeEol);
    return b.toBytes();
  }

  static void _cborTextKey(BytesBuilder b, String key) {
    final bytes = ascii.encode(key);
    // All IPNS data keys are < 24 chars -> single-byte major-3 header.
    b.addByte(0x60 | bytes.length);
    b.add(bytes);
  }

  static void _cborByteString(BytesBuilder b, Uint8List bytes) {
    _cborHead(b, 0x40, bytes.length); // major type 2
    b.add(bytes);
  }

  static void _cborUint(BytesBuilder b, int value) {
    _cborHead(b, 0x00, value); // major type 0
  }

  // --- protobuf (unsigned LEB128 varints; ascending field order) ---

  static Uint8List _marshalIpnsEntry({
    required Uint8List value,
    required Uint8List validity,
    required int sequence,
    required int ttlNs,
    required Uint8List signatureV2,
    required Uint8List data,
  }) {
    final b = BytesBuilder();
    _pbBytesField(b, 1, value); // value
    _pbVarintField(b, 3, validityTypeEol); // validityType (enum)
    _pbBytesField(b, 4, validity); // validity
    _pbVarintField(b, 5, sequence); // sequence (uint64)
    _pbVarintField(b, 6, ttlNs); // ttl (uint64)
    _pbBytesField(b, 8, signatureV2); // signatureV2
    _pbBytesField(b, 9, data); // data (DAG-CBOR)
    return b.toBytes();
  }

  static void _pbBytesField(BytesBuilder b, int field, Uint8List bytes) {
    _pbVarint(b, (field << 3) | 2); // wire type 2 (length-delimited)
    _pbVarint(b, bytes.length);
    b.add(bytes);
  }

  static void _pbVarintField(BytesBuilder b, int field, int value) {
    _pbVarint(b, (field << 3) | 0); // wire type 0 (varint)
    _pbVarint(b, value);
  }

  static void _pbVarint(BytesBuilder b, int value) {
    // Negative values would sign-extend under Dart's arithmetic `>>` and loop
    // forever; reject loudly (callers pass tags/lengths/sequence/ttl — all
    // non-negative).
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'varint must be non-negative');
    }
    var n = value;
    while (true) {
      final byte = n & 0x7f;
      n >>= 7;
      if (n != 0) {
        b.addByte(byte | 0x80);
      } else {
        b.addByte(byte);
        break;
      }
    }
  }

  /// Minimal-length CBOR head for [major] (0x00 uint, 0x40 bytes, 0x60 text)
  /// carrying argument [n] (the value for uints, the length for strings).
  static void _cborHead(BytesBuilder b, int major, int n) {
    if (n < 0) {
      throw ArgumentError.value(n, 'n', 'CBOR argument must be non-negative');
    }
    if (n < 24) {
      b.addByte(major | n);
    } else if (n <= 0xFF) {
      b.addByte(major | 24);
      b.addByte(n);
    } else if (n <= 0xFFFF) {
      b.addByte(major | 25);
      b.addByte((n >> 8) & 0xff);
      b.addByte(n & 0xff);
    } else if (n <= 0xFFFFFFFF) {
      b.addByte(major | 26);
      b.addByte((n >> 24) & 0xff);
      b.addByte((n >> 16) & 0xff);
      b.addByte((n >> 8) & 0xff);
      b.addByte(n & 0xff);
    } else {
      b.addByte(major | 27);
      for (var shift = 56; shift >= 0; shift -= 8) {
        b.addByte((n >> shift) & 0xff);
      }
    }
  }

  // --- minimal protobuf field scanner (for verify/tests) ---

  /// Scan top-level protobuf fields, returning the bytes of wire-type-2 fields
  /// keyed by field number (later occurrences win). Varint/other fields are
  /// skipped. Sufficient to pull out `data` (9) and `signatureV2` (8).
  static Map<int, Uint8List> _scanProtobuf(Uint8List bytes) {
    final out = <int, Uint8List>{};
    var i = 0;
    int readVarint() {
      var result = 0;
      var shift = 0;
      while (i < bytes.length && shift < 64) {
        final byte = bytes[i++];
        result |= (byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) break;
        shift += 7;
      }
      return result;
    }

    while (i < bytes.length) {
      final tag = readVarint();
      final field = tag >> 3;
      final wire = tag & 0x7;
      if (wire == 2) {
        final len = readVarint();
        if (i + len > bytes.length) break;
        out[field] = Uint8List.sublistView(bytes, i, i + len);
        i += len;
      } else if (wire == 0) {
        readVarint();
      } else if (wire == 5) {
        i += 4;
      } else if (wire == 1) {
        i += 8;
      } else {
        break; // unsupported wire type
      }
    }
    return out;
  }
}
