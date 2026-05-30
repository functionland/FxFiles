// Live end-to-end verification for the IPNS stable-link record (Phase 2).
//
// Generates a throwaway Ed25519 key, publishes a signed IPNS V2 record to
// w3name, reads it back, and verifies the service accepted it and resolves the
// name to the expected CID — then publishes a second CID and confirms the
// update propagates and the sequence advanced. Exercises the real validator
// (w3name) and the real record/wire format, which unit tests cannot.
//
// Run:  dart run tool/ipns_publish_check.dart
// Requires network access to https://name.web3.storage. Uses a random key, so
// it leaves only an innocuous, expiring test record (random name -> sample CID).

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'package:fula_files/core/services/ipns_name.dart';
import 'package:fula_files/core/services/ipns_record.dart';

const String endpoint = 'https://name.web3.storage';
const String cidA =
    'bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi';
const String cidB =
    'bafybeibml5jw3goui3rzefz35rffjkrxjgkpjffd2ypc43xq53ntqzu33a';

void main() async {
  final keyPair = await Ed25519().newKeyPair();
  final pub = Uint8List.fromList((await keyPair.extractPublicKey()).bytes);
  final name = IpnsName.fromEd25519PublicKey(pub);
  print('IPNS name: $name');
  print('Resolve URL: $endpoint/name/$name');
  print('Gateway URL: https://$name.ipns.dweb.link/');
  print('');

  Future<void> publish(String cid, int seq) async {
    final record =
        await IpnsRecord.build(keyPair: keyPair, cid: cid, sequence: seq);
    final ok = await IpnsRecord.verify(record, pub);
    print('  built seq=$seq, ${record.length} bytes, self-verify=$ok');
    final resp = await http
        .post(Uri.parse('$endpoint/name/$name'), body: base64.encode(record))
        .timeout(const Duration(seconds: 30));
    print('  POST -> ${resp.statusCode} ${resp.body.isEmpty ? '' : resp.body}');
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('publish failed');
    }
  }

  // Returns (value, sequence-parsed-from-the-live-record).
  Future<(String, int?)> resolve() async {
    final resp = await http
        .get(Uri.parse('$endpoint/name/$name'))
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw Exception('resolve failed: ${resp.statusCode} ${resp.body}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final value = json['value'] as String? ?? '(no value)';
    final recordB64 = json['record'] as String?;
    final seq = recordB64 == null
        ? null
        : IpnsRecord.sequenceOf(base64.decode(recordB64));
    return (value, seq);
  }

  print('Publish #1 ($cidA)...');
  await publish(cidA, 0);
  final (v1, s1) = await resolve();
  print('  resolved value: $v1   sequence: $s1');
  final pass1 = v1 == '/ipfs/$cidA' && s1 == 0;
  print('  EXPECT /ipfs/$cidA + seq 0 -> ${pass1 ? 'PASS' : 'FAIL'}');
  print('');

  print('Publish #2 / update ($cidB)...');
  await publish(cidB, 1);
  final (v2, s2) = await resolve();
  print('  resolved value: $v2   sequence: $s2');
  final pass2 = v2 == '/ipfs/$cidB' && s2 == 1;
  print('  EXPECT /ipfs/$cidB + seq 1 -> ${pass2 ? 'PASS' : 'FAIL'}');
  print('');

  print(pass1 && pass2
      ? 'RESULT: PASS — record accepted, update resolved, sequence parsed from '
          'the live record (fetch-before-publish anchor works).'
      : 'RESULT: FAIL');
}
