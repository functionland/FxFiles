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
  /// 2. POST {ipfsServer}/pins      (JSON {cid, name}) → pins for persistence
  /// 3. Build the public gateway URL from CID via the user-configured
  ///    template (defaults to dweb.link).
  Future<({String cid, String gatewayUrl})> pinFile(
    String localPath,
    String fileName,
  ) async {
    return _pin(
      await http.MultipartFile.fromPath('file', localPath,
          filename: fileName),
      fileName,
    );
  }

  /// Same flow for in-memory bytes — the web shell has no file paths
  /// (it downloads the decrypted object first, then pins the plaintext).
  Future<({String cid, String gatewayUrl})> pinBytes(
    Uint8List bytes,
    String fileName,
  ) {
    return _pin(
      http.MultipartFile.fromBytes('file', bytes, filename: fileName),
      fileName,
    );
  }

  Future<({String cid, String gatewayUrl})> _pin(
    http.MultipartFile part,
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
      ..files.add(part);

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

    // Step 2: Pin the CID via pinning service for persistence.
    //
    // PATH: `/pins`, NOT `/api/pins`. The pinning service registers exactly
    // one route for this (`openapi/go/api_pins.go`, gorilla/mux `.Path()` =
    // exact match) and nothing is mounted under `/api` except
    // `/api/v1/public-stats`; nginx forwards the URI verbatim, so `/api/pins`
    // reached the router unmatched and 404'd. `/api/pins` DOES exist — on the
    // pinning-webui BFF, a different service on a different domain, which
    // itself calls this same `/pins`. That is where the wrong path came from.
    //
    // Every public link created before this fix therefore points at an
    // UNPINNED Cid: the upload succeeded, the pin silently 404'd, and nothing
    // is keeping the data alive. Fixing the path stops the bleeding; it does
    // not re-pin what already went out.
    var pinned = false;
    try {
      final pinUri = Uri.parse('$ipfsServer/pins');
      debugPrint('IPFS pin: starting');
      final pinResponse = await http.post(
        pinUri,
        // Body stays exactly {cid, name}: the handler uses
        // DisallowUnknownFields(), so any extra field is a 400.
        headers: {
          'Authorization': 'Bearer $jwt',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'cid': cid, 'name': fileName}),
      ).timeout(const Duration(seconds: 30));
      // The IPFS pinning-service spec answers 202 Accepted, not 200 — treat
      // both as success. Checking at all is the point: this used to only
      // debugPrint the status, which is why a 404 on every single call went
      // unnoticed.
      pinned = pinResponse.statusCode == 200 || pinResponse.statusCode == 202;
      if (!pinned) {
        debugPrint('IPFS pin FAILED: HTTP ${pinResponse.statusCode} '
            'for $pinUri — the file is on IPFS but nothing is pinning it, '
            'so it can be garbage-collected.');
      } else {
        debugPrint('IPFS pin: ok (${pinResponse.statusCode})');
      }
    } catch (e) {
      debugPrint('IPFS pin FAILED (exception): $e — the file is on IPFS but '
          'unpinned.');
    }
    if (!pinned) {
      // Still non-fatal: the CID is valid and the link works right now. But
      // this is a durability problem, not a cosmetic one, so it must be
      // visible rather than swallowed.
      debugPrint('IPFS public share: link is live but NOT pinned');
    }

    // Step 3: Build the public gateway URL via the user-configured template
    // (default dweb.link) — same code path as website-generator results.
    final gatewayUrl = publicGatewayUrlForCid(cid);

    debugPrint('IPFS public share: ok');
    return (cid: cid, gatewayUrl: gatewayUrl);
  }
}
