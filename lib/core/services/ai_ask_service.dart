import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/ask_ai_context.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/remote_object_resolver.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/shared/utils/tagged_file_utils.dart';

/// Extensions the Ask AI backend can actually turn into a Claude content block
/// (mirrors `detectMedia` in pinning-service/ai/src/services/claudeService.ts).
///
/// Filtering client-side matters for MONEY, not just tidiness: the route bills
/// 1500 credits per received file BEFORE Claude decides it cannot read it, so
/// uploading a `.heic` or a video costs the user credits and returns
/// "Unsupported file type for Ask AI".
const Set<String> kAskAiSupportedExtensions = <String>{
  // images
  'png', 'jpg', 'jpeg', 'gif', 'webp',
  // documents
  'pdf', 'docx', 'xlsx', 'pptx',
  // text
  'txt', 'md', 'csv', 'json', 'html', 'htm', 'xml',
};

bool _isSupportedForAskAi(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot == -1) return false;
  return kAskAiSupportedExtensions.contains(
      fileName.substring(dot + 1).toLowerCase());
}

/// True when [error] means "this object isn't here", as opposed to auth /
/// network / decryption trouble.
///
/// Only a miss justifies trying the next candidate bucket. Falling through on
/// an auth or network error would turn a transient outage into a misleading
/// "could not read your file".
///
/// Deliberately matches STORAGE-SPECIFIC forms only. A bare `not found` also
/// appears in DNS/host failures, and a bare `404` in routing or authorization
/// layers that hide objects rather than admitting they exist — either would
/// silently promote an outage into "try the next bucket".
@visibleForTesting
bool isObjectMissingError(Object error) {
  final s = error.toString().toLowerCase();
  return s.contains('object not found:') ||
      s.contains('nosuchkey') ||
      s.contains('no such key');
}

/// Why an attachment did not make it into the request.
enum AskAiSkipReason { unsupportedType, noCloudCopy, downloadFailed }

class AskAiSkippedFile {
  final String fileName;
  final AskAiSkipReason reason;

  const AskAiSkippedFile(this.fileName, this.reason);

  String get explanation => switch (reason) {
        AskAiSkipReason.unsupportedType => '$fileName (unsupported file type)',
        AskAiSkipReason.noCloudCopy => '$fileName (no cloud copy yet)',
        AskAiSkipReason.downloadFailed => '$fileName (could not be retrieved)',
      };
}

/// Outcome of an Ask AI round-trip.
///
/// [skipped] is non-empty when some requested files never reached the model.
/// The answer is still returned — one stale object out of thirty shouldn't
/// block analysis of the other twenty-nine — but the caller MUST tell the user
/// which files were left out.
class AskAiResult {
  final String response;

  /// Files for which a multipart part was actually sent. The client cannot
  /// know whether the backend then accepted each one.
  final int sentCount;

  final List<AskAiSkippedFile> skipped;

  const AskAiResult({
    required this.response,
    required this.sentCount,
    this.skipped = const <AskAiSkippedFile>[],
  });

  bool get hasSkips => skipped.isNotEmpty;
}

/// Thrown when files were requested but NOT ONE could be sent.
///
/// Raised before the request goes out, so no credits are spent and no
/// idempotency key is burned. The old behaviour sent a prompt saying "answer
/// about the following files" with nothing attached, and the model answered
/// anyway — which is how this bug stayed invisible.
class AskAiNoFilesAttachedException implements Exception {
  final List<AskAiSkippedFile> skipped;

  const AskAiNoFilesAttachedException(this.skipped);

  List<String> get fileNames => skipped.map((s) => s.fileName).toList();

  @override
  String toString() => 'No files could be attached: '
      '${skipped.map((s) => s.explanation).join(', ')}';
}

typedef ObjectDownloader = Future<Uint8List> Function(String bucket, String key);
typedef RequestSender = Future<http.StreamedResponse> Function(
    http.BaseRequest request);
typedef LocalPathResolver = Future<String?> Function({
  String? localPath,
  String? iosAssetId,
});

class AiAskService {
  static const _defaultAiEndpoint = 'https://ai.cloud.fx.land';

  final ObjectDownloader? _downloader;
  final RequestSender? _sender;
  final LocalPathResolver? _localPathResolver;
  final Future<String?> Function()? _tokenReader;
  final Future<String?> Function()? _endpointReader;

  AiAskService._()
      : _downloader = null,
        _sender = null,
        _localPathResolver = null,
        _tokenReader = null,
        _endpointReader = null;

  /// Seam for unit tests — the production path uses the singleton below.
  @visibleForTesting
  AiAskService.withOverrides({
    ObjectDownloader? downloader,
    RequestSender? sender,
    LocalPathResolver? localPathResolver,
    Future<String?> Function()? tokenReader,
    Future<String?> Function()? endpointReader,
  })  : _downloader = downloader,
        _sender = sender,
        _localPathResolver = localPathResolver,
        _tokenReader = tokenReader,
        _endpointReader = endpointReader;

  static final AiAskService instance = AiAskService._();

  final _uuid = const Uuid();

  Future<Uint8List> _download(String bucket, String key) =>
      (_downloader ?? FulaApiService.instance.downloadObject)(bucket, key);

  Future<String?> _resolveLocal(AskAiAttachment a) =>
      (_localPathResolver ?? resolveLocalFilePath)(
        localPath: a.localPath,
        iosAssetId: a.iosAssetId,
      );

  /// Ask AI about [attachments]. Generates an idempotency key and uploads the
  /// files via multipart.
  Future<AskAiResult> askAi({
    required String prompt,
    required List<AskAiAttachment> attachments,
  }) async {
    final aiEndpoint = await (_endpointReader ??
            () => SecureStorageService.instance
                .read(SecureStorageKeys.aiEndpointUrl))() ??
        _defaultAiEndpoint;
    final token = await (_tokenReader ??
        () => SecureStorageService.instance
            .read(SecureStorageKeys.jwtToken))();
    if (token == null) {
      throw Exception('Not authenticated');
    }

    final idempotencyKey = _uuid.v4();
    final uri = Uri.parse('$aiEndpoint/api/v1/ask');

    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Idempotency-Key'] = idempotencyKey
      ..fields['prompt'] = prompt;

    final skipped = <AskAiSkippedFile>[];
    var sent = 0;

    for (final attachment in attachments) {
      // Don't pay to upload something the backend will reject unread.
      if (!_isSupportedForAskAi(attachment.fileName)) {
        skipped.add(AskAiSkippedFile(
            attachment.fileName, AskAiSkipReason.unsupportedType));
        continue;
      }

      // 1. A real on-device copy is cheapest (native only — on web this
      //    returns null and we fall through to the cloud).
      final realPath = await _resolveLocal(attachment);
      if (realPath != null) {
        request.files.add(await http.MultipartFile.fromPath(
          'files',
          realPath,
          filename: attachment.fileName,
        ));
        sent++;
        continue;
      }

      // 2. Otherwise fetch it from the cloud.
      final rKey = attachment.remoteKey;
      if (rKey == null || rKey.isEmpty) {
        skipped.add(AskAiSkippedFile(
            attachment.fileName, AskAiSkipReason.noCloudCopy));
        continue;
      }
      final bytes = await _downloadAttachment(attachment, rKey);
      if (bytes == null) {
        skipped.add(AskAiSkippedFile(
            attachment.fileName, AskAiSkipReason.downloadFailed));
        continue;
      }
      request.files.add(http.MultipartFile.fromBytes(
        'files',
        bytes,
        filename: attachment.fileName,
      ));
      sent++;
    }

    // Asking "about these files" having sent none yields a confidently wrong
    // answer. Fail before spending anything.
    if (attachments.isNotEmpty && sent == 0) {
      throw AskAiNoFilesAttachedException(List.unmodifiable(skipped));
    }

    final streamedResponse =
        await (_sender ?? (http.BaseRequest r) => r.send())(request);
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final json = jsonDecode(response.body);
      if (json['response'] != null) {
        return AskAiResult(
          response: json['response'] as String,
          sentCount: sent,
          skipped: List.unmodifiable(skipped),
        );
      }
      throw Exception('Invalid response format');
    }

    String errMsg = 'Request failed with status ${response.statusCode}';
    try {
      final json = jsonDecode(response.body);
      if (json['error'] != null) errMsg = json['error'];
    } catch (_) {}
    throw Exception(errMsg);
  }

  /// Try each plausible (bucket, key) for [attachment] until one downloads.
  ///
  /// `remoteKey` alone is ambiguous — bare for app-written objects, composite
  /// `bucket/key` for web-written ones — so the resolver returns an ordered
  /// candidate list rather than a single guess. A candidate is only skipped
  /// when the object is genuinely absent; any other error aborts and is
  /// rethrown so a transient outage isn't reported as a missing file.
  Future<Uint8List?> _downloadAttachment(
      AskAiAttachment attachment, String rKey) async {
    final candidates = resolveRemoteObjectCandidates(
      remoteKey: rKey,
      fileName: attachment.fileName,
      sourceBucket: attachment.sourceBucket,
      fallbackBase: attachment.fallbackBucketBase,
    );
    if (candidates.isEmpty) {
      debugPrint('AiAskService: no bucket candidates for '
          '"${attachment.fileName}" (remoteKey: $rKey)');
      return null;
    }

    for (final candidate in candidates) {
      try {
        return await _download(candidate.bucket, candidate.key);
      } catch (e) {
        if (!isObjectMissingError(e)) rethrow;
      }
    }

    debugPrint('AiAskService: "${attachment.fileName}" not found in any of '
        '${candidates.join(', ')}');
    return null;
  }
}
