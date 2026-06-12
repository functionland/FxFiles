import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// HKDF-SHA256 (RFC 5869) — pure Dart so it unit-tests on the VM. Used
/// by the web listing cache to derive its AES-GCM key from the session
/// KEK; the KEK itself is never handed to WebCrypto.
///
/// extract: PRK = HMAC-SHA256(salt, ikm)
/// expand:  T(i) = HMAC-SHA256(PRK, T(i-1) | info | i)
Uint8List hkdfSha256(
  List<int> ikm, {
  required List<int> salt,
  required List<int> info,
  int length = 32,
}) {
  if (length <= 0 || length > 255 * 32) {
    throw ArgumentError.value(length, 'length');
  }
  final prk = Hmac(sha256, salt).convert(ikm).bytes;
  final hmac = Hmac(sha256, prk);
  final out = BytesBuilder(copy: false);
  var t = const <int>[];
  var i = 1;
  while (out.length < length) {
    t = hmac.convert([...t, ...info, i]).bytes;
    out.add(t);
    i++;
  }
  return Uint8List.fromList(out.toBytes().sublist(0, length));
}
