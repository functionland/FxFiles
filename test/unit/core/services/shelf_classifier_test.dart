// Pure-function tests for the Shelf rule-based classifier. Table-driven
// so every category branch is exercised, including the screenshot
// regex, the URL-detection short-circuit, and the application/* split.

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_classifier.dart';

class _Row {
  final String label;
  final String? mimeType;
  final String filename;
  final String? textPayload;
  final ShelfCategory expected;
  const _Row(this.label, this.mimeType, this.filename, this.textPayload,
      this.expected);
}

void main() {
  group('ShelfClassifier.classify', () {
    const rows = <_Row>[
      // image/* — non-screenshot
      _Row('plain photo', 'image/jpeg', 'IMG_1234.jpg', null,
          ShelfCategory.image),
      _Row('PNG screenshot by filename', 'image/png',
          'Screenshot_2026-05-21-12-30.png', null, ShelfCategory.screenshot),
      _Row('screenshot regex is case-insensitive', 'image/png',
          'SCREENSHOT.png', null, ShelfCategory.screenshot),
      _Row('image without explicit MIME, MIME inferred from .gif',
          null, 'cat.gif', null, ShelfCategory.image),

      // video / audio
      _Row('video/mp4', 'video/mp4', 'clip.mp4', null, ShelfCategory.video),
      _Row('audio/mpeg', 'audio/mpeg', 'song.mp3', null, ShelfCategory.audio),

      // document
      _Row('application/pdf', 'application/pdf', 'report.pdf', null,
          ShelfCategory.document),

      // application/* (non-pdf) → file
      _Row('application/zip', 'application/zip', 'archive.zip', null,
          ShelfCategory.file),
      _Row('application/octet-stream', 'application/octet-stream', 'blob.bin',
          null, ShelfCategory.file),

      // text/* (without payload) → note
      _Row('text/csv → note', 'text/csv', 'rows.csv', null, ShelfCategory.note),
      _Row('text/plain (file path, no payload) → note', 'text/plain',
          'todo.txt', null, ShelfCategory.note),

      // text payloads
      _Row('text/plain payload that is a single URL → link', 'text/plain',
          'shared.txt', 'https://example.com/path?q=1', ShelfCategory.link),
      _Row('text/plain payload that is plain prose → note', 'text/plain',
          'shared.txt', 'Remember to buy milk', ShelfCategory.note),
      _Row('payload with URL embedded in prose → note (not link)',
          'text/plain', 'shared.txt',
          'See https://example.com and reply by tomorrow', ShelfCategory.note),
      _Row('no MIME, payload is a URL → link', null, 'shared.txt',
          'https://example.com/', ShelfCategory.link),

      // unknown / nothing
      _Row('null MIME, no payload → other', null, 'unknown', null,
          ShelfCategory.other),
      _Row('font MIME → other', 'font/otf', 'icons.otf', null,
          ShelfCategory.other),
    ];

    for (final row in rows) {
      test(row.label, () {
        final result = ShelfClassifier.classify(
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
        ShelfClassifier.classify(
          mimeType: 'image/jpeg',
          filename: 'pic.jpg',
          textPayload: '',
        ),
        ShelfCategory.image,
      );
    });

    test('URL with trailing whitespace still classifies as link', () {
      expect(
        ShelfClassifier.classify(
          mimeType: 'text/plain',
          filename: 'shared.txt',
          textPayload: 'https://example.com   \n',
        ),
        ShelfCategory.link,
      );
    });
  });
}
