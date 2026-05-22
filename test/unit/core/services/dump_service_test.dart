// Tests for `DumpService` ingestion behavior. Covers:
//   - encryption-key gating (R10) → queued vs pendingAuth
//   - dedup via DumpStorageService.findDuplicate (R8 candidate match)
//   - classification routing
//   - missing payload files are skipped, not errored
//   - retryPending picks up only pendingAuth rows
//
// Heavy collaborators (SyncService, FulaApiService, AuthService) are
// avoided by using DumpService.initForTesting() + DumpService.encryptionKeyProvider
// seams. Upload-side behavior (uploadOne / drain) is verified at the
// device-level smoke test in Session 5.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/core/services/dump_notification_service.dart';
import 'package:fula_files/core/services/dump_service.dart';
import 'package:fula_files/core/services/dump_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  Future<File> writeBytes(String name, List<int> bytes) async {
    final f = File('${tempDir.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dump_service_test_');
    Hive.init(tempDir.path);

    // Suppress the Android MethodChannel so the in-test calls to
    // DumpNotificationService don't try to reach a real platform plugin.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(DumpNotificationService.channelName),
      (_) async => true,
    );

    await DumpService.instance.resetForTesting();
    await DumpStorageService.instance.resetForTesting();
    await DumpService.instance.initForTesting();
  });

  tearDown(() async {
    await DumpService.instance.resetForTesting();
    await DumpStorageService.instance.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(DumpNotificationService.channelName),
      null,
    );
    await Hive.deleteFromDisk();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {
      // Windows occasionally holds the dir briefly; harmless.
    }
  });

  group('ingestStagedPayload — encryption-key gating (R10)', () {
    test('writes items as queued when an encryption key is available',
        () async {
      DumpService.instance.encryptionKeyProvider = () async =>
          Uint8List.fromList(List<int>.filled(32, 0x42));
      final f = await writeBytes('a.txt', [1, 2, 3]);

      final created = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['text/plain'],
        originalNames: const ['a.txt'],
      );

      expect(created.length, 1);
      expect(created.first.uploadStatus, DumpUploadStatus.queued);
    });

    test('writes items as pendingAuth when no key is available', () async {
      DumpService.instance.encryptionKeyProvider = () async => null;
      final f = await writeBytes('a.txt', [1, 2, 3]);

      final created = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['text/plain'],
        originalNames: const ['a.txt'],
      );

      expect(created.first.uploadStatus, DumpUploadStatus.pendingAuth);
    });

    test('treats empty Uint8List as "no key" (defensive default)', () async {
      DumpService.instance.encryptionKeyProvider = () async => Uint8List(0);
      final f = await writeBytes('a.txt', [1, 2, 3]);

      final created = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['text/plain'],
        originalNames: const ['a.txt'],
      );

      expect(created.first.uploadStatus, DumpUploadStatus.pendingAuth);
    });

    test('treats thrown exception in keyProvider as "no key"', () async {
      DumpService.instance.encryptionKeyProvider =
          () async => throw StateError('keychain locked');
      final f = await writeBytes('a.txt', [1, 2, 3]);

      final created = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['text/plain'],
        originalNames: const ['a.txt'],
      );

      expect(created.first.uploadStatus, DumpUploadStatus.pendingAuth);
    });
  });

  group('ingestStagedPayload — dedup', () {
    setUp(() {
      DumpService.instance.encryptionKeyProvider =
          () async => Uint8List.fromList(List<int>.filled(32, 0x01));
    });

    test('a second ingest of identical bytes is skipped', () async {
      final f1 = await writeBytes('dup1.bin', [1, 2, 3, 4, 5]);
      final f2 = await writeBytes('dup2.bin', [1, 2, 3, 4, 5]);

      final first = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f1.path],
        mimeTypes: const [null],
        originalNames: const ['dup1.bin'],
      );
      expect(first.length, 1);

      final second = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f2.path],
        mimeTypes: const [null],
        originalNames: const ['dup2.bin'],
      );
      expect(second, isEmpty, reason: 'Same bytes ⇒ deduped');

      expect(DumpStorageService.instance.getAll().length, 1);
    });

    test('different bytes (same length) are NOT deduped', () async {
      final f1 = await writeBytes('a.bin', [0xAA, 0xAA, 0xAA, 0xAA]);
      final f2 = await writeBytes('b.bin', [0xBB, 0xBB, 0xBB, 0xBB]);

      await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f1.path],
        mimeTypes: const [null],
        originalNames: const ['a.bin'],
      );
      final second = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f2.path],
        mimeTypes: const [null],
        originalNames: const ['b.bin'],
      );
      expect(second.length, 1);
      expect(DumpStorageService.instance.getAll().length, 2);
    });
  });

  group('ingestStagedPayload — classification routing', () {
    setUp(() {
      DumpService.instance.encryptionKeyProvider =
          () async => Uint8List.fromList(List<int>.filled(32, 0x05));
    });

    test('image MIME → DumpCategory.image', () async {
      final f = await writeBytes('IMG_1234.jpg', List<int>.filled(16, 0));
      final created = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['image/jpeg'],
        originalNames: const ['IMG_1234.jpg'],
      );
      expect(created.first.category, DumpCategory.image);
    });

    test('image MIME with screenshot in filename → screenshot', () async {
      final f = await writeBytes('Screenshot_x.png', List<int>.filled(16, 0));
      final created = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['image/png'],
        originalNames: const ['Screenshot_x.png'],
      );
      expect(created.first.category, DumpCategory.screenshot);
    });

    test('text/plain payload that is a URL → link', () async {
      final f = await writeBytes('share.txt', 'https://example.com'.codeUnits);
      final created = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['text/plain'],
        originalNames: const ['share.txt'],
        textPayload: 'https://example.com',
      );
      expect(created.first.category, DumpCategory.link);
      expect(created.first.textPayload, 'https://example.com');
    });

    test('plain prose text/plain payload → note', () async {
      final f = await writeBytes('share.txt', 'buy milk'.codeUnits);
      final created = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['text/plain'],
        originalNames: const ['share.txt'],
        textPayload: 'buy milk',
      );
      expect(created.first.category, DumpCategory.note);
    });

    test('PDF → document', () async {
      final f = await writeBytes('report.pdf', List<int>.filled(16, 0));
      final created = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['application/pdf'],
        originalNames: const ['report.pdf'],
      );
      expect(created.first.category, DumpCategory.document);
    });
  });

  group('ingestStagedPayload — robustness', () {
    setUp(() {
      DumpService.instance.encryptionKeyProvider =
          () async => Uint8List.fromList(List<int>.filled(32, 0x77));
    });

    test('missing source file is skipped, not errored', () async {
      final created = await DumpService.instance.ingestStagedPayload(
        cachedPaths: ['${tempDir.path}/does-not-exist.bin'],
        mimeTypes: const [null],
        originalNames: const ['ghost.bin'],
      );
      expect(created, isEmpty);
      expect(DumpStorageService.instance.getAll(), isEmpty);
    });

    test('mixed missing + present: only present ones land', () async {
      final f = await writeBytes('real.bin', [9, 9, 9]);
      final created = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [
          '${tempDir.path}/ghost.bin',
          f.path,
        ],
        mimeTypes: const [null, null],
        originalNames: const ['ghost.bin', 'real.bin'],
      );
      expect(created.length, 1);
      expect(created.first.originalName, 'real.bin');
    });

    test('sourcePackage is preserved on the row', () async {
      final f = await writeBytes('a.bin', [1]);
      final created = await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const [null],
        originalNames: const ['a.bin'],
        sourcePackage: 'com.example.gallery',
      );
      expect(created.first.sourceAppPackage, 'com.example.gallery');
    });
  });

  group('retryPending', () {
    test('with no key → returns 0 and does not flip any status', () async {
      DumpService.instance.encryptionKeyProvider = () async => null;
      final f = await writeBytes('a.bin', [1]);
      await DumpService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const [null],
        originalNames: const ['a.bin'],
      );
      expect(DumpStorageService.instance.getPendingAuthItems().length, 1);

      final retried = await DumpService.instance.retryPending();
      expect(retried, 0);
      expect(DumpStorageService.instance.getPendingAuthItems().length, 1);
    });

    // Note: the "with key → flips rows" path is verified at the
    // device-level smoke test in Session 5. Exercising it here would
    // need a SyncService / FulaApiService stub (retryPending fires
    // uploadOne via `unawaited`); that wiring is out of scope for
    // Session 2's unit test surface.
  });
}
