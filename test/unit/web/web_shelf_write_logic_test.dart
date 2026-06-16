import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/web/services/web_shelf_write_logic.dart';

void main() {
  final now = DateTime.utc(2026, 6, 15, 9, 5); // fixed for determinism

  group('key + name helpers', () {
    test('shelfManifestKey matches native .fula/dumps/<id>.json', () {
      expect(shelfManifestKey('abc123'), '.fula/dumps/abc123.json');
    });

    test('sanitizeShelfName strips unsafe chars, never empty', () {
      expect(sanitizeShelfName('a b/c?.png'), 'a_b_c_.png');
      expect(sanitizeShelfName('keep-OK_1.2'), 'keep-OK_1.2');
      expect(sanitizeShelfName('***'), '___'); // each char replaced 1:1
      expect(sanitizeShelfName(''), 'file');
    });

    test('shelfBodyKey is <yyyy>/<mm>/<id>-<sanitized> in UTC', () {
      // Local DateTime in a +offset zone still buckets by UTC month.
      final key = shelfBodyKey('id1', DateTime.utc(2026, 3, 4), 'My File.jpg');
      expect(key, '2026/03/id1-My_File.jpg');
    });

    test('deriveNoteName: first non-empty line, truncated past 60', () {
      expect(deriveNoteName('hello\nworld', now), 'hello');
      expect(deriveNoteName('   \n  second', now), 'second');
      final long = 'x' * 80;
      final name = deriveNoteName(long, now);
      expect(name.length, 60); // 59 chars + ellipsis
      expect(name.endsWith('…'), isTrue);
    });

    test('deriveNoteName: blank text falls back to a stamped default', () {
      expect(deriveNoteName('   \n\t ', now), startsWith('Note '));
    });

    test('effectiveShelfMime prefers explicit, else infers from name', () {
      expect(effectiveShelfMime('image/png', 'x.bin'), 'image/png');
      expect(effectiveShelfMime(null, 'photo.jpg'), 'image/jpeg');
      expect(effectiveShelfMime('', 'clip.mp3'), 'audio/mpeg');
    });
  });

  group('buildLinkItem', () {
    test('is a manifest-only Link (no blob)', () {
      final item = buildLinkItem(id: 'l1', url: '  https://fx.land/x  ', now: now);
      expect(item.category, ShelfCategory.link);
      expect(item.textPayload, 'https://fx.land/x'); // trimmed
      expect(item.originalName, 'https://fx.land/x');
      expect(item.remoteKey, isNull);
      expect(item.localCachePath, '');
      expect(item.uploadStatus, ShelfUploadStatus.uploaded);
      expect(item.contentSha, isNotEmpty);
      expect(item.sizeBytes, utf8.encode('https://fx.land/x').length);
    });
  });

  group('buildNoteItem', () {
    test('plain text → Note with derived title + textPayload', () {
      final item = buildNoteItem(id: 'n1', text: 'Buy milk\nand eggs', now: now);
      expect(item.category, ShelfCategory.note);
      expect(item.originalName, 'Buy milk');
      expect(item.textPayload, 'Buy milk\nand eggs');
      expect(item.remoteKey, isNull);
      expect(item.mimeType, 'text/plain');
    });

    test('a bare URL note classifies as Link (native parity)', () {
      final item = buildNoteItem(id: 'n2', text: 'https://example.com', now: now);
      expect(item.category, ShelfCategory.link);
    });
  });

  group('buildBytesItem', () {
    test('routes category by mime + records blob location', () {
      final item = buildBytesItem(
        id: 'b1',
        name: 'shot.png',
        mime: 'image/png',
        sizeBytes: 1234,
        contentSha: 'deadbeef',
        remoteKey: '2026/06/b1-shot.png',
        sourceBucket: 'dump-v8',
        now: now,
      );
      expect(item.category, ShelfCategory.image);
      expect(item.remoteKey, '2026/06/b1-shot.png');
      expect(item.sourceBucket, 'dump-v8');
      expect(item.sizeBytes, 1234);
      expect(item.contentSha, 'deadbeef');
      expect(item.mimeType, 'image/png');
    });

    test('infers mime from name when not provided (audio)', () {
      final item = buildBytesItem(
        id: 'b2',
        name: 'memo.mp3',
        mime: null,
        sizeBytes: 10,
        contentSha: 'x',
        remoteKey: 'k',
        sourceBucket: 'dump',
        now: now,
      );
      expect(item.category, ShelfCategory.audio);
      expect(item.mimeType, 'audio/mpeg'); // .mp3 → audio/mpeg
    });
  });

  group('shelfContentSha', () {
    test('is stable + matches across equal byte buffers', () {
      final a = shelfContentSha(Uint8List.fromList([1, 2, 3]));
      final b = shelfContentSha(Uint8List.fromList([1, 2, 3]));
      expect(a, b);
      expect(a, isNotEmpty);
    });
  });

  group('prependShelfItem', () {
    test('puts new item first and dedups its id', () {
      final a = buildLinkItem(id: 'a', url: 'https://a', now: now);
      final b = buildLinkItem(id: 'b', url: 'https://b', now: now);
      final aAgain = buildLinkItem(id: 'a', url: 'https://a2', now: now);

      final r = prependShelfItem([a, b], aAgain);
      expect(r.items.map((i) => i.id).toList(), ['a', 'b']);
      expect(r.items.first.textPayload, 'https://a2'); // replaced
      expect(r.order, ['a', 'b']);
    });

    test('prepends to a fresh list', () {
      final a = buildLinkItem(id: 'a', url: 'https://a', now: now);
      final r = prependShelfItem(const [], a);
      expect(r.items.single.id, 'a');
      expect(r.order, ['a']);
    });
  });

  group('buildShelfManifest', () {
    test('emits the v2 shape native restore reads', () {
      final item = buildLinkItem(id: 'l1', url: 'https://x', now: now);
      final payload = buildShelfManifest(
        items: [item],
        order: const ['l1'],
        userId: 'uid16',
        now: now,
      );
      expect(payload['v'], 2);
      expect(payload['userId'], 'uid16');
      expect(payload['order'], ['l1']);
      expect(payload['updatedAt'], now.toUtc().toIso8601String());
      expect((payload['items'] as List), hasLength(1));
    });

    test('round-trips through ShelfItem.fromJson (cross-platform shape)', () {
      final link = buildLinkItem(id: 'l1', url: 'https://x', now: now);
      final note = buildNoteItem(id: 'n1', text: 'hi there', now: now);
      final file = buildBytesItem(
        id: 'f1',
        name: 'a.png',
        mime: 'image/png',
        sizeBytes: 5,
        contentSha: 'sha',
        remoteKey: '2026/06/f1-a.png',
        sourceBucket: 'dump-v8',
        now: now,
      );
      final payload = buildShelfManifest(
        items: [link, note, file],
        order: const ['l1', 'n1', 'f1'],
        userId: 'uid16',
        now: now,
      );

      // Serialize → deserialize exactly as the native restore path does.
      final decoded =
          jsonDecode(utf8.decode(shelfManifestBytes(payload))) as Map<String, dynamic>;
      final items = (decoded['items'] as List)
          .map((e) => ShelfItem.fromJson(e as Map<String, dynamic>))
          .toList();

      expect(items[0].category, ShelfCategory.link);
      expect(items[0].textPayload, 'https://x');
      expect(items[0].remoteKey, isNull);
      // fromJson normalizes a null-remoteKey row to its persisted status.
      expect(items[0].uploadStatus, ShelfUploadStatus.uploaded);

      expect(items[1].category, ShelfCategory.note);
      expect(items[1].textPayload, 'hi there');

      expect(items[2].category, ShelfCategory.image);
      expect(items[2].remoteKey, '2026/06/f1-a.png');
      expect(items[2].sourceBucket, 'dump-v8');
      // A row with a remoteKey normalizes to uploaded.
      expect(items[2].uploadStatus, ShelfUploadStatus.uploaded);
    });
  });

  group('mergeShelfManifestBlobs', () {
    Uint8List blobOf(List<ShelfItem> items, List<String> order) =>
        shelfManifestBytes(buildShelfManifest(
            items: items, order: order, userId: 'u', now: now));
    ShelfItem link(String id, String url) =>
        buildLinkItem(id: id, url: url, now: now);

    test('v8 (first blob) wins an id over legacy', () {
      final r = mergeShelfManifestBlobs([
        blobOf([link('x', 'https://v8')], ['x']),
        blobOf([link('x', 'https://legacy')], ['x']),
      ]);
      expect(r.items.single.textPayload, 'https://v8');
    });

    test('applies v8 order; legacy-only items fall to the end', () {
      final a = link('a', 'https://a');
      final b = link('b', 'https://b');
      final c = link('c', 'https://c');
      final r = mergeShelfManifestBlobs([
        blobOf([a, b], ['b', 'a']),
        blobOf([c], ['c']),
      ]);
      expect(r.items.map((i) => i.id).toList(), ['b', 'a', 'c']);
    });

    test('skips null / empty / unparseable blobs, keeps the good one', () {
      final good = blobOf([link('a', 'https://a')], ['a']);
      final bad = Uint8List.fromList(utf8.encode('not json{'));
      final r = mergeShelfManifestBlobs([null, Uint8List(0), bad, good]);
      expect(r.items.single.id, 'a');
    });

    test('all-empty input → empty result (genuine empty shelf)', () {
      expect(mergeShelfManifestBlobs([null, null]).items, isEmpty);
    });
  });
}
