// Integration-flavoured unit tests for DumpStorageService — exercises
// the full Hive round-trip + dedup (R8) + orphan GC (R7) + pendingAuth
// filtering (R10). Each test gets a fresh tempDir + Hive instance.

import 'dart:async';
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
}
