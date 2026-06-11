import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

// Pure construction of public-share URLs. Platform-neutral and free of
// service dependencies so the native SharingService and the web shell
// build BYTE-IDENTICAL links — the v2 payload field set and the
// /view/<id>#<fragment> shape are consumed by the cloud portal's share
// viewer, so a drifted copy would produce links that look right but
// fail to decrypt for recipients.

/// Base URL of the share portal (the pinning-service web UI).
const String kShareGatewayBaseUrl = 'https://cloud.fx.land';

/// Deep-link base for recipient-specific shares — these open in the
/// native app (which holds the recipient's private key), so the link is
/// an app scheme, not an https URL.
const String kRecipientShareLinkBase = 'fxblox://share';

/// Recipient-share deep link: `fxblox://share/<ShareToken.encode()>`.
/// Same shape on every platform — the native deep-link handler parses
/// the encoded token straight off the path.
String buildRecipientShareUrl(String encodedToken, {String? baseUrl}) =>
    '${baseUrl ?? kRecipientShareLinkBase}/$encodedToken';

// ============================================================================
// FULA share IDs. A user's share ID is their X25519 public key, base64url
// without padding, prefixed "FULA-". Owners paste a recipient's share ID
// to create a recipient-specific share, so encode/decode must agree
// across native and web (moved here from AuthService, which is
// dart:io-tainted; AuthService delegates to these).
// ============================================================================

/// Public key → "FULA-…" share ID (base64url, padding stripped).
String encodeFulaShareId(Uint8List publicKey) {
  final encoded = base64UrlEncode(publicKey).replaceAll('=', '');
  return 'FULA-$encoded';
}

/// "FULA-…" share ID (or bare base64/base64url key) → public key bytes.
/// Throws [FormatException] on undecodable input.
Uint8List decodeFulaShareId(String input) {
  String keyStr = input.trim();

  if (keyStr.toUpperCase().startsWith('FULA-')) {
    keyStr = keyStr.substring(5);
  }

  try {
    final padded = _addBase64Padding(keyStr);
    final standard = padded.replaceAll('-', '+').replaceAll('_', '/');
    return base64Decode(standard);
  } catch (_) {
    return base64Decode(_addBase64Padding(keyStr));
  }
}

String _addBase64Padding(String input) {
  final remainder = input.length % 4;
  if (remainder == 0) return input;
  return input + '=' * (4 - remainder);
}

/// Assemble the v2 public-link URL.
///
/// The fragment carries the fula share token plus the DISPOSABLE link
/// secret key — fragments are never sent to servers (HTTP spec), so the
/// secret stays client-side until a recipient's browser parses it.
///
/// Field set must match the portal's parser and the native app:
///   v=2, t=fulaToken, b=bucket, k=pathScope, cid=storageKey,
///   sk=base64(linkSecretKey), l=label?, f=fileName?, folder=true?
String buildPublicShareUrl({
  required String baseUrl,
  required String tokenId,
  required String fulaToken,
  required String bucket,
  required String pathScope,
  required String storageKey,
  required Uint8List linkSecretKey,
  String? label,
  String? fileName,
  bool folder = false,
}) {
  final payloadMap = {
    'v': 2, // Version 2 = fula_client format
    't': fulaToken,
    'b': bucket,
    'k': pathScope, // Original path - used for DEK derivation
    'cid': storageKey, // Storage key/CID - used for fetching from IPFS
    'sk': base64Encode(linkSecretKey), // Secret key for decryption
    if (label != null) 'l': label,
    if (fileName != null) 'f': fileName,
    if (folder) 'folder': true,
  };
  final fragment = base64UrlEncode(utf8.encode(jsonEncode(payloadMap)));
  return '$baseUrl/view/$tokenId#$fragment';
}

// ============================================================================
// Password-protected links. The portal decrypts the inner v2 payload
// with a key derived from the user-supplied password; these parameters
// (PBKDF2-HMAC-SHA256 / 100k / 256-bit, AES-GCM-256, nonce||ct||mac
// layout, outer {v,p,s,e,b,k} shape) are wire format — native, web and
// the portal must agree byte-for-byte.
// ============================================================================

final _shareAesGcm = AesGcm.with256bits();
final _shareRandom = Random.secure();

/// PBKDF2-HMAC-SHA256, 100k iterations, 256-bit output.
Future<Uint8List> sharePasswordDeriveKey(
    String password, Uint8List salt) async {
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 100000,
    bits: 256,
  );
  final secretKey = await pbkdf2.deriveKey(
    secretKey: SecretKey(utf8.encode(password)),
    nonce: salt,
  );
  return Uint8List.fromList(await secretKey.extractBytes());
}

/// AES-GCM-256; output layout: nonce || ciphertext || mac.
Future<Uint8List> sharePasswordEncrypt(Uint8List data, Uint8List key) async {
  final secretKey = SecretKey(key);
  final nonce = _shareAesGcm.newNonce();
  final secretBox =
      await _shareAesGcm.encrypt(data, secretKey: secretKey, nonce: nonce);
  return Uint8List.fromList(
      [...nonce, ...secretBox.cipherText, ...secretBox.mac.bytes]);
}

/// Inverse of [sharePasswordEncrypt].
Future<Uint8List> sharePasswordDecrypt(
    Uint8List encryptedData, Uint8List key) async {
  final nonceLength = _shareAesGcm.nonceLength;
  final macLength = _shareAesGcm.macAlgorithm.macLength;
  final nonce = encryptedData.sublist(0, nonceLength);
  final cipherText =
      encryptedData.sublist(nonceLength, encryptedData.length - macLength);
  final mac = encryptedData.sublist(encryptedData.length - macLength);
  final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
  final decrypted =
      await _shareAesGcm.decrypt(secretBox, secretKey: SecretKey(key));
  return Uint8List.fromList(decrypted);
}

Uint8List generateShareSalt(int length) =>
    Uint8List.fromList(List.generate(length, (_) => _shareRandom.nextInt(256)));

// ============================================================================
// Share/collab manifest envelope ("ENC1"). Folder, tag and collaboration
// shares store their file manifest server-side at
// /api/share/v2/manifest/<shareId>; when the share has a link secret the
// manifest is encrypted client-side: HKDF-SHA256(linkSecret,
// info='manifest-enc-v1:<scopeId>') → AES-GCM-256 nonce||ct||mac →
// 'ENC1:'+base64. Wire format shared by native (CollaborationService
// delegates here), the web shell and the portal.
// ============================================================================

/// HKDF-SHA256 32-byte manifest key, domain-separated per scope.
Future<Uint8List> shareManifestDeriveKey(
    Uint8List linkSecret, String scopeId) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final derived = await hkdf.deriveKey(
    secretKey: SecretKey(linkSecret),
    info: utf8.encode('manifest-enc-v1:$scopeId'),
    nonce: Uint8List(0),
  );
  return Uint8List.fromList(await derived.extractBytes());
}

/// Manifest JSON → 'ENC1:{base64(nonce||ct||mac)}'.
Future<String> shareManifestEncrypt(
    Map<String, dynamic> manifest, Uint8List linkSecret, String scopeId) async {
  final key = await shareManifestDeriveKey(linkSecret, scopeId);
  final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
  final encrypted = await sharePasswordEncrypt(plaintext, key);
  return 'ENC1:${base64Encode(encrypted)}';
}

/// Inverse of [shareManifestEncrypt].
Future<Map<String, dynamic>> shareManifestDecrypt(
    String enc1Blob, Uint8List linkSecret, String scopeId) async {
  if (!enc1Blob.startsWith('ENC1:')) {
    throw ArgumentError(
        'Expected "ENC1:" prefix, got: ${enc1Blob.length > 16 ? "${enc1Blob.substring(0, 16)}..." : enc1Blob}');
  }
  final encrypted = base64Decode(enc1Blob.substring(5));
  final key = await shareManifestDeriveKey(linkSecret, scopeId);
  final decrypted =
      await sharePasswordDecrypt(Uint8List.fromList(encrypted), key);
  return jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>;
}

/// Assemble a password-protected share URL: the standard v2 inner
/// payload is AES-GCM-encrypted under the password-derived key and
/// wrapped in the outer `{v:2, p:true, s, e, b, k}` envelope. Returns
/// the URL plus the fragment and salt (native persists both for URL
/// regeneration).
Future<({String url, String fragment, Uint8List salt})>
    buildPasswordProtectedShareUrl({
  required String baseUrl,
  required String tokenId,
  required String fulaToken,
  required String bucket,
  required String pathScope,
  required String storageKey,
  required Uint8List linkSecretKey,
  required String password,
  String? label,
  String? fileName,
  bool folder = false,
}) async {
  final innerPayloadMap = {
    'v': 2,
    't': fulaToken,
    'b': bucket,
    'k': pathScope,
    'cid': storageKey,
    'sk': base64Encode(linkSecretKey),
    if (label != null) 'l': label,
    if (fileName != null) 'f': fileName,
    if (folder) 'folder': true,
  };

  final salt = generateShareSalt(16);
  final passwordKey = await sharePasswordDeriveKey(password, salt);
  final encryptedPayload = await sharePasswordEncrypt(
    Uint8List.fromList(utf8.encode(jsonEncode(innerPayloadMap))),
    passwordKey,
  );

  final outerPayload = {
    'v': 2,
    'p': true, // password protected flag
    's': base64Encode(salt),
    'e': base64Encode(encryptedPayload),
    'b': bucket,
    'k': pathScope,
  };
  final fragment = base64UrlEncode(utf8.encode(jsonEncode(outerPayload)));
  return (
    url: '$baseUrl/view/$tokenId#$fragment',
    fragment: fragment,
    salt: salt,
  );
}
