import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fula_files/core/models/ask_ai_context.dart';
import 'package:fula_files/core/services/ai_ask_service.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';

/// Records what the uploader actually attempted, so a test can assert on the
/// buckets probed and the multipart parts produced.
class _Recorder {
  final List<String> probed = <String>[];
  final List<http.MultipartRequest> sent = <http.MultipartRequest>[];

  /// bucket|key -> bytes. Anything absent behaves like a real object miss.
  final Map<String, Uint8List> objects;

  /// bucket|key -> error to throw instead of a miss.
  final Map<String, Object> hardErrors;

  _Recorder({
    Map<String, Uint8List>? objects,
    Map<String, Object>? hardErrors,
  })  : objects = objects ?? <String, Uint8List>{},
        hardErrors = hardErrors ?? <String, Object>{};

  Future<Uint8List> download(String bucket, String key) async {
    final id = '$bucket|$key';
    probed.add(id);
    final hard = hardErrors[id];
    if (hard != null) throw hard;
    final data = objects[id];
    if (data == null) {
      throw Exception('Failed to download object: '
          'AnyhowException(Object not found: $key)');
    }
    return data;
  }

  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(request as http.MultipartRequest);
    final body = jsonEncode({'response': 'ok'});
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
    );
  }
}

void main() {
  setUp(() => BucketVersionResolver.enabled = true);
  tearDown(() => BucketVersionResolver.enabled = true);

  AiAskService serviceFor(_Recorder rec) => AiAskService.withOverrides(
        downloader: rec.download,
        sender: rec.send,
        // Web behaviour by default: no local file ever resolves.
        localPathResolver: ({String? localPath, String? iosAssetId}) async =>
            null,
        tokenReader: () async => 'test-token',
        endpointReader: () async => 'https://ai.example.test',
      );

  List<String> partNames(http.MultipartRequest r) =>
      r.files.map((f) => f.filename ?? '').toList();

  group('the shelf regression', () {
    test('a year-prefixed shelf key resolves to dump-v8, never "2026"',
        () async {
      final rec = _Recorder(objects: {
        'dump-v8|2026/07/abc-report.pdf': Uint8List.fromList([1, 2, 3]),
      });

      final result = await serviceFor(rec).askAi(
        prompt: 'what is this?',
        attachments: const [
          AskAiAttachment(
            fileName: 'report.pdf',
            remoteKey: '2026/07/abc-report.pdf',
            sourceBucket: 'dump-v8',
            fallbackBucketBase: 'dump',
          ),
        ],
      );

      expect(rec.probed, isNot(contains(startsWith('2026|'))));
      expect(rec.probed.first, 'dump-v8|2026/07/abc-report.pdf');
      expect(result.sentCount, 1);
      expect(result.skipped, isEmpty);
      expect(partNames(rec.sent.single), ['report.pdf']);
    });

    test('a pre-P7 shelf row falls through to legacy dump', () async {
      final rec = _Recorder(objects: {
        'dump|2025/03/old-notes.pdf': Uint8List.fromList([9]),
      });

      final result = await serviceFor(rec).askAi(
        prompt: 'q',
        attachments: const [
          AskAiAttachment(
            fileName: 'notes.pdf',
            remoteKey: '2025/03/old-notes.pdf',
            // ShelfAskAiContext maps a null sourceBucket to legacy 'dump'.
            sourceBucket: 'dump',
            fallbackBucketBase: 'dump',
          ),
        ],
      );

      expect(result.sentCount, 1);
      expect(rec.probed, contains('dump|2025/03/old-notes.pdf'));
    });

    test('a bare tag key never probes the invented "files" bucket', () async {
      final rec = _Recorder(objects: {
        'images|photo.jpg': Uint8List.fromList([7]),
      });

      final result = await serviceFor(rec).askAi(
        prompt: 'q',
        attachments: const [
          AskAiAttachment(fileName: 'photo.jpg', remoteKey: 'photo.jpg'),
        ],
      );

      expect(rec.probed, isNot(contains(startsWith('files|'))));
      expect(rec.probed, ['images-v8|photo.jpg', 'images|photo.jpg']);
      expect(result.sentCount, 1);
    });
  });

  group('zero attachable files', () {
    test('never sends the request, so nothing is billed', () async {
      final rec = _Recorder(); // every object missing

      await expectLater(
        serviceFor(rec).askAi(
          prompt: 'q',
          attachments: const [
            AskAiAttachment(
              fileName: 'gone.pdf',
              remoteKey: '2026/07/x-gone.pdf',
              sourceBucket: 'dump-v8',
            ),
          ],
        ),
        throwsA(isA<AskAiNoFilesAttachedException>()),
      );

      expect(rec.sent, isEmpty, reason: 'must abort before send/billing');
    });

    test('a prompt-only shelf link still sends (the legitimate zero case)',
        () async {
      final rec = _Recorder();

      final result = await serviceFor(rec).askAi(
        prompt: 'summarise this link',
        attachments: const <AskAiAttachment>[],
      );

      expect(result.sentCount, 0);
      expect(rec.sent, hasLength(1));
      expect(rec.sent.single.files, isEmpty);
    });
  });

  group('partial failure', () {
    test('sends what it can and reports what it could not', () async {
      final rec = _Recorder(objects: {
        'images-v8|good.jpg': Uint8List.fromList([1]),
      });

      final result = await serviceFor(rec).askAi(
        prompt: 'q',
        attachments: const [
          AskAiAttachment(fileName: 'good.jpg', remoteKey: 'good.jpg'),
          AskAiAttachment(fileName: 'bad.jpg', remoteKey: 'bad.jpg'),
        ],
      );

      expect(result.sentCount, 1);
      expect(result.skipped.map((s) => s.fileName), ['bad.jpg']);
      expect(result.skipped.single.reason, AskAiSkipReason.downloadFailed);
      expect(partNames(rec.sent.single), ['good.jpg']);
    });

    test('a file with no cloud copy is reported, not silently dropped',
        () async {
      final rec = _Recorder(objects: {
        'images-v8|good.jpg': Uint8List.fromList([1]),
      });

      final result = await serviceFor(rec).askAi(
        prompt: 'q',
        attachments: const [
          AskAiAttachment(fileName: 'good.jpg', remoteKey: 'good.jpg'),
          AskAiAttachment(fileName: 'local-only.jpg'),
        ],
      );

      expect(result.skipped.single.reason, AskAiSkipReason.noCloudCopy);
    });
  });

  group('unsupported types are not uploaded', () {
    test('a video is skipped client-side rather than billed', () async {
      final rec = _Recorder(objects: {
        'videos-v8|clip.mp4': Uint8List.fromList([1]),
        'images-v8|shot.jpg': Uint8List.fromList([2]),
      });

      final result = await serviceFor(rec).askAi(
        prompt: 'q',
        attachments: const [
          AskAiAttachment(fileName: 'shot.jpg', remoteKey: 'shot.jpg'),
          AskAiAttachment(fileName: 'clip.mp4', remoteKey: 'clip.mp4'),
        ],
      );

      expect(result.sentCount, 1);
      expect(result.skipped.single.fileName, 'clip.mp4');
      expect(result.skipped.single.reason, AskAiSkipReason.unsupportedType);
      // Never even fetched — no bandwidth, no credits.
      expect(rec.probed, isNot(contains('videos-v8|clip.mp4')));
    });

    test('heic is skipped (backend supports png/jpeg/gif/webp only)', () async {
      final rec = _Recorder();

      await expectLater(
        serviceFor(rec).askAi(
          prompt: 'q',
          attachments: const [
            AskAiAttachment(fileName: 'IMG_1.heic', remoteKey: 'IMG_1.heic'),
          ],
        ),
        throwsA(isA<AskAiNoFilesAttachedException>()),
      );
      expect(rec.probed, isEmpty);
    });
  });

  group('error classification', () {
    test('a hard error aborts instead of masquerading as a missing file',
        () async {
      final rec = _Recorder(hardErrors: {
        'images-v8|x.jpg': Exception('401 Unauthorized'),
      });

      await expectLater(
        serviceFor(rec).askAi(
          prompt: 'q',
          attachments: const [
            AskAiAttachment(fileName: 'x.jpg', remoteKey: 'x.jpg'),
          ],
        ),
        throwsA(isA<Exception>()),
      );

      // Must NOT have quietly tried the legacy sibling after an auth failure.
      expect(rec.probed, ['images-v8|x.jpg']);
      expect(rec.sent, isEmpty);
    });

    test('object-missing errors are recognised', () {
      expect(
        isObjectMissingError(Exception(
            'FulaApiException: Failed to download object: '
            'AnyhowException(Object not found: 2026/07/x.pdf)')),
        isTrue,
      );
      expect(isObjectMissingError(Exception('NoSuchKey')), isTrue);
      expect(isObjectMissingError(Exception('401 Unauthorized')), isFalse);
      expect(isObjectMissingError(Exception('Connection closed')), isFalse);
    });
  });

  group('local files take precedence', () {
    test('a cached shelf body is used without any cloud round-trip', () async {
      final rec = _Recorder();
      final service = AiAskService.withOverrides(
        downloader: rec.download,
        sender: rec.send,
        localPathResolver: ({String? localPath, String? iosAssetId}) async =>
            localPath,
        tokenReader: () async => 'test-token',
        endpointReader: () async => 'https://ai.example.test',
      );

      // fromPath needs a real file; use this test's own source file.
      const here = 'test/unit/core/services/ai_ask_service_test.dart';
      final result = await service.askAi(
        prompt: 'q',
        attachments: const [
          AskAiAttachment(
            fileName: 'notes.txt',
            localPath: here,
            remoteKey: '2026/07/abc-notes.txt',
            sourceBucket: 'dump-v8',
          ),
        ],
      );

      expect(result.sentCount, 1);
      expect(rec.probed, isEmpty, reason: 'local copy must short-circuit');
    });
  });
}
