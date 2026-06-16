// Integration-flavoured unit tests for ShelfStorageService — exercises
// the full Hive round-trip + dedup (R8) + orphan GC (R7) + pendingAuth
// filtering (R10). Each test gets a fresh tempDir + Hive instance.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_storage_service.dart';

ShelfItem _item({
  required String id,
  String contentSha = 'sha-default',
  int sizeBytes = 100,
  String localCachePath = '/tmp/missing',
  ShelfUploadStatus uploadStatus = ShelfUploadStatus.queued,
  ShelfCategory category = ShelfCategory.other,
  DateTime? receivedAt,
}) {
  return ShelfItem(
    id: id,
    receivedAt: receivedAt ?? DateTime.utc(2026, 5, 21, 12, 0),
    originalName: '$id-file',
    sizeBytes: sizeBytes,
    localCachePath: localCachePath,
    category: category,
    uploadStatus: uploadStatus,
    contentSha: contentSha,
  );
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dump_storage_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await ShelfStorageService.instance.resetForTesting();
    await Hive.deleteFromDisk();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {
      // Windows occasionally holds the dir; harmless.
    }
  });

  group('init', () {
    test('registers adapters 60-63 and opens dump_items box', () async {
      await ShelfStorageService.instance.init();
      expect(ShelfStorageService.instance.isInitialized, isTrue);
      expect(Hive.isAdapterRegistered(60), isTrue, reason: 'ShelfCategory');
      expect(Hive.isAdapterRegistered(61), isTrue, reason: 'ShelfUploadStatus');
      expect(Hive.isAdapterRegistered(62), isTrue, reason: 'ShelfItem');
      expect(Hive.isAdapterRegistered(63), isTrue,
          reason: 'ShelfEnrichmentStatus');
    });

    test('is idempotent — second call does not throw', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.init();
      expect(ShelfStorageService.instance.isInitialized, isTrue);
    });
  });

  group('add / getById / getAll', () {
    test('adds and retrieves an item by id', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'a'));
      final fetched = ShelfStorageService.instance.getById('a');
      expect(fetched, isNotNull);
      expect(fetched!.id, 'a');
    });

    test('getAll returns all stored items', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'a'));
      await ShelfStorageService.instance.add(_item(id: 'b'));
      await ShelfStorageService.instance.add(_item(id: 'c'));
      final all = ShelfStorageService.instance.getAll();
      expect(all.map((i) => i.id).toSet(), {'a', 'b', 'c'});
    });
  });

  group('findByContentSha (candidate dedup)', () {
    test('returns all items matching the contentSha', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(
        _item(id: 'a', contentSha: 'sha-x', sizeBytes: 100),
      );
      await ShelfStorageService.instance.add(
        _item(id: 'b', contentSha: 'sha-x', sizeBytes: 200),
      );
      await ShelfStorageService.instance.add(
        _item(id: 'c', contentSha: 'sha-y', sizeBytes: 100),
      );
      final matches =
          ShelfStorageService.instance.findByContentSha('sha-x');
      expect(matches.map((i) => i.id).toSet(), {'a', 'b'});
    });

    test('returns empty list when nothing matches', () async {
      await ShelfStorageService.instance.init();
      expect(
        ShelfStorageService.instance.findByContentSha('nope'),
        isEmpty,
      );
    });
  });

  group('findDuplicate (R8: candidate + size + full-hash verify)', () {
    test('returns null when no candidate matches contentSha', () async {
      await ShelfStorageService.instance.init();
      final result = await ShelfStorageService.instance.findDuplicate(
        contentSha: 'nope',
        sizeBytes: 100,
        sourceFilePath: '/does/not/exist',
      );
      expect(result, isNull);
    });

    test('returns null when contentSha matches but sizeBytes differs',
        () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(
        _item(id: 'a', contentSha: 'sha-x', sizeBytes: 100),
      );
      final result = await ShelfStorageService.instance.findDuplicate(
        contentSha: 'sha-x',
        sizeBytes: 200,
        sourceFilePath: '/does/not/exist',
      );
      expect(result, isNull);
    });

    test(
        'accepts candidate for large files (>50MB) on sha+size match without '
        'full hash', () async {
      await ShelfStorageService.instance.init();
      // Use a >50MB sizeBytes but a fake path — we MUST not read the file.
      const huge = 60 * 1024 * 1024;
      await ShelfStorageService.instance.add(
        _item(id: 'big', contentSha: 'sha-big', sizeBytes: huge),
      );
      final result = await ShelfStorageService.instance.findDuplicate(
        contentSha: 'sha-big',
        sizeBytes: huge,
        sourceFilePath: '/does/not/exist',
      );
      expect(result, isNotNull);
      expect(result!.id, 'big');
    });

    test('for small files (≤50MB), verifies full hash and accepts on match',
        () async {
      await ShelfStorageService.instance.init();
      // Create two real files with identical bytes.
      final bytes = Uint8List.fromList(
        List<int>.generate(1024, (i) => i % 256),
      );
      final f1 = File('${tempDir.path}/dup-existing.bin');
      final f2 = File('${tempDir.path}/dup-incoming.bin');
      await f1.writeAsBytes(bytes);
      await f2.writeAsBytes(bytes);

      final sha = sha256.convert(bytes).toString();
      await ShelfStorageService.instance.add(
        _item(
          id: 'existing',
          contentSha: sha,
          sizeBytes: bytes.length,
          localCachePath: f1.path,
        ),
      );

      final result = await ShelfStorageService.instance.findDuplicate(
        contentSha: sha,
        sizeBytes: bytes.length,
        sourceFilePath: f2.path,
      );
      expect(result, isNotNull);
      expect(result!.id, 'existing');
    });

    test(
        'for small files, rejects candidate when full hash differs '
        '(prefix-collision case)', () async {
      await ShelfStorageService.instance.init();
      // Two files with the SAME size + SAME contentSha (deliberately
      // mismatched in our test to simulate R8's collision risk), but
      // different full-file bytes → full-hash check should reject.
      final bytesA = Uint8List.fromList(List<int>.filled(1024, 0xAA));
      final bytesB = Uint8List.fromList(List<int>.filled(1024, 0xBB));
      final f1 = File('${tempDir.path}/collide-existing.bin');
      final f2 = File('${tempDir.path}/collide-incoming.bin');
      await f1.writeAsBytes(bytesA);
      await f2.writeAsBytes(bytesB);

      // Use the same fake `contentSha` candidate key for both — R8
      // simulation. The full-hash verify must catch the mismatch.
      const fakeCandidateSha = 'sha-collision-prefix';
      await ShelfStorageService.instance.add(
        _item(
          id: 'existing',
          contentSha: fakeCandidateSha,
          sizeBytes: 1024,
          localCachePath: f1.path,
        ),
      );

      final result = await ShelfStorageService.instance.findDuplicate(
        contentSha: fakeCandidateSha,
        sizeBytes: 1024,
        sourceFilePath: f2.path,
      );
      expect(result, isNull, reason: 'Full-hash check must reject collision');
    });
  });

  group('updateStatus', () {
    test('updates status + remoteKey + errorMessage atomically', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(
        _item(id: 'a', uploadStatus: ShelfUploadStatus.queued),
      );

      await ShelfStorageService.instance.updateStatus(
        'a',
        ShelfUploadStatus.uploaded,
        remoteKey: '2026/05/a.bin',
      );

      final after = ShelfStorageService.instance.getById('a')!;
      expect(after.uploadStatus, ShelfUploadStatus.uploaded);
      expect(after.remoteKey, '2026/05/a.bin');
    });

    test('no-op on unknown id', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.updateStatus(
        'nope',
        ShelfUploadStatus.failed,
      );
      expect(ShelfStorageService.instance.getById('nope'), isNull);
    });
  });

  group('updateEnrichment', () {
    test('updates enrichment fields without touching upload fields',
        () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(
        _item(id: 'a', uploadStatus: ShelfUploadStatus.uploaded),
      );

      await ShelfStorageService.instance.updateEnrichment(
        'a',
        title: 'Sunset',
        description: 'sky, dusk',
        thumbnailPath: '/tmp/thumbs/a.jpg',
        mlLabels: const ['sky', 'dusk'],
        status: ShelfEnrichmentStatus.done,
      );

      final after = ShelfStorageService.instance.getById('a')!;
      expect(after.autoTitle, 'Sunset');
      expect(after.autoDescription, 'sky, dusk');
      expect(after.thumbnailPath, '/tmp/thumbs/a.jpg');
      expect(after.mlLabels, const ['sky', 'dusk']);
      expect(after.enrichmentStatus, ShelfEnrichmentStatus.done);
      expect(after.uploadStatus, ShelfUploadStatus.uploaded,
          reason: 'enrichment must not touch uploadStatus');
    });
  });

  group('delete', () {
    test('removes the item from the box', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'a'));
      await ShelfStorageService.instance.delete('a');
      expect(ShelfStorageService.instance.getById('a'), isNull);
    });
  });

  group('getPendingAuthItems', () {
    test('returns only items in pendingAuth state', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(
        _item(id: 'p1', uploadStatus: ShelfUploadStatus.pendingAuth),
      );
      await ShelfStorageService.instance.add(
        _item(id: 'q1', uploadStatus: ShelfUploadStatus.queued),
      );
      await ShelfStorageService.instance.add(
        _item(id: 'p2', uploadStatus: ShelfUploadStatus.pendingAuth),
      );

      final result = ShelfStorageService.instance.getPendingAuthItems();
      expect(result.map((i) => i.id).toSet(), {'p1', 'p2'});
    });
  });

  group('watch (Stream<List<ShelfItem>>)', () {
    test('emits initial snapshot then re-emits on mutation', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'a'));

      final emissions = <List<ShelfItem>>[];
      final completer = Completer<void>();
      final sub = ShelfStorageService.instance.watch().listen((batch) {
        emissions.add(batch);
        if (emissions.length >= 2) completer.complete();
      });

      // Mutate after subscribing → second emission.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await ShelfStorageService.instance.add(_item(id: 'b'));
      await completer.future.timeout(const Duration(seconds: 1));
      await sub.cancel();

      expect(emissions.length, greaterThanOrEqualTo(2));
      // First emission has 1 item, second has 2.
      expect(emissions.first.length, 1);
      expect(emissions.last.map((i) => i.id).toSet(), {'a', 'b'});
    });
  });

  group('garbageCollectOrphans (R7)', () {
    test('deletes files in pendingDir without a matching ShelfItem', () async {
      await ShelfStorageService.instance.init();
      final pendingDir =
          await Directory('${tempDir.path}/dump_pending').create();

      final orphan = File('${pendingDir.path}/orphan.bin');
      final tracked = File('${pendingDir.path}/tracked.bin');
      await orphan.writeAsBytes([1, 2, 3]);
      await tracked.writeAsBytes([4, 5, 6]);

      await ShelfStorageService.instance.add(
        _item(id: 'tracked', localCachePath: tracked.path),
      );

      final deleted =
          await ShelfStorageService.instance.garbageCollectOrphans(pendingDir);

      expect(deleted, 1);
      expect(await orphan.exists(), isFalse);
      expect(await tracked.exists(), isTrue);
    });

    test('returns 0 and is a no-op on missing directory', () async {
      await ShelfStorageService.instance.init();
      final missing = Directory('${tempDir.path}/does-not-exist');
      final deleted =
          await ShelfStorageService.instance.garbageCollectOrphans(missing);
      expect(deleted, 0);
    });
  });

  group('ShelfItem JSON round-trip', () {
    test('toJson excludes device-specific paths', () {
      final item = ShelfItem(
        id: 'abc',
        receivedAt: DateTime.utc(2026, 5, 23, 14, 47),
        originalName: 'Note.txt',
        sizeBytes: 44,
        localCachePath: '/data/.../dump_pending/abc-note.txt',
        thumbnailPath: '/data/.../dump_thumbs/abc.jpg',
        category: ShelfCategory.link,
        contentSha: 'sha-xyz',
        remoteKey: '2026/05/abc-Note.txt',
        thumbnailRemoteKey: '2026/05/abc.jpg',
      );
      final json = item.toJson();
      expect(json.containsKey('localCachePath'), isFalse);
      expect(json.containsKey('thumbnailPath'), isFalse);
      expect(json['remoteKey'], '2026/05/abc-Note.txt');
      expect(json['thumbnailRemoteKey'], '2026/05/abc.jpg');
      expect(json['category'], 'link');
    });

    test('fromJson normalizes uploadStatus → uploaded when remoteKey set',
        () {
      final json = {
        'id': 'abc',
        'receivedAt': '2026-05-23T14:47:00.000Z',
        'originalName': 'Note.txt',
        'sizeBytes': 44,
        'remoteKey': '2026/05/abc-Note.txt',
        'category': 'link',
        'uploadStatus': 'pendingAuth', // stale — but remoteKey is set
        'contentSha': 'sha-xyz',
        'enrichmentStatus': 'done',
      };
      final item = ShelfItem.fromJson(json);
      expect(item.uploadStatus, ShelfUploadStatus.uploaded);
      expect(item.localCachePath, '');
      expect(item.thumbnailPath, isNull);
      expect(item.remoteKey, '2026/05/abc-Note.txt');
    });

    test('fromJson preserves uploadStatus when remoteKey is null', () {
      final json = {
        'id': 'abc',
        'receivedAt': '2026-05-23T14:47:00.000Z',
        'originalName': 'Note.txt',
        'sizeBytes': 44,
        'remoteKey': null,
        'category': 'note',
        'uploadStatus': 'pendingAuth',
        'contentSha': 'sha-xyz',
        'enrichmentStatus': 'pending',
      };
      final item = ShelfItem.fromJson(json);
      expect(item.uploadStatus, ShelfUploadStatus.pendingAuth);
    });

    test('toJson → fromJson round-trip preserves cross-device fields', () {
      final original = ShelfItem(
        id: 'rt',
        receivedAt: DateTime.utc(2026, 4, 1, 10, 30),
        originalName: 'photo.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 1024,
        localCachePath: '/local/will/be/lost',
        remoteKey: '2026/04/rt-photo.jpg',
        thumbnailPath: '/local/thumb/will/be/lost',
        thumbnailRemoteKey: '2026/04/rt.jpg',
        category: ShelfCategory.image,
        uploadStatus: ShelfUploadStatus.uploaded,
        sourceAppPackage: 'com.instagram.android',
        textPayload: null,
        mlLabels: const ['cat', 'sunset'],
        contentSha: 'sha-img',
        autoTitle: 'Sunset',
        autoDescription: 'cat, sunset',
        enrichmentStatus: ShelfEnrichmentStatus.done,
      );
      final clone = ShelfItem.fromJson(original.toJson());
      expect(clone.id, original.id);
      expect(clone.receivedAt, original.receivedAt);
      expect(clone.originalName, original.originalName);
      expect(clone.mimeType, original.mimeType);
      expect(clone.sizeBytes, original.sizeBytes);
      expect(clone.remoteKey, original.remoteKey);
      expect(clone.thumbnailRemoteKey, original.thumbnailRemoteKey);
      expect(clone.category, original.category);
      expect(clone.uploadStatus, original.uploadStatus);
      expect(clone.sourceAppPackage, original.sourceAppPackage);
      expect(clone.mlLabels, original.mlLabels);
      expect(clone.contentSha, original.contentSha);
      expect(clone.autoTitle, original.autoTitle);
      expect(clone.autoDescription, original.autoDescription);
      expect(clone.enrichmentStatus, original.enrichmentStatus);
      // Device-specific fields are intentionally NOT preserved.
      expect(clone.localCachePath, '');
      expect(clone.thumbnailPath, isNull);
    });
  });

  group('Cloud sync — syncToCloud + debounce', () {
    test('mutating the box schedules a debounced upload that fires once',
        () async {
      await ShelfStorageService.instance.init();
      final uploads = <List<int>>[];
      ShelfStorageService.instance.cloudSyncUploadOverride =
          (data, _) async => uploads.add(data);

      // Three rapid mutations should debounce to a single upload.
      await ShelfStorageService.instance.add(_item(id: 'a'));
      await ShelfStorageService.instance.add(_item(id: 'b'));
      await ShelfStorageService.instance.add(_item(id: 'c'));

      // Debounce is 5s; fast-forward by triggering the sync explicitly
      // (production code waits for the Timer).
      await ShelfStorageService.instance.syncToCloud();

      expect(uploads.length, 1);
      final payload =
          jsonDecode(utf8.decode(uploads.single)) as Map<String, dynamic>;
      final ids = (payload['items'] as List)
          .map((e) => (e as Map<String, dynamic>)['id'] as String)
          .toSet();
      expect(ids, {'a', 'b', 'c'});
    });

    test('upload payload omits localCachePath/thumbnailPath', () async {
      await ShelfStorageService.instance.init();
      late Map<String, dynamic> captured;
      ShelfStorageService.instance.cloudSyncUploadOverride = (data, _) async {
        captured = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      };
      await ShelfStorageService.instance.add(
        _item(id: 'x', localCachePath: '/private/local'),
      );
      await ShelfStorageService.instance.syncToCloud();
      final firstItem =
          (captured['items'] as List).first as Map<String, dynamic>;
      expect(firstItem.containsKey('localCachePath'), isFalse);
      expect(firstItem.containsKey('thumbnailPath'), isFalse);
    });
  });

  group('Cloud sync — restoreFromCloud', () {
    Uint8List _encodeCloudPayload(List<Map<String, dynamic>> items) {
      return Uint8List.fromList(utf8.encode(jsonEncode({
        'v': 1,
        'updatedAt': '2026-05-23T15:00:00.000Z',
        'items': items,
      })));
    }

    test('restores rows that aren\'t already in the local box', () async {
      await ShelfStorageService.instance.init();
      // Local has one row already.
      await ShelfStorageService.instance.add(_item(id: 'local-only'));

      final cloudPayload = _encodeCloudPayload([
        ShelfItem(
          id: 'cloud-1',
          receivedAt: DateTime.utc(2026, 5, 1),
          originalName: 'shared.txt',
          sizeBytes: 100,
          localCachePath: '/this/is/discarded',
          remoteKey: '2026/05/cloud-1-shared.txt',
          category: ShelfCategory.link,
          contentSha: 'sha-cloud',
        ).toJson(),
        ShelfItem(
          id: 'cloud-2',
          receivedAt: DateTime.utc(2026, 5, 2),
          originalName: 'photo.jpg',
          sizeBytes: 2048,
          localCachePath: '/this/is/also/discarded',
          remoteKey: '2026/05/cloud-2-photo.jpg',
          category: ShelfCategory.image,
          contentSha: 'sha-cloud-2',
          thumbnailRemoteKey: '2026/05/cloud-2.jpg',
        ).toJson(),
      ]);

      ShelfStorageService.instance.cloudSyncDownloadOverride =
          (_) async => cloudPayload;

      final restored = await ShelfStorageService.instance.restoreFromCloud();
      expect(restored, 2);

      final all = ShelfStorageService.instance
          .getAll()
          .map((i) => i.id)
          .toSet();
      expect(all, {'local-only', 'cloud-1', 'cloud-2'});

      final c2 = ShelfStorageService.instance.getById('cloud-2')!;
      expect(c2.thumbnailRemoteKey, '2026/05/cloud-2.jpg');
      // Status normalized — cloud had it as queued in original, with
      // a remoteKey it must read back as uploaded.
      expect(c2.uploadStatus, ShelfUploadStatus.uploaded);
      // Device-specific fields stripped on the way out + restored as
      // placeholder on the way back in.
      expect(c2.localCachePath, '');
      expect(c2.thumbnailPath, isNull);
    });

    test('does NOT overwrite local rows that share an id with cloud',
        () async {
      await ShelfStorageService.instance.init();
      // Local row in a state we want to preserve.
      await ShelfStorageService.instance.add(_item(
        id: 'shared-id',
        uploadStatus: ShelfUploadStatus.uploading,
        localCachePath: '/local/active/path',
      ));

      // Cloud has the same id but stale.
      final cloudPayload = _encodeCloudPayload([
        ShelfItem(
          id: 'shared-id',
          receivedAt: DateTime.utc(2026, 4, 1),
          originalName: 'old.bin',
          sizeBytes: 999,
          localCachePath: '/stale',
          remoteKey: '2026/04/shared-id-old.bin',
          category: ShelfCategory.other,
          contentSha: 'sha-old',
          uploadStatus: ShelfUploadStatus.uploaded,
        ).toJson(),
      ]);
      ShelfStorageService.instance.cloudSyncDownloadOverride =
          (_) async => cloudPayload;

      final restored = await ShelfStorageService.instance.restoreFromCloud();
      expect(restored, 0, reason: 'existing local row should not be clobbered');

      final actual = ShelfStorageService.instance.getById('shared-id')!;
      expect(actual.uploadStatus, ShelfUploadStatus.uploading);
      expect(actual.localCachePath, '/local/active/path');
    });

    test('empty cloud payload restores nothing and is a no-op', () async {
      await ShelfStorageService.instance.init();
      ShelfStorageService.instance.cloudSyncDownloadOverride =
          (_) async => Uint8List(0);
      final restored = await ShelfStorageService.instance.restoreFromCloud();
      expect(restored, 0);
      expect(ShelfStorageService.instance.getAll(), isEmpty);
    });

    test('malformed cloud payload returns 0 (not thrown)', () async {
      await ShelfStorageService.instance.init();
      ShelfStorageService.instance.cloudSyncDownloadOverride =
          (_) async => Uint8List.fromList(utf8.encode('not json at all'));
      final restored = await ShelfStorageService.instance.restoreFromCloud();
      expect(restored, 0);
    });

    test('cloud sync skips when download override returns null', () async {
      await ShelfStorageService.instance.init();
      ShelfStorageService.instance.cloudSyncDownloadOverride =
          (_) async => null;
      final restored = await ShelfStorageService.instance.restoreFromCloud();
      expect(restored, 0);
    });
  });

  group('Cloud sync — init backfill', () {
    test(
        'init with a non-empty box schedules a backfill sync within '
        'the debounce window', () async {
      // First open: populate the box with rows from a "previous
      // session" so on the next init we look like an existing
      // install that has unsynced rows on disk.
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'pre1'));
      await ShelfStorageService.instance.add(_item(id: 'pre2'));
      await ShelfStorageService.instance.resetForTesting();

      // Hook the upload override BEFORE the re-init so the backfill
      // sync triggered from init() is captured.
      final uploads = <List<int>>[];
      ShelfStorageService.instance.cloudSyncUploadOverride =
          (data, _) async => uploads.add(data);

      await ShelfStorageService.instance.init();
      expect(ShelfStorageService.instance.getAll().length, 2,
          reason: 'rows persist across resetForTesting');

      // Debounce is 2s; wait past it. Without the init-time backfill
      // this would be 0 — the test verifies we don't lose pre-existing
      // rows just because the user hasn't touched the app since the
      // cloud-sync code shipped.
      await Future.delayed(const Duration(seconds: 3));
      expect(uploads.length, 1,
          reason:
              'init() must schedule a sync when the box already has rows');
    });

    test('init with an empty box does NOT fire a spurious sync',
        () async {
      final uploads = <List<int>>[];
      ShelfStorageService.instance.cloudSyncUploadOverride =
          (data, _) async => uploads.add(data);

      await ShelfStorageService.instance.init();
      // Wait past the debounce so any erroneously-scheduled timer
      // would have fired by now.
      await Future.delayed(const Duration(seconds: 3));
      expect(uploads, isEmpty,
          reason: 'empty box should not trigger a backfill upload');
    });
  });

  group('updateThumbnail{RemoteKey,LocalPath}', () {
    test('updateThumbnailRemoteKey sets the field on an existing row',
        () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 't1'));
      await ShelfStorageService.instance
          .updateThumbnailRemoteKey('t1', '2026/05/t1.jpg');
      final row = ShelfStorageService.instance.getById('t1')!;
      expect(row.thumbnailRemoteKey, '2026/05/t1.jpg');
    });

    test('updateThumbnailLocalPath sets the field without touching status',
        () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(
        _item(id: 't2')..enrichmentStatus = ShelfEnrichmentStatus.done,
      );
      await ShelfStorageService.instance
          .updateThumbnailLocalPath('t2', '/cached/path.jpg');
      final row = ShelfStorageService.instance.getById('t2')!;
      expect(row.thumbnailPath, '/cached/path.jpg');
      expect(row.enrichmentStatus, ShelfEnrichmentStatus.done);
    });

    test('updateThumbnailRemoteKey is a no-op when row missing', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance
          .updateThumbnailRemoteKey('does-not-exist', 'foo');
      expect(ShelfStorageService.instance.getById('does-not-exist'), isNull);
    });
  });

  group('User-defined display order', () {
    test('add() prepends each new id so newest lands at position 0',
        () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'a'));
      await ShelfStorageService.instance.add(_item(id: 'b'));
      await ShelfStorageService.instance.add(_item(id: 'c'));
      expect(ShelfStorageService.instance.getOrder(), ['c', 'b', 'a']);
    });

    test('delete() removes the id from the persisted order', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'a'));
      await ShelfStorageService.instance.add(_item(id: 'b'));
      await ShelfStorageService.instance.add(_item(id: 'c'));
      await ShelfStorageService.instance.delete('b');
      expect(ShelfStorageService.instance.getOrder(), ['c', 'a']);
    });

    test('setOrder sanitises against live ids (drops unknowns)', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'a'));
      await ShelfStorageService.instance.add(_item(id: 'b'));
      await ShelfStorageService.instance.setOrder(['b', 'ghost', 'a']);
      expect(ShelfStorageService.instance.getOrder(), ['b', 'a']);
    });

    test('setOrder dedupes', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'a'));
      await ShelfStorageService.instance.add(_item(id: 'b'));
      await ShelfStorageService.instance.setOrder(['a', 'b', 'a']);
      expect(ShelfStorageService.instance.getOrder(), ['a', 'b']);
    });

    test('setOrder is a no-op when the supplied list equals current order',
        () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'a'));
      await ShelfStorageService.instance.add(_item(id: 'b'));
      // Capture the timestamp of the current order's last write by
      // grabbing a sync snapshot via the override.
      final calls = <String>[];
      ShelfStorageService.instance.cloudSyncUploadOverride =
          (data, key) async {
        calls.add(jsonDecode(utf8.decode(data))['order'].toString());
      };
      // setOrder with the same content should not trigger a re-sync.
      await ShelfStorageService.instance.setOrder(['b', 'a']);
      await Future<void>.delayed(const Duration(seconds: 3));
      final firstCallCount = calls.length;

      await ShelfStorageService.instance.setOrder(['b', 'a']);
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(calls.length, firstCallCount,
          reason: 'No-op write must not schedule another upload');
    });
  });

  group('Pending-delete tombstones', () {
    test('mark + get round-trip', () async {
      await ShelfStorageService.instance.init();
      final entry = ShelfPendingDeleteEntry(
        itemId: 'gone',
        markedAt: DateTime.utc(2026, 5, 25, 10),
        remoteKey: '2026/05/gone.bin',
        thumbnailRemoteKey: '2026/05/gone.jpg',
      );
      await ShelfStorageService.instance.markPendingDelete(entry);
      expect(
        ShelfStorageService.instance.getPendingDeleteIds(),
        contains('gone'),
      );
      final fetched = ShelfStorageService.instance.getPendingDelete('gone');
      expect(fetched, isNotNull);
      expect(fetched!.remoteKey, '2026/05/gone.bin');
      expect(fetched.thumbnailRemoteKey, '2026/05/gone.jpg');
    });

    test('clearPendingDelete removes the tombstone', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.markPendingDelete(
        ShelfPendingDeleteEntry(
          itemId: 'gone',
          markedAt: DateTime.utc(2026, 5, 25, 10),
        ),
      );
      await ShelfStorageService.instance.clearPendingDelete('gone');
      expect(ShelfStorageService.instance.getPendingDeleteIds(), isEmpty);
    });

    test('getPendingDelete returns null for unknown ids', () async {
      await ShelfStorageService.instance.init();
      expect(
        ShelfStorageService.instance.getPendingDelete('never-seen'),
        isNull,
      );
    });
  });

  group('Cloud manifest v2 — order field round-trip', () {
    test('syncToCloud uploads v=2 payload with the order field', () async {
      await ShelfStorageService.instance.init();

      final captured = <Map<String, dynamic>>[];
      ShelfStorageService.instance.cloudSyncUploadOverride =
          (data, key) async {
        captured.add(
          jsonDecode(utf8.decode(data)) as Map<String, dynamic>,
        );
      };

      await ShelfStorageService.instance.add(_item(id: 'a'));
      await ShelfStorageService.instance.add(_item(id: 'b'));
      await ShelfStorageService.instance.setOrder(['b', 'a']);

      // Wait past the 2s debounce.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(captured, isNotEmpty);
      final last = captured.last;
      expect(last['v'], 2, reason: 'Manifest must advertise v2');
      expect(last['order'], ['b', 'a'],
          reason: 'order array must round-trip in the payload');
    });

    test(
        'restoreFromCloud reads order field and writes it locally; '
        'sanitises against current items', () async {
      await ShelfStorageService.instance.init();

      // Pretend the cloud has items b and c, plus an order list that
      // includes a ghost id "x" we should drop on restore.
      final payload = jsonEncode({
        'v': 2,
        'updatedAt': '2026-05-25T10:00:00Z',
        'items': [
          _item(id: 'b').toJson(),
          _item(id: 'c').toJson(),
        ],
        'order': ['x', 'c', 'b'],
      });
      ShelfStorageService.instance.cloudSyncDownloadOverride = (_) async {
        return Uint8List.fromList(utf8.encode(payload));
      };

      final restored = await ShelfStorageService.instance.restoreFromCloud();
      expect(restored, greaterThanOrEqualTo(2));
      // 'x' was filtered out; 'c' and 'b' were preserved (in input
      // order from the manifest).
      expect(ShelfStorageService.instance.getOrder(), ['c', 'b']);
    });

    test('restoreFromCloud accepts v1 payload (no order field) without '
        'wiping the local order', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'a'));
      await ShelfStorageService.instance.setOrder(['a']);

      final v1Payload = jsonEncode({
        'v': 1,
        'updatedAt': '2026-05-25T10:00:00Z',
        'items': [_item(id: 'a').toJson()],
        // NOTE: no `order` key.
      });
      ShelfStorageService.instance.cloudSyncDownloadOverride =
          (_) async => Uint8List.fromList(utf8.encode(v1Payload));

      await ShelfStorageService.instance.restoreFromCloud();
      expect(
        ShelfStorageService.instance.getOrder(),
        ['a'],
        reason: 'v1 restore must NOT wipe the locally-set order',
      );
    });
  });

  group('Merge-before-write (clobber guard)', () {
    Uint8List cloudManifest(List<ShelfItem> items) =>
        Uint8List.fromList(utf8.encode(jsonEncode({
          'v': 2,
          'updatedAt': '2026-06-16T00:00:00.000Z',
          'items': items.map((i) => i.toJson()).toList(),
          'order': items.map((i) => i.id).toList(),
        })));

    test('folds in cloud items the box lacks; keeps existing rows', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'local'));

      ShelfStorageService.instance.cloudMergeReadOverride = () async => [
            cloudManifest([
              _item(id: 'local'), // already present — skipped
              _item(id: 'web-1', category: ShelfCategory.link),
              _item(id: 'web-2', category: ShelfCategory.image),
            ]),
          ];

      final ok =
          await ShelfStorageService.instance.mergeCloudAdditionsForTest();
      expect(ok, isTrue);
      expect(ShelfStorageService.instance.getAll().map((i) => i.id).toSet(),
          {'local', 'web-1', 'web-2'});
    });

    test('does NOT resurrect a tombstoned (locally-deleted) item', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'keep'));
      // Simulate a local delete whose cloud cleanup is still pending.
      await ShelfStorageService.instance.markPendingDelete(
        ShelfPendingDeleteEntry(
            itemId: 'deleted', markedAt: DateTime.utc(2026, 6, 16)),
      );

      ShelfStorageService.instance.cloudMergeReadOverride = () async => [
            cloudManifest([_item(id: 'keep'), _item(id: 'deleted')]),
          ];

      final ok =
          await ShelfStorageService.instance.mergeCloudAdditionsForTest();
      expect(ok, isTrue);
      expect(ShelfStorageService.instance.getById('deleted'), isNull,
          reason: 'tombstoned id must not be folded back in');
    });

    test('aborts (returns false) when the cloud read fails', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'local'));
      ShelfStorageService.instance.cloudMergeReadOverride =
          () async => throw StateError('transient gateway error');

      final ok =
          await ShelfStorageService.instance.mergeCloudAdditionsForTest();
      expect(ok, isFalse, reason: 'a read failure must abort the upload');
      expect(ShelfStorageService.instance.getAll().map((i) => i.id).toSet(),
          {'local'}, reason: 'box untouched on abort');
    });

    test('empty cloud read is a no-op that succeeds', () async {
      await ShelfStorageService.instance.init();
      await ShelfStorageService.instance.add(_item(id: 'local'));
      ShelfStorageService.instance.cloudMergeReadOverride =
          () async => <Uint8List>[];
      final ok =
          await ShelfStorageService.instance.mergeCloudAdditionsForTest();
      expect(ok, isTrue);
      expect(ShelfStorageService.instance.getAll().map((i) => i.id).toSet(),
          {'local'});
    });
  });

  group('flushNow', () {
    test('triggers an immediate upload reflecting the current box', () async {
      await ShelfStorageService.instance.init();
      final uploads = <Map<String, dynamic>>[];
      ShelfStorageService.instance.cloudSyncUploadOverride = (data, _) async {
        uploads.add(jsonDecode(utf8.decode(data)) as Map<String, dynamic>);
      };
      await ShelfStorageService.instance.add(_item(id: 'a'));
      await ShelfStorageService.instance.flushNow();
      expect(uploads, isNotEmpty);
      final ids = (uploads.last['items'] as List)
          .map((e) => (e as Map<String, dynamic>)['id'])
          .toSet();
      expect(ids, contains('a'));
    });
  });
}
