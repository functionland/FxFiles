import 'dart:convert';
import 'dart:typed_data';

// Pure construction of public-share URLs. Platform-neutral and free of
// service dependencies so the native SharingService and the web shell
// build BYTE-IDENTICAL links — the v2 payload field set and the
// /view/<id>#<fragment> shape are consumed by the cloud portal's share
// viewer, so a drifted copy would produce links that look right but
// fail to decrypt for recipients.

/// Base URL of the share portal (the pinning-service web UI).
const String kShareGatewayBaseUrl = 'https://cloud.fx.land';

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
