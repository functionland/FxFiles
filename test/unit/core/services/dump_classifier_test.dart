// Pure-function tests for the Dump rule-based classifier. Table-driven
// so every category branch is exercised, including the screenshot
// regex, the URL-detection short-circuit, and the application/* split.

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/core/services/dump_classifier.dart';

class _Row {
  final String label;
  final String? mimeType;
  final String filename;
  final String? textPayload;
  final DumpCategory expected;
  const _Row(this.label, this.mimeType, this.filename, this.textPayload,
      this.expected);
}

void main() {
  group('DumpClassifier.classify', () {
    const rows = <_Row>[
      // image/* — non-screenshot
      _Row('plain photo', 'image/jpeg', 'IMG_1234.jpg', null,
          DumpCategory.image),
      _Row('PNG screenshot by filename', 'image/png',
          'Screenshot_2026-05-21-12-30.png', null, DumpCategory.screenshot),
      _Row('screenshot regex is case-insensitive', 'image/png',
          'SCREENSHOT.png', null, DumpCategory.screenshot),
      _Row('image without explicit MIME, MIME inferred from .gif',
          null, 'cat.gif', null, DumpCategory.image),

      // video / audio
      _Row('video/mp4', 'video/mp4', 'clip.mp4', null, DumpCategory.video),
      _Row('audio/mpeg', 'audio/mpeg', 'song.mp3', null, DumpCategory.audio),

      // document
      _Row('application/pdf', 'application/pdf', 'report.pdf', null,
          DumpCategory.document),

      // application/* (non-pdf) → file
      _Row('application/zip', 'application/zip', 'archive.zip', null,
          DumpCategory.file),
      _Row('application/octet-stream', 'application/octet-stream', 'blob.bin',
          null, DumpCategory.file),

      // text/* (without payload) → note
      _Row('text/csv → note', 'text/csv', 'rows.csv', null, DumpCategory.note),
      _Row('text/plain (file path, no payload) → note', 'text/plain',
          'todo.txt', null, DumpCategory.note),

      // text payloads
      _Row('text/plain payload that is a single URL → link', 'text/plain',
          'shared.txt', 'https://example.com/path?q=1', DumpCategory.link),
      _Row('text/plain payload that is plain prose → note', 'text/plain',
          'shared.txt', 'Remember to buy milk', DumpCategory.note),
      _Row('payload with URL embedded in prose → note (not link)',
          'text/plain', 'shared.txt',
          'See https://example.com and reply by tomorrow', DumpCategory.note),
      _Row('no MIME, payload is a URL → link', null, 'shared.txt',
          'https://example.com/', DumpCategory.link),

      // unknown / nothing
      _Row('null MIME, no payload → other', null, 'unknown', null,
          DumpCategory.other),
      _Row('font MIME → other', 'font/otf', 'icons.otf', null,
          DumpCategory.other),
    ];

    for (final row in rows) {
      test(row.label, () {
        final result = DumpClassifier.classify(
          mimeType: row.mimeType,
          filename: row.filename,
          textPayload: row.textPayload,
        );
        expect(result, row.expected,
            reason:
                '${row.label} (mime=${row.mimeType}, name=${row.filename}, payload=${row.textPayload})');
      });
    }

    test('empty textPayload + image/* falls through to image, not note', () {
      // Guard against the text-branch eating images when the receiver
      // passes an empty string for textPayload (some content providers
      // do this on Android).
      expect(
        DumpClassifier.classify(
          mimeType: 'image/jpeg',
          filename: 'pic.jpg',
          textPayload: '',
        ),
        DumpCategory.image,
      );
    });

    test('URL with trailing whitespace still classifies as link', () {
      expect(
        DumpClassifier.classify(
          mimeType: 'text/plain',
          filename: 'shared.txt',
          textPayload: 'https://example.com   \n',
        ),
        DumpCategory.link,
      );
    });
  });
}
