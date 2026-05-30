import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/ipns_name.dart';
import 'package:fula_files/core/services/ipns_record.dart';

/// Minimal top-level protobuf scanner (wire types 0 and 2) for assertions —
/// independent of the production scanner so the test validates the wire format
/// from scratch.
Map<int, Uint8List> _scan(Uint8List bytes) {
  final out = <int, Uint8List>{};
  var i = 0;
  int readVarint() {
    var r = 0, s = 0;
    while (i < bytes.length) {
      final b = bytes[i++];
      r |= (b & 0x7f) << s;
      if ((b & 0x80) == 0) break;
      s += 7;
    }
    return r;
  }

  while (i < bytes.length) {
    final tag = readVarint();
    final field = tag >> 3;
    final wire = tag & 0x7;
    if (wire == 2) {
      final len = readVarint();
      out[field] = Uint8List.sublistView(bytes, i, i + len);
      i += len;
    } else if (wire == 0) {
      readVarint();
    } else {
      break;
    }
  }
  return out;
}

void main() {
  group('IpnsRecord', () {
    late SimpleKeyPair kp;
    late Uint8List pub;
    const cid =
        'bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi';

    setUp(() async {
      kp = await Ed25519()
          .newKeyPairFromSeed(Uint8List.fromList(List<int>.filled(32, 9)));
      pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    });

    test('built record self-verifies against the public key', () async {
      final rec = await IpnsRecord.build(keyPair: kp, cid: cid, sequence: 0);
      expect(await IpnsRecord.verify(rec, pub), isTrue);
    });

    test('tampered record fails verification', () async {
      final rec = await IpnsRecord.build(keyPair: kp, cid: cid, sequence: 1);
      final bad = Uint8List.fromList(rec);
      bad[bad.length - 1] ^= 0x01; // flip a bit in the tail
      expect(await IpnsRecord.verify(bad, pub), isFalse);
    });

    test('protobuf carries V2 fields and omits signatureV1 / pubKey', () async {
      final rec = await IpnsRecord.build(keyPair: kp, cid: cid, sequence: 2);
      final f = _scan(rec);
      expect(f.containsKey(1), isTrue, reason: 'value');
      expect(f.containsKey(4), isTrue, reason: 'validity');
      expect(f.containsKey(8), isTrue, reason: 'signatureV2');
      expect(f[8]!.length, 64, reason: 'ed25519 signature is 64 bytes');
      expect(f.containsKey(9), isTrue, reason: 'data');
      expect(f.containsKey(2), isFalse, reason: 'no signatureV1');
      expect(f.containsKey(7), isFalse, reason: 'no pubKey for ed25519');
    });

    test('CBOR data is a 5-entry map with TTL as the first canonical key',
        () async {
      final rec = await IpnsRecord.build(keyPair: kp, cid: cid, sequence: 0);
      final data = _scan(rec)[9]!;
      expect(data[0], 0xA5, reason: 'CBOR map header for 5 pairs');
      expect(data[1], 0x63, reason: 'text string of length 3');
      expect(String.fromCharCodes(data.sublist(2, 5)), 'TTL');
    });

    test('value field encodes the /ipfs/<cid> path', () async {
      final rec = await IpnsRecord.build(keyPair: kp, cid: cid, sequence: 0);
      expect(utf8.decode(_scan(rec)[1]!), '/ipfs/$cid');
    });

    test('the name derived from the keypair round-trips to the public key',
        () {
      final name = IpnsName.fromEd25519PublicKey(pub);
      expect(IpnsName.ed25519PublicKeyFromName(name), pub);
    });

    test('sequenceOf reads back the protobuf sequence field', () async {
      final rec = await IpnsRecord.build(keyPair: kp, cid: cid, sequence: 42);
      expect(IpnsRecord.sequenceOf(rec), 42);
      final rec0 = await IpnsRecord.build(keyPair: kp, cid: cid, sequence: 0);
      expect(IpnsRecord.sequenceOf(rec0), 0);
    });

    test('build rejects a negative sequence', () async {
      await expectLater(
        IpnsRecord.build(keyPair: kp, cid: cid, sequence: -1),
        throwsArgumentError,
      );
    });
  });
}
