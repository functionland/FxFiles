// Integration-flavoured unit tests for DumpStorageService — exercises
// the full Hive round-trip + dedup (R8) + orphan GC (R7) + pendingAuth
// filtering (R10). Each test gets a fresh tempDir + Hive instance.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/core/services/dump_storage_service.dart';

DumpItem _item({
  required String id,
  String contentSha = 'sha-default',
  int sizeBytes = 100,
  String localCachePath = '/tmp/missing',
  DumpUploadStatus uploadStatus = DumpUploadStatus.queued,
  DumpCategory category = DumpCategory.other,
  DateTime? receivedAt,
}) {
  return DumpItem(
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
    await DumpStorageService.instance.resetForTesting();
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
      await DumpStorageService.instance.init();
      expect(DumpStorageService.instance.isInitialized, isTrue);
      expect(Hive.isAdapterRegistered(60), isTrue, reason: 'DumpCategory');
      expect(Hive.isAdapterRegistered(61), isTrue, reason: 'DumpUploadStatus');
      expect(Hive.isAdapterRegistered(62), isTrue, reason: 'DumpItem');
      expect(Hive.isAdapterRegistered(63), isTrue,
          reason: 'DumpEnrichmentStatus');
    });

    test('is idempotent — second call does not throw', () async {
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.init();
      expect(DumpStorageService.instance.isInitialized, isTrue);
    });
  });

  group('add / getById / getAll', () {
    test('adds and retrieves an item by id', () async {
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.add(_item(id: 'a'));
      final fetched = DumpStorageService.instance.getById('a');
      expect(fetched, isNotNull);
      expect(fetched!.id, 'a');
    });

    test('getAll returns all stored items', () async {
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.add(_item(id: 'a'));
      await DumpStorageService.instance.add(_item(id: 'b'));
      await DumpStorageService.instance.add(_item(id: 'c'));
      final all = DumpStorageService.instance.getAll();
      expect(all.map((i) => i.id).toSet(), {'a', 'b', 'c'});
    });
  });

  group('findByContentSha (candidate dedup)', () {
    test('returns all items matching the contentSha', () async {
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.add(
        _item(id: 'a', contentSha: 'sha-x', sizeBytes: 100),
      );
      await DumpStorageService.instance.add(
        _item(id: 'b', contentSha: 'sha-x', sizeBytes: 200),
      );
      await DumpStorageService.instance.add(
        _item(id: 'c', contentSha: 'sha-y', sizeBytes: 100),
      );
      final matches =
          DumpStorageService.instance.findByContentSha('sha-x');
      expect(matches.map((i) => i.id).toSet(), {'a', 'b'});
    });

    test('returns empty list when nothing matches', () async {
      await DumpStorageService.instance.init();
      expect(
        DumpStorageService.instance.findByContentSha('nope'),
        isEmpty,
      );
    });
  });

  group('findDuplicate (R8: candidate + size + full-hash verify)', () {
    test('returns null when no candidate matches contentSha', () async {
      await DumpStorageService.instance.init();
      final result = await DumpStorageService.instance.findDuplicate(
        contentSha: 'nope',
        sizeBytes: 100,
        sourceFilePath: '/does/not/exist',
      );
      expect(result, isNull);
    });

    test('returns null when contentSha matches but sizeBytes differs',
        () async {
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.add(
        _item(id: 'a', contentSha: 'sha-x', sizeBytes: 100),
      );
      final result = await DumpStorageService.instance.findDuplicate(
        contentSha: 'sha-x',
        sizeBytes: 200,
        sourceFilePath: '/does/not/exist',
      );
      expect(result, isNull);
    });

    test(
        'accepts candidate for large files (>50MB) on sha+size match without '
        'full hash', () async {
      await DumpStorageService.instance.init();
      // Use a >50MB sizeBytes but a fake path — we MUST not read the file.
      const huge = 60 * 1024 * 1024;
      await DumpStorageService.instance.add(
        _item(id: 'big', contentSha: 'sha-big', sizeBytes: huge),
      );
      final result = await DumpStorageService.instance.findDuplicate(
        contentSha: 'sha-big',
        sizeBytes: huge,
        sourceFilePath: '/does/not/exist',
      );
      expect(result, isNotNull);
      expect(result!.id, 'big');
    });

    test('for small files (≤50MB), verifies full hash and accepts on match',
        () async {
      await DumpStorageService.instance.init();
      // Create two real files with identical bytes.
      final bytes = Uint8List.fromList(
        List<int>.generate(1024, (i) => i % 256),
      );
      final f1 = File('${tempDir.path}/dup-existing.bin');
      final f2 = File('${tempDir.path}/dup-incoming.bin');
      await f1.writeAsBytes(bytes);
      await f2.writeAsBytes(bytes);

      final sha = sha256.convert(bytes).toString();
      await DumpStorageService.instance.add(
        _item(
          id: 'existing',
          contentSha: sha,
          sizeBytes: bytes.length,
          localCachePath: f1.path,
        ),
      );

      final result = await DumpStorageService.instance.findDuplicate(
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
      await DumpStorageService.instance.init();
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
      await DumpStorageService.instance.add(
        _item(
          id: 'existing',
          contentSha: fakeCandidateSha,
          sizeBytes: 1024,
          localCachePath: f1.path,
        ),
      );

      final result = await DumpStorageService.instance.findDuplicate(
        contentSha: fakeCandidateSha,
        sizeBytes: 1024,
        sourceFilePath: f2.path,
      );
      expect(result, isNull, reason: 'Full-hash check must reject collision');
    });
  });

  group('updateStatus', () {
    test('updates status + remoteKey + errorMessage atomically', () async {
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.add(
        _item(id: 'a', uploadStatus: DumpUploadStatus.queued),
      );

      await DumpStorageService.instance.updateStatus(
        'a',
        DumpUploadStatus.uploaded,
        remoteKey: '2026/05/a.bin',
      );

      final after = DumpStorageService.instance.getById('a')!;
      expect(after.uploadStatus, DumpUploadStatus.uploaded);
      expect(after.remoteKey, '2026/05/a.bin');
    });

    test('no-op on unknown id', () async {
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.updateStatus(
        'nope',
        DumpUploadStatus.failed,
      );
      expect(DumpStorageService.instance.getById('nope'), isNull);
    });
  });

  group('updateEnrichment', () {
    test('updates enrichment fields without touching upload fields',
        () async {
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.add(
        _item(id: 'a', uploadStatus: DumpUploadStatus.uploaded),
      );

      await DumpStorageService.instance.updateEnrichment(
        'a',
        title: 'Sunset',
        description: 'sky, dusk',
        thumbnailPath: '/tmp/thumbs/a.jpg',
        mlLabels: const ['sky', 'dusk'],
        status: DumpEnrichmentStatus.done,
      );

      final after = DumpStorageService.instance.getById('a')!;
      expect(after.autoTitle, 'Sunset');
      expect(after.autoDescription, 'sky, dusk');
      expect(after.thumbnailPath, '/tmp/thumbs/a.jpg');
      expect(after.mlLabels, const ['sky', 'dusk']);
      expect(after.enrichmentStatus, DumpEnrichmentStatus.done);
      expect(after.uploadStatus, DumpUploadStatus.uploaded,
          reason: 'enrichment must not touch uploadStatus');
    });
  });

  group('delete', () {
    test('removes the item from the box', () async {
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.add(_item(id: 'a'));
      await DumpStorageService.instance.delete('a');
      expect(DumpStorageService.instance.getById('a'), isNull);
    });
  });

  group('getPendingAuthItems', () {
    test('returns only items in pendingAuth state', () async {
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.add(
        _item(id: 'p1', uploadStatus: DumpUploadStatus.pendingAuth),
      );
      await DumpStorageService.instance.add(
        _item(id: 'q1', uploadStatus: DumpUploadStatus.queued),
      );
      await DumpStorageService.instance.add(
        _item(id: 'p2', uploadStatus: DumpUploadStatus.pendingAuth),
      );

      final result = DumpStorageService.instance.getPendingAuthItems();
      expect(result.map((i) => i.id).toSet(), {'p1', 'p2'});
    });
  });

  group('watch (Stream<List<DumpItem>>)', () {
    test('emits initial snapshot then re-emits on mutation', () async {
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.add(_item(id: 'a'));

      final emissions = <List<DumpItem>>[];
      final completer = Completer<void>();
      final sub = DumpStorageService.instance.watch().listen((batch) {
        emissions.add(batch);
        if (emissions.length >= 2) completer.complete();
      });

      // Mutate after subscribing → second emission.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await DumpStorageService.instance.add(_item(id: 'b'));
      await completer.future.timeout(const Duration(seconds: 1));
      await sub.cancel();

      expect(emissions.length, greaterThanOrEqualTo(2));
      // First emission has 1 item, second has 2.
      expect(emissions.first.length, 1);
      expect(emissions.last.map((i) => i.id).toSet(), {'a', 'b'});
    });
  });

  group('garbageCollectOrphans (R7)', () {
    test('deletes files in pendingDir without a matching DumpItem', () async {
      await DumpStorageService.instance.init();
      final pendingDir =
          await Directory('${tempDir.path}/dump_pending').create();

      final orphan = File('${pendingDir.path}/orphan.bin');
      final tracked = File('${pendingDir.path}/tracked.bin');
      await orphan.writeAsBytes([1, 2, 3]);
      await tracked.writeAsBytes([4, 5, 6]);

      await DumpStorageService.instance.add(
        _item(id: 'tracked', localCachePath: tracked.path),
      );

      final deleted =
          await DumpStorageService.instance.garbageCollectOrphans(pendingDir);

      expect(deleted, 1);
      expect(await orphan.exists(), isFalse);
      expect(await tracked.exists(), isTrue);
    });

    test('returns 0 and is a no-op on missing directory', () async {
      await DumpStorageService.instance.init();
      final missing = Directory('${tempDir.path}/does-not-exist');
      final deleted =
          await DumpStorageService.instance.garbageCollectOrphans(missing);
      expect(deleted, 0);
    });
  });

  group('DumpItem JSON round-trip', () {
    test('toJson excludes device-specific paths', () {
      final item = DumpItem(
        id: 'abc',
        receivedAt: DateTime.utc(2026, 5, 23, 14, 47),
        originalName: 'Note.txt',
        sizeBytes: 44,
        localCachePath: '/data/.../dump_pending/abc-note.txt',
        thumbnailPath: '/data/.../dump_thumbs/abc.jpg',
        category: DumpCategory.link,
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
      final item = DumpItem.fromJson(json);
      expect(item.uploadStatus, DumpUploadStatus.uploaded);
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
      final item = DumpItem.fromJson(json);
      expect(item.uploadStatus, DumpUploadStatus.pendingAuth);
    });

    test('toJson → fromJson round-trip preserves cross-device fields', () {
      final original = DumpItem(
        id: 'rt',
        receivedAt: DateTime.utc(2026, 4, 1, 10, 30),
        originalName: 'photo.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 1024,
        localCachePath: '/local/will/be/lost',
        remoteKey: '2026/04/rt-photo.jpg',
        thumbnailPath: '/local/thumb/will/be/lost',
        thumbnailRemoteKey: '2026/04/rt.jpg',
        category: DumpCategory.image,
        uploadStatus: DumpUploadStatus.uploaded,
        sourceAppPackage: 'com.instagram.android',
        textPayload: null,
        mlLabels: const ['cat', 'sunset'],
        contentSha: 'sha-img',
        autoTitle: 'Sunset',
        autoDescription: 'cat, sunset',
        enrichmentStatus: DumpEnrichmentStatus.done,
      );
      final clone = DumpItem.fromJson(original.toJson());
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
      await DumpStorageService.instance.init();
      final uploads = <List<int>>[];
      DumpStorageService.instance.cloudSyncUploadOverride =
          (data, _) async => uploads.add(data);

      // Three rapid mutations should debounce to a single upload.
      await DumpStorageService.instance.add(_item(id: 'a'));
      await DumpStorageService.instance.add(_item(id: 'b'));
      await DumpStorageService.instance.add(_item(id: 'c'));

      // Debounce is 5s; fast-forward by triggering the sync explicitly
      // (production code waits for the Timer).
      await DumpStorageService.instance.syncToCloud();

      expect(uploads.length, 1);
      final payload =
          jsonDecode(utf8.decode(uploads.single)) as Map<String, dynamic>;
      final ids = (payload['items'] as List)
          .map((e) => (e as Map<String, dynamic>)['id'] as String)
          .toSet();
      expect(ids, {'a', 'b', 'c'});
    });

    test('upload payload omits localCachePath/thumbnailPath', () async {
      await DumpStorageService.instance.init();
      late Map<String, dynamic> captured;
      DumpStorageService.instance.cloudSyncUploadOverride = (data, _) async {
        captured = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      };
      await DumpStorageService.instance.add(
        _item(id: 'x', localCachePath: '/private/local'),
      );
      await DumpStorageService.instance.syncToCloud();
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
      await DumpStorageService.instance.init();
      // Local has one row already.
      await DumpStorageService.instance.add(_item(id: 'local-only'));

      final cloudPayload = _encodeCloudPayload([
        DumpItem(
          id: 'cloud-1',
          receivedAt: DateTime.utc(2026, 5, 1),
          originalName: 'shared.txt',
          sizeBytes: 100,
          localCachePath: '/this/is/discarded',
          remoteKey: '2026/05/cloud-1-shared.txt',
          category: DumpCategory.link,
          contentSha: 'sha-cloud',
        ).toJson(),
        DumpItem(
          id: 'cloud-2',
          receivedAt: DateTime.utc(2026, 5, 2),
          originalName: 'photo.jpg',
          sizeBytes: 2048,
          localCachePath: '/this/is/also/discarded',
          remoteKey: '2026/05/cloud-2-photo.jpg',
          category: DumpCategory.image,
          contentSha: 'sha-cloud-2',
          thumbnailRemoteKey: '2026/05/cloud-2.jpg',
        ).toJson(),
      ]);

      DumpStorageService.instance.cloudSyncDownloadOverride =
          (_) async => cloudPayload;

      final restored = await DumpStorageService.instance.restoreFromCloud();
      expect(restored, 2);

      final all = DumpStorageService.instance
          .getAll()
          .map((i) => i.id)
          .toSet();
      expect(all, {'local-only', 'cloud-1', 'cloud-2'});

      final c2 = DumpStorageService.instance.getById('cloud-2')!;
      expect(c2.thumbnailRemoteKey, '2026/05/cloud-2.jpg');
      // Status normalized — cloud had it as queued in original, with
      // a remoteKey it must read back as uploaded.
      expect(c2.uploadStatus, DumpUploadStatus.uploaded);
      // Device-specific fields stripped on the way out + restored as
      // placeholder on the way back in.
      expect(c2.localCachePath, '');
      expect(c2.thumbnailPath, isNull);
    });

    test('does NOT overwrite local rows that share an id with cloud',
        () async {
      await DumpStorageService.instance.init();
      // Local row in a state we want to preserve.
      await DumpStorageService.instance.add(_item(
        id: 'shared-id',
        uploadStatus: DumpUploadStatus.uploading,
        localCachePath: '/local/active/path',
      ));

      // Cloud has the same id but stale.
      final cloudPayload = _encodeCloudPayload([
        DumpItem(
          id: 'shared-id',
          receivedAt: DateTime.utc(2026, 4, 1),
          originalName: 'old.bin',
          sizeBytes: 999,
          localCachePath: '/stale',
          remoteKey: '2026/04/shared-id-old.bin',
          category: DumpCategory.other,
          contentSha: 'sha-old',
          uploadStatus: DumpUploadStatus.uploaded,
        ).toJson(),
      ]);
      DumpStorageService.instance.cloudSyncDownloadOverride =
          (_) async => cloudPayload;

      final restored = await DumpStorageService.instance.restoreFromCloud();
      expect(restored, 0, reason: 'existing local row should not be clobbered');

      final actual = DumpStorageService.instance.getById('shared-id')!;
      expect(actual.uploadStatus, DumpUploadStatus.uploading);
      expect(actual.localCachePath, '/local/active/path');
    });

    test('empty cloud payload restores nothing and is a no-op', () async {
      await DumpStorageService.instance.init();
      DumpStorageService.instance.cloudSyncDownloadOverride =
          (_) async => Uint8List(0);
      final restored = await DumpStorageService.instance.restoreFromCloud();
      expect(restored, 0);
      expect(DumpStorageService.instance.getAll(), isEmpty);
    });

    test('malformed cloud payload returns 0 (not thrown)', () async {
      await DumpStorageService.instance.init();
      DumpStorageService.instance.cloudSyncDownloadOverride =
          (_) async => Uint8List.fromList(utf8.encode('not json at all'));
      final restored = await DumpStorageService.instance.restoreFromCloud();
      expect(restored, 0);
    });

    test('cloud sync skips when download override returns null', () async {
      await DumpStorageService.instance.init();
      DumpStorageService.instance.cloudSyncDownloadOverride =
          (_) async => null;
      final restored = await DumpStorageService.instance.restoreFromCloud();
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
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.add(_item(id: 'pre1'));
      await DumpStorageService.instance.add(_item(id: 'pre2'));
      await DumpStorageService.instance.resetForTesting();

      // Hook the upload override BEFORE the re-init so the backfill
      // sync triggered from init() is captured.
      final uploads = <List<int>>[];
      DumpStorageService.instance.cloudSyncUploadOverride =
          (data, _) async => uploads.add(data);

      await DumpStorageService.instance.init();
      expect(DumpStorageService.instance.getAll().length, 2,
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
      DumpStorageService.instance.cloudSyncUploadOverride =
          (data, _) async => uploads.add(data);

      await DumpStorageService.instance.init();
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
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.add(_item(id: 't1'));
      await DumpStorageService.instance
          .updateThumbnailRemoteKey('t1', '2026/05/t1.jpg');
      final row = DumpStorageService.instance.getById('t1')!;
      expect(row.thumbnailRemoteKey, '2026/05/t1.jpg');
    });

    test('updateThumbnailLocalPath sets the field without touching status',
        () async {
      await DumpStorageService.instance.init();
      await DumpStorageService.instance.add(
        _item(id: 't2')..enrichmentStatus = DumpEnrichmentStatus.done,
      );
      await DumpStorageService.instance
          .updateThumbnailLocalPath('t2', '/cached/path.jpg');
      final row = DumpStorageService.instance.getById('t2')!;
      expect(row.thumbnailPath, '/cached/path.jpg');
      expect(row.enrichmentStatus, DumpEnrichmentStatus.done);
    });

    test('updateThumbnailRemoteKey is a no-op when row missing', () async {
      await DumpStorageService.instance.init();
      await DumpStorageService.instance
          .updateThumbnailRemoteKey('does-not-exist', 'foo');
      expect(DumpStorageService.instance.getById('does-not-exist'), isNull);
    });
  });
}
