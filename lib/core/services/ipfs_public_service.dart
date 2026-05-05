import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:fula_files/core/models/website_generation.dart'
    show publicGatewayUrlForCid;
import 'package:fula_files/core/services/secure_storage_service.dart';

class IpfsPublicService {
  IpfsPublicService._();
  static final instance = IpfsPublicService._();

  static const String _defaultIpfsEndpoint = 'https://ipfs.cloud.fx.land';
  static const String _defaultIpfsServer = 'https://api.cloud.fx.land';

  /// Upload a file publicly to IPFS and pin it.
  ///
  /// 1. POST {ipfsEndpoint}/upload  (multipart file) → returns CID
  /// 2. POST {ipfsServer}/api/pins  (JSON {cid, name}) → pins for persistence
  /// 3. Build public dweb.link gateway URL from CID (NOT the configured local
  ///    gateway — public shares must resolve from any device).
  Future<({String cid, String gatewayUrl})> pinFile(
    String localPath,
    String fileName,
  ) async {
    final ipfsEndpoint = await SecureStorageService.instance
            .read(SecureStorageKeys.ipfsEndpointUrl) ??
        _defaultIpfsEndpoint;
    final ipfsServer = await SecureStorageService.instance
            .read(SecureStorageKeys.ipfsServerUrl) ??
        _defaultIpfsServer;
    final jwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);

    if (jwt == null || jwt.isEmpty) {
      throw Exception(
          'No API key configured. Please set your API key in Settings.');
    }

    // Step 1: Upload file to IPFS endpoint to get CID
    final uploadUri = Uri.parse('$ipfsEndpoint/upload');
    debugPrint('IPFS upload: starting');
    final request = http.MultipartRequest('POST', uploadUri)
      ..headers['Authorization'] = 'Bearer $jwt'
      ..files.add(
          await http.MultipartFile.fromPath('file', localPath,
              filename: fileName));

    final streamed = await request.send().timeout(const Duration(minutes: 5));
    final body = await streamed.stream
        .bytesToString()
        .timeout(const Duration(minutes: 5));

    if (streamed.statusCode != 200) {
      throw Exception('Upload failed (${streamed.statusCode})');
    }

    final uploadJson = jsonDecode(body.trim()) as Map<String, dynamic>;
    final cid = uploadJson['cid'] as String?;
    if (cid == null || cid.isEmpty) {
      throw Exception('Upload succeeded but no CID returned');
    }
    debugPrint('IPFS upload: ok');

    // Step 2: Pin the CID via pinning service for persistence
    try {
      final pinUri = Uri.parse('$ipfsServer/api/pins');
      debugPrint('IPFS pin: starting');
      final pinResponse = await http.post(
        pinUri,
        headers: {
          'Authorization': 'Bearer $jwt',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'cid': cid, 'name': fileName}),
      ).timeout(const Duration(seconds: 30));
      debugPrint('IPFS pin: status ${pinResponse.statusCode}');
    } catch (e) {
      // Pin failure is non-fatal — the file is already on IPFS
      debugPrint('IPFS pin failed (non-fatal)');
    }

    // Step 3: Build public gateway URL using the dweb.link subdomain gateway
    // — the same gateway used for website-generator results — so the link
    // resolves from any device regardless of the user's local gateway setting.
    final gatewayUrl = publicGatewayUrlForCid(cid);

    debugPrint('IPFS public share: ok');
    return (cid: cid, gatewayUrl: gatewayUrl);
  }
}
