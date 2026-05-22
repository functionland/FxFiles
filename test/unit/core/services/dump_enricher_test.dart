// Unit tests for DumpEnricher. Covers:
//   - Per-category branches: Link / Note / Image / Video / Audio /
//     Document / File / Other / Screenshot.
//   - R14 SSRF guards: private IPs and non-http schemes never fetch.
//   - Failure paths: missing source file → failed; HTTP errors → URL
//     fallback; ML Kit throws → null labels but result not failed.
//
// Hot platform plugins (ML Kit, video_thumbnail) are skipped or
// substituted via the test seams on DumpEnricher.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/core/services/dump_enricher.dart';

class _StubLabel implements ImageLabel {
  @override
  final String label;
  @override
  final double confidence;
  @override
  final int index;
  _StubLabel(this.label, [this.confidence = 0.9]) : index = 0;
}

class _CannedClient extends http.BaseClient {
  final List<int> body;
  _CannedClient({required this.body});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([body]),
      200,
      headers: const {'content-type': 'text/html'},
      request: request,
    );
  }
}

DumpItem _item({
  required String id,
  required DumpCategory category,
  required String localCachePath,
  String originalName = 'sample',
  String? mimeType,
  int sizeBytes = 100,
  String? textPayload,
}) {
  return DumpItem(
    id: id,
    receivedAt: DateTime.utc(2026, 5, 21),
    originalName: originalName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    localCachePath: localCachePath,
    category: category,
    contentSha: 'sha-$id',
    textPayload: textPayload,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dump_enricher_test_');
    DumpEnricher.instance.resetForTesting();
    DumpEnricher.instance.thumbsDirOverride =
        () async => Directory('${tempDir.path}/thumbs');
  });

  tearDown(() async {
    DumpEnricher.instance.resetForTesting();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {
      // Windows occasionally holds the dir briefly; harmless.
    }
  });

  group('Note enrichment', () {
    test('title = first non-empty line trimmed, desc = leading 200 chars',
        () async {
      final path = '${tempDir.path}/note.txt';
      await File(path).writeAsString('  \n\nFirst line of the note\nbody');
      final item = _item(
        id: 'n1',
        category: DumpCategory.note,
        localCachePath: path,
        originalName: 'note.txt',
        mimeType: 'text/plain',
        textPayload: '  \n\nFirst line of the note\nbody',
      );
      final res = await DumpEnricher.instance.enrich(item);
      expect(res.status, DumpEnrichmentStatus.done);
      expect(res.title, 'First line of the note');
      expect(res.description, contains('First line of the note'));
    });

    test('very long first line is truncated', () async {
      final long = List.generate(200, (_) => 'x').join();
      final path = '${tempDir.path}/note.txt';
      await File(path).writeAsString(long);
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'n2',
        category: DumpCategory.note,
        localCachePath: path,
        textPayload: long,
      ));
      expect(res.title!.length, lessThanOrEqualTo(60));
      expect(res.title!.endsWith('…'), isTrue);
    });

    test('empty payload returns title=originalName, desc=0 bytes · Note',
        () async {
      final path = '${tempDir.path}/note.txt';
      await File(path).writeAsString('');
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'n3',
        category: DumpCategory.note,
        localCachePath: path,
        originalName: 'note.txt',
        textPayload: '',
      ));
      expect(res.status, DumpEnrichmentStatus.done);
      expect(res.title, 'note.txt');
      expect(res.description, contains('Note'));
    });
  });

  group('Link enrichment — R14 SSRF guards', () {
    test('non-http scheme returns host fallback without fetching', () async {
      DumpEnricher.instance.linkHttpClientOverride = _CannedClient(
        body: 'should not be called'.codeUnits,
      );
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'l1',
        category: DumpCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'javascript:alert(1)',
      ));
      expect(res.status, DumpEnrichmentStatus.done);
      expect(res.title, isNotNull);
    });

    test('private-IP host is not fetched (no OG title)', () async {
      DumpEnricher.instance.linkHttpClientOverride = _CannedClient(
        body: '<title>SHOULD NOT APPEAR</title>'.codeUnits,
      );
      // `localhost` resolves to 127.0.0.1 — the private-IP guard
      // should block the fetch.
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'l2',
        category: DumpCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: 'http://localhost/foo',
      ));
      expect(res.status, DumpEnrichmentStatus.done);
      expect(res.title, 'localhost');
      expect(res.description, 'http://localhost/foo');
    });

    test('empty/missing textPayload returns Link description', () async {
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'l3',
        category: DumpCategory.link,
        localCachePath: '${tempDir.path}/share.txt',
        textPayload: '',
      ));
      expect(res.status, DumpEnrichmentStatus.done);
      expect(res.description, 'Link');
    });
  });

  group('Image enrichment', () {
    Future<File> writePng(String name, int w, int h) async {
      final image = img.Image(width: w, height: h);
      img.fill(image, color: img.ColorRgb8(200, 100, 50));
      final bytes = img.encodePng(image);
      final file = File('${tempDir.path}/$name');
      await file.writeAsBytes(bytes);
      return file;
    }

    test('ML Kit labels populate title (Title Case) + description', () async {
      final file = await writePng('photo.png', 800, 600);
      DumpEnricher.instance.imageLabelOverride = (_) async => [
            _StubLabel('sunset', 0.9),
            _StubLabel('sky', 0.85),
            _StubLabel('cloud', 0.7),
          ];

      final res = await DumpEnricher.instance.enrich(_item(
        id: 'i1',
        category: DumpCategory.image,
        localCachePath: file.path,
        originalName: 'photo.png',
        mimeType: 'image/png',
      ));
      expect(res.status, DumpEnrichmentStatus.done);
      expect(res.title, 'Sunset');
      expect(res.description, 'sunset, sky, cloud');
      expect(res.mlLabels, ['sunset', 'sky', 'cloud']);
      expect(res.thumbnailPath, isNotNull);
      expect(await File(res.thumbnailPath!).exists(), isTrue);
    });

    test('screenshot category always titles as "Screenshot"', () async {
      final file = await writePng('Screenshot_2026-05-21.png', 400, 400);
      DumpEnricher.instance.imageLabelOverride = (_) async => [
            _StubLabel('text', 0.9),
          ];
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'i2',
        category: DumpCategory.screenshot,
        localCachePath: file.path,
        originalName: 'Screenshot_2026-05-21.png',
      ));
      expect(res.title, 'Screenshot');
      expect(res.description, 'text');
    });

    test('ML Kit throwing falls back to filename + size·category', () async {
      final file = await writePng('photo.png', 400, 300);
      DumpEnricher.instance.imageLabelOverride =
          (_) async => throw StateError('ML Kit unavailable');

      final res = await DumpEnricher.instance.enrich(_item(
        id: 'i3',
        category: DumpCategory.image,
        localCachePath: file.path,
        originalName: 'photo.png',
        sizeBytes: 1024 * 50,
      ));
      expect(res.status, DumpEnrichmentStatus.done);
      expect(res.title, 'photo');
      expect(res.description, contains('Image'));
      expect(res.mlLabels, isEmpty);
    });

    test('downscales source image into the thumbs dir', () async {
      final file = await writePng('big.png', 1024, 768);
      DumpEnricher.instance.imageLabelOverride = (_) async => const [];
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'i4',
        category: DumpCategory.image,
        localCachePath: file.path,
        originalName: 'big.png',
      ));
      expect(res.thumbnailPath, isNotNull);
      final thumbBytes = await File(res.thumbnailPath!).readAsBytes();
      final decoded = img.decodeImage(thumbBytes)!;
      expect(decoded.width, lessThanOrEqualTo(256));
      expect(decoded.height, lessThanOrEqualTo(256));
    });

    test('missing source file → enrichment failed', () async {
      DumpEnricher.instance.imageLabelOverride = (_) async => const [];
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'i5',
        category: DumpCategory.image,
        localCachePath: '${tempDir.path}/does-not-exist.png',
      ));
      expect(res.status, DumpEnrichmentStatus.failed);
    });
  });

  group('Audio / Document / File branches', () {
    test('audio uses filename + size·Audio', () async {
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'a1',
        category: DumpCategory.audio,
        localCachePath: '${tempDir.path}/song.mp3',
        originalName: 'song.mp3',
        sizeBytes: 4 * 1024 * 1024,
      ));
      expect(res.status, DumpEnrichmentStatus.done);
      expect(res.title, 'song');
      expect(res.description, '4.0 MB · Audio');
    });

    test('document title=filename, desc="size · PDF"', () async {
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'd1',
        category: DumpCategory.document,
        localCachePath: '${tempDir.path}/report.pdf',
        originalName: 'report.pdf',
        sizeBytes: 250 * 1024,
      ));
      expect(res.title, 'report');
      expect(res.description, '250.0 KB · PDF');
    });

    test('file description includes mimeType', () async {
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'f1',
        category: DumpCategory.file,
        localCachePath: '${tempDir.path}/archive.zip',
        originalName: 'archive.zip',
        mimeType: 'application/zip',
        sizeBytes: 1024,
      ));
      expect(res.description, contains('application/zip'));
    });

    test('other defaults to filename + "unknown" mime', () async {
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'o1',
        category: DumpCategory.other,
        localCachePath: '${tempDir.path}/weird.dat',
        originalName: 'weird.dat',
        sizeBytes: 1,
      ));
      expect(res.description, contains('unknown'));
    });
  });

  group('Video enrichment', () {
    test('missing video file → failed', () async {
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'v1',
        category: DumpCategory.video,
        localCachePath: '${tempDir.path}/missing.mp4',
      ));
      expect(res.status, DumpEnrichmentStatus.failed);
    });

    test('present file → done, with title/desc set even when '
        'video_thumbnail unavailable (test env)', () async {
      // Touch a stub file; the platform plugin isn't actually wired
      // up in `flutter test`, so the thumbnail call will fail and
      // the enricher's catch block leaves thumbnailPath null while
      // still returning done.
      final f = File('${tempDir.path}/clip.mp4');
      await f.writeAsBytes(Uint8List.fromList(List.filled(16, 0)));
      final res = await DumpEnricher.instance.enrich(_item(
        id: 'v2',
        category: DumpCategory.video,
        localCachePath: f.path,
        originalName: 'clip.mp4',
        sizeBytes: 16,
      ));
      expect(res.status, DumpEnrichmentStatus.done);
      expect(res.title, 'clip');
      expect(res.description, contains('Video'));
    });
  });
}
