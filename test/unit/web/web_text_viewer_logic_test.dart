import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/web/services/web_text_viewer_logic.dart';

/// Unit tests for the pure inline-text-viewer logic (#19). The browser-only
/// widget (web_text_viewer.dart) imports package:web indirectly via web_save
/// and is not VM-testable; the classification + helpers live in the
/// dependency-free web_text_viewer_logic.dart and are covered here.
void main() {
  group('fileExtension', () {
    test('lower-cases and takes the last segment', () {
      expect(fileExtension('a.TXT'), 'txt');
      expect(fileExtension('a.b.JS'), 'js');
    });

    test('strips path prefixes (forward and back slash)', () {
      expect(fileExtension('folder/sub/file.TS'), 'ts');
      expect(fileExtension('a/b\\c.Md'), 'md');
    });

    test('extensionless names map to the whole basename (native parity)', () {
      expect(fileExtension('Makefile'), 'makefile');
      expect(fileExtension('.gitignore'), 'gitignore');
      expect(fileExtension('path/to/Dockerfile'), 'dockerfile');
    });
  });

  group('isTextViewableName', () {
    test('opens the types users asked for (xml, ts, js, html, yaml, py)', () {
      for (final n in ['a.xml', 'a.ts', 'a.js', 'a.html', 'a.yaml', 'a.py']) {
        expect(isTextViewableName(n), isTrue, reason: n);
      }
    });

    test('still opens the previously-working types (no regression)', () {
      for (final n in ['a.txt', 'a.md', 'a.json', 'a.csv', 'a.log']) {
        expect(isTextViewableName(n), isTrue, reason: n);
      }
    });

    test('opens extensionless special names', () {
      expect(isTextViewableName('Makefile'), isTrue);
      expect(isTextViewableName('.gitignore'), isTrue);
      expect(isTextViewableName('.env'), isTrue);
    });

    test('does not open binary/media', () {
      for (final n in ['a.png', 'a.jpg', 'a.mp4', 'a.mp3', 'a.exe', 'a.zip']) {
        expect(isTextViewableName(n), isFalse, reason: n);
      }
    });
  });

  group('isCodeName (dark editor theme)', () {
    test('code extensions are code', () {
      for (final n in ['a.dart', 'a.ts', 'a.xml', 'a.json', 'a.css']) {
        expect(isCodeName(n), isTrue, reason: n);
      }
    });

    test('plain text/doc extensions are not code', () {
      for (final n in ['a.txt', 'a.md', 'a.csv', 'a.log']) {
        expect(isCodeName(n), isFalse, reason: n);
      }
    });
  });

  group('prettyPrintJsonIfApplicable', () {
    test('indents valid JSON when ext is json', () {
      final out = prettyPrintJsonIfApplicable('{"a":1,"b":2}', 'json');
      expect(out.contains('\n'), isTrue);
      expect(out.contains('  '), isTrue);
      // Round-trips to the same data.
      expect(jsonDecode(out), {'a': 1, 'b': 2});
    });

    test('leaves invalid JSON unchanged', () {
      const bad = '{not valid json';
      expect(prettyPrintJsonIfApplicable(bad, 'json'), bad);
    });

    test('does not touch non-json extensions', () {
      const s = '{"a":1}';
      expect(prettyPrintJsonIfApplicable(s, 'txt'), s);
    });

    test('skips pretty-print above the byte cap', () {
      const s = '{"a":1}';
      expect(
        prettyPrintJsonIfApplicable(s, 'json', byteSize: 10, maxBytes: 5),
        s,
      );
    });
  });

  group('splitLines', () {
    test('handles \\n, \\r\\n and lone \\r', () {
      expect(splitLines('a\nb\r\nc\rd'), ['a', 'b', 'c', 'd']);
    });

    test('no spurious trailing blank line', () {
      expect(splitLines('a\nb\n'), ['a', 'b']);
    });

    test('empty content → zero lines', () {
      expect(splitLines(''), isEmpty);
    });
  });

  group('maxLineDisplayWidth', () {
    test('returns the widest line length', () {
      expect(maxLineDisplayWidth(['ab', 'abcd', 'a']), 4);
    });

    test('counts a tab as multiple columns', () {
      // '\tx' = tabWidth(4) + 1 = 5 columns, wider than the 4-char line.
      expect(maxLineDisplayWidth(['abcd', '\tx']), 5);
    });

    test('empty list → 0', () {
      expect(maxLineDisplayWidth(const []), 0);
    });
  });

  group('decodeTextLenient', () {
    test('round-trips valid UTF-8', () {
      final bytes = Uint8List.fromList(utf8.encode('héllo, 世界'));
      expect(decodeTextLenient(bytes), 'héllo, 世界');
    });

    test('does not throw on malformed bytes', () {
      final bytes = Uint8List.fromList([0xFF, 0xFE, 0x41]);
      expect(() => decodeTextLenient(bytes), returnsNormally);
      expect(decodeTextLenient(bytes).isNotEmpty, isTrue);
    });
  });

  group('findMatchingLineIndices', () {
    final lines = ['Alpha', 'beta', 'AlphaBeta', 'gamma'];

    test('empty query → no matches', () {
      expect(findMatchingLineIndices(lines, ''), isEmpty);
    });

    test('is case-insensitive and returns line indices', () {
      expect(findMatchingLineIndices(lines, 'alpha'), [0, 2]);
      expect(findMatchingLineIndices(lines, 'BETA'), [1, 2]);
    });

    test('no match → empty', () {
      expect(findMatchingLineIndices(lines, 'zzz'), isEmpty);
    });
  });
}
