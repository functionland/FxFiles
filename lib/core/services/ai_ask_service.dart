import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/shared/utils/tagged_file_utils.dart';

class AiAskService {
  AiAskService._();
  static final AiAskService instance = AiAskService._();

  static const _defaultAiEndpoint = 'https://ai.cloud.fx.land';
  final _uuid = const Uuid();

  /// Ask AI about the given files. Generates an idempotency key and uploads the files via multipart.
  Future<String> askAi({
    required String prompt,
    required List<TaggedFile> files,
  }) async {
    final aiEndpoint = await SecureStorageService.instance.read(SecureStorageKeys.aiEndpointUrl) ?? _defaultAiEndpoint;
    final token = await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    if (token == null) {
      throw Exception('Not authenticated');
    }

    final idempotencyKey = _uuid.v4();
    final uri = Uri.parse('$aiEndpoint/api/v1/ask');

    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Idempotency-Key'] = idempotencyKey
      ..fields['prompt'] = prompt;

    for (final file in files) {
      final realPath = await resolveTaggedFilePath(file);
      if (realPath != null) {
        request.files.add(await http.MultipartFile.fromPath(
          'files', 
          realPath,
          filename: file.fileName,
        ));
      } else if (file.remoteKey != null && file.remoteKey!.isNotEmpty) {
        final rKey = file.remoteKey!;
        String bucket;
        String key;
        
        if (rKey.contains('/')) {
          final parts = rKey.split('/');
          bucket = parts.first;
          key = parts.skip(1).join('/');
        } else {
          bucket = BucketVersionResolver.writeBucket('files');
          key = rKey;
        }

        try {
          final data = await FulaApiService.instance.downloadObject(bucket, key);
          request.files.add(http.MultipartFile.fromBytes(
            'files', 
            data,
            filename: file.fileName,
          ));
        } catch (e) {
          debugPrint('AiAskService: Failed to download remote file ${file.fileName}: $e');
        }
      }
    }

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final json = jsonDecode(response.body);
      if (json['response'] != null) {
        return json['response'] as String;
      }
      throw Exception('Invalid response format');
    } else {
      String errMsg = 'Request failed with status ${response.statusCode}';
      try {
        final json = jsonDecode(response.body);
        if (json['error'] != null) errMsg = json['error'];
      } catch (_) {}
      throw Exception(errMsg);
    }
  }
}
