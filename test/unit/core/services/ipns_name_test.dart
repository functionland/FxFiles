import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/ipns_name.dart';

void main() {
  group('IpnsName', () {
    // A real IPNS name shipped in the app (the users-index name in
    // fula_api_service.dart `kUsersIndexIpnsName`). It was produced by
    // kubo/go-ipfs, so round-tripping it validates our base36 codec and CID
    // structure against a real-world value rather than a synthetic one.
    const realName =
        'k51qzi5uqu5dkkd6tv8slgoouzzs505qdcr4cb5egc9rlx7qwq0e794yxj9cg4';

    test('decodes a real IPNS name to the expected CID structure', () {
      final cid = IpnsName.decodeToCidBytes(realName);
      // 01 72 | 00 24 | 08 01 12 20 | <32-byte pubkey>  => 40 bytes
      expect(cid.length, 40);
      expect(
        cid.sublist(0, 8),
        [0x01, 0x72, 0x00, 0x24, 0x08, 0x01, 0x12, 0x20],
      );
    });

    test('round-trips a real IPNS name: decode -> pubkey -> re-derive', () {
      final pub = IpnsName.ed25519PublicKeyFromName(realName);
      expect(pub, isNotNull);
      expect(pub!.length, 32);
      // Re-deriving the name from the extracted public key must reproduce the
      // exact original string — this is the end-to-end codec check.
      expect(IpnsName.fromEd25519PublicKey(pub), realName);
    });

    test('derives a k51 name and round-trips structurally', () {
      // Arbitrary 32-byte value: we are testing the byte codec, not curve
      // validity. The leading CID bytes are fixed, so any Ed25519 name starts
      // with the same prefix as real names.
      final pub = Uint8List.fromList(
        List<int>.generate(32, (i) => (i * 7 + 3) & 0xff),
      );
      final name = IpnsName.fromEd25519PublicKey(pub);
      expect(name.startsWith('k51'), isTrue);
      expect(IpnsName.ed25519PublicKeyFromName(name), pub);
    });

    test('round-trips a real Ed25519 keypair end-to-end', () async {
      final keyPair = await Ed25519().newKeyPairFromSeed(
        Uint8List.fromList(List<int>.filled(32, 7)),
      );
      final pub =
          Uint8List.fromList((await keyPair.extractPublicKey()).bytes);
      final name = IpnsName.fromEd25519PublicKey(pub);
      expect(name[0], 'k');
      expect(IpnsName.ed25519PublicKeyFromName(name), pub);
    });

    test('rejects a non-32-byte public key', () {
      expect(
        () => IpnsName.fromEd25519PublicKey(Uint8List(31)),
        throwsArgumentError,
      );
    });

    test('returns null for a non-base36 name', () {
      // CIDv1 base32 names start with 'b'; not a libp2p-key base36 name.
      expect(IpnsName.ed25519PublicKeyFromName('bafy...'), isNull);
    });
  });
}
