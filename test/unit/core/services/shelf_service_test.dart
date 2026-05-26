// Tests for `ShelfService` ingestion behavior. Covers:
//   - encryption-key gating (R10) → queued vs pendingAuth
//   - dedup via ShelfStorageService.findDuplicate (R8 candidate match)
//   - classification routing
//   - missing payload files are skipped, not errored
//   - retryPending picks up only pendingAuth rows
//
// Heavy collaborators (SyncService, FulaApiService, AuthService) are
// avoided by using ShelfService.initForTesting() + ShelfService.encryptionKeyProvider
// seams. Upload-side behavior (uploadOne / drain) is verified at the
// device-level smoke test in Session 5.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_notification_service.dart';
import 'package:fula_files/core/services/shelf_service.dart';
import 'package:fula_files/core/services/shelf_storage_service.dart';

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
    // ShelfNotificationService don't try to reach a real platform plugin.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(ShelfNotificationService.channelName),
      (_) async => true,
    );

    await ShelfService.instance.resetForTesting();
    await ShelfStorageService.instance.resetForTesting();
    await ShelfService.instance.initForTesting();
  });

  tearDown(() async {
    await ShelfService.instance.resetForTesting();
    await ShelfStorageService.instance.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(ShelfNotificationService.channelName),
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
      ShelfService.instance.encryptionKeyProvider = () async =>
          Uint8List.fromList(List<int>.filled(32, 0x42));
      final f = await writeBytes('a.txt', [1, 2, 3]);

      final created = await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['text/plain'],
        originalNames: const ['a.txt'],
      );

      expect(created.length, 1);
      expect(created.first.uploadStatus, ShelfUploadStatus.queued);
    });

    test('writes items as pendingAuth when no key is available', () async {
      ShelfService.instance.encryptionKeyProvider = () async => null;
      final f = await writeBytes('a.txt', [1, 2, 3]);

      final created = await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['text/plain'],
        originalNames: const ['a.txt'],
      );

      expect(created.first.uploadStatus, ShelfUploadStatus.pendingAuth);
    });

    test('treats empty Uint8List as "no key" (defensive default)', () async {
      ShelfService.instance.encryptionKeyProvider = () async => Uint8List(0);
      final f = await writeBytes('a.txt', [1, 2, 3]);

      final created = await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['text/plain'],
        originalNames: const ['a.txt'],
      );

      expect(created.first.uploadStatus, ShelfUploadStatus.pendingAuth);
    });

    test('treats thrown exception in keyProvider as "no key"', () async {
      ShelfService.instance.encryptionKeyProvider =
          () async => throw StateError('keychain locked');
      final f = await writeBytes('a.txt', [1, 2, 3]);

      final created = await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['text/plain'],
        originalNames: const ['a.txt'],
      );

      expect(created.first.uploadStatus, ShelfUploadStatus.pendingAuth);
    });
  });

  group('ingestStagedPayload — dedup', () {
    setUp(() {
      ShelfService.instance.encryptionKeyProvider =
          () async => Uint8List.fromList(List<int>.filled(32, 0x01));
    });

    test('a second ingest of identical bytes is skipped', () async {
      final f1 = await writeBytes('dup1.bin', [1, 2, 3, 4, 5]);
      final f2 = await writeBytes('dup2.bin', [1, 2, 3, 4, 5]);

      final first = await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f1.path],
        mimeTypes: const [null],
        originalNames: const ['dup1.bin'],
      );
      expect(first.length, 1);

      final second = await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f2.path],
        mimeTypes: const [null],
        originalNames: const ['dup2.bin'],
      );
      expect(second, isEmpty, reason: 'Same bytes ⇒ deduped');

      expect(ShelfStorageService.instance.getAll().length, 1);
    });

    test('different bytes (same length) are NOT deduped', () async {
      final f1 = await writeBytes('a.bin', [0xAA, 0xAA, 0xAA, 0xAA]);
      final f2 = await writeBytes('b.bin', [0xBB, 0xBB, 0xBB, 0xBB]);

      await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f1.path],
        mimeTypes: const [null],
        originalNames: const ['a.bin'],
      );
      final second = await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f2.path],
        mimeTypes: const [null],
        originalNames: const ['b.bin'],
      );
      expect(second.length, 1);
      expect(ShelfStorageService.instance.getAll().length, 2);
    });
  });

  group('ingestAndSchedule — duplicate notification UX', () {
    late List<MethodCall> methodCalls;

    setUp(() {
      // Replace the outer setUp's pass-through handler with one that
      // records every call so we can assert which notification method
      // fired for each ingest scenario.
      methodCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        MethodChannel(ShelfNotificationService.channelName),
        (call) async {
          methodCalls.add(call);
          return true;
        },
      );
      // Force the Android channel even on the Windows test host so we
      // exercise the Android-side routing (otherwise _isAndroidEnabled
      // is false and the channel is never invoked).
      ShelfNotificationService.debugForceAndroid = true;
      ShelfService.instance.encryptionKeyProvider =
          () async => Uint8List.fromList(List<int>.filled(32, 0x77));
    });

    tearDown(() {
      ShelfNotificationService.debugForceAndroid = null;
    });

    test(
        're-dumping the same bytes posts showShelfDuplicate (not '
        'showShelfComplete/showShelfReceived), with the duplicate count',
        () async {
      final f1 = await writeBytes('orig.bin', [10, 20, 30, 40, 50]);
      final f2 = await writeBytes('redump.bin', [10, 20, 30, 40, 50]);

      // First ingest: a fresh row — fires showShelfReceived as expected.
      final first = await ShelfService.instance.ingestAndSchedule(
        cachedPaths: [f1.path],
        mimeTypes: const [null],
        originalNames: const ['orig.bin'],
      );
      expect(first.length, 1);
      methodCalls.clear();

      // Second ingest of identical bytes → R8 dedup → empty result.
      // The hanging "Processing…" notification posted by Kotlin
      // would normally never clear; showShelfDuplicate replaces it in
      // place using the same notification id.
      final second = await ShelfService.instance.ingestAndSchedule(
        cachedPaths: [f2.path],
        mimeTypes: const [null],
        originalNames: const ['redump.bin'],
      );
      expect(second, isEmpty);

      final methods = methodCalls.map((c) => c.method).toList();
      expect(methods, contains('showShelfDuplicate'),
          reason: 'duplicate batch must update the hanging notification');
      expect(methods, isNot(contains('showShelfComplete')),
          reason: 'no items were uploaded — Complete must not fire');
      expect(methods, isNot(contains('showShelfReceived')),
          reason: 'we already had the Received from the share Activity');

      final dupCall =
          methodCalls.firstWhere((c) => c.method == 'showShelfDuplicate');
      expect(dupCall.arguments['count'], 1);
      expect(dupCall.arguments['title'], 'Already in Shelf');
    });

    test('first-ever ingest fires showShelfReceived, not Duplicate',
        () async {
      final f = await writeBytes('brand-new.bin', [99, 100, 101, 102]);
      methodCalls.clear();

      final created = await ShelfService.instance.ingestAndSchedule(
        cachedPaths: [f.path],
        mimeTypes: const [null],
        originalNames: const ['brand-new.bin'],
      );
      expect(created.length, 1);

      final methods = methodCalls.map((c) => c.method).toList();
      expect(methods, contains('showShelfReceived'));
      expect(methods, isNot(contains('showShelfDuplicate')));
    });

    test(
        'partial-duplicate batch (some new, some dup) keeps '
        'Received behaviour for the new ones — no Duplicate fired',
        () async {
      // Item A already in storage.
      final a = await writeBytes('a-prior.bin', [0xA0, 0xA1, 0xA2]);
      await ShelfService.instance.ingestAndSchedule(
        cachedPaths: [a.path],
        mimeTypes: const [null],
        originalNames: const ['a-prior.bin'],
      );
      methodCalls.clear();

      // Now ingest a batch with one dup (same bytes as A) + one new (B).
      final aDup = await writeBytes('a-redump.bin', [0xA0, 0xA1, 0xA2]);
      final b = await writeBytes('b-new.bin', [0xB0, 0xB1, 0xB2, 0xB3]);

      final created = await ShelfService.instance.ingestAndSchedule(
        cachedPaths: [aDup.path, b.path],
        mimeTypes: const [null, null],
        originalNames: const ['a-redump.bin', 'b-new.bin'],
      );
      expect(created.length, 1, reason: 'B is new, A is duped');

      final methods = methodCalls.map((c) => c.method).toList();
      expect(methods, contains('showShelfReceived'),
          reason: 'the new item drives Received');
      expect(methods, isNot(contains('showShelfDuplicate')),
          reason: 'mixed batches surface via Complete for the new ones');
    });
  });

  group('ingestStagedPayload — classification routing', () {
    setUp(() {
      ShelfService.instance.encryptionKeyProvider =
          () async => Uint8List.fromList(List<int>.filled(32, 0x05));
    });

    test('image MIME → ShelfCategory.image', () async {
      final f = await writeBytes('IMG_1234.jpg', List<int>.filled(16, 0));
      final created = await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['image/jpeg'],
        originalNames: const ['IMG_1234.jpg'],
      );
      expect(created.first.category, ShelfCategory.image);
    });

    test('image MIME with screenshot in filename → screenshot', () async {
      final f = await writeBytes('Screenshot_x.png', List<int>.filled(16, 0));
      final created = await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['image/png'],
        originalNames: const ['Screenshot_x.png'],
      );
      expect(created.first.category, ShelfCategory.screenshot);
    });

    test('text/plain payload that is a URL → link', () async {
      final f = await writeBytes('share.txt', 'https://example.com'.codeUnits);
      final created = await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['text/plain'],
        originalNames: const ['share.txt'],
        textPayload: 'https://example.com',
      );
      expect(created.first.category, ShelfCategory.link);
      expect(created.first.textPayload, 'https://example.com');
    });

    test('plain prose text/plain payload → note', () async {
      final f = await writeBytes('share.txt', 'buy milk'.codeUnits);
      final created = await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['text/plain'],
        originalNames: const ['share.txt'],
        textPayload: 'buy milk',
      );
      expect(created.first.category, ShelfCategory.note);
    });

    test('PDF → document', () async {
      final f = await writeBytes('report.pdf', List<int>.filled(16, 0));
      final created = await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const ['application/pdf'],
        originalNames: const ['report.pdf'],
      );
      expect(created.first.category, ShelfCategory.document);
    });
  });

  group('ingestStagedPayload — robustness', () {
    setUp(() {
      ShelfService.instance.encryptionKeyProvider =
          () async => Uint8List.fromList(List<int>.filled(32, 0x77));
    });

    test('missing source file is skipped, not errored', () async {
      final created = await ShelfService.instance.ingestStagedPayload(
        cachedPaths: ['${tempDir.path}/does-not-exist.bin'],
        mimeTypes: const [null],
        originalNames: const ['ghost.bin'],
      );
      expect(created, isEmpty);
      expect(ShelfStorageService.instance.getAll(), isEmpty);
    });

    test('mixed missing + present: only present ones land', () async {
      final f = await writeBytes('real.bin', [9, 9, 9]);
      final created = await ShelfService.instance.ingestStagedPayload(
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
      final created = await ShelfService.instance.ingestStagedPayload(
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
      ShelfService.instance.encryptionKeyProvider = () async => null;
      final f = await writeBytes('a.bin', [1]);
      await ShelfService.instance.ingestStagedPayload(
        cachedPaths: [f.path],
        mimeTypes: const [null],
        originalNames: const ['a.bin'],
      );
      expect(ShelfStorageService.instance.getPendingAuthItems().length, 1);

      final retried = await ShelfService.instance.retryPending();
      expect(retried, 0);
      expect(ShelfStorageService.instance.getPendingAuthItems().length, 1);
    });

    // Note: the "with key → flips rows" path is verified at the
    // device-level smoke test in Session 5. Exercising it here would
    // need a SyncService / FulaApiService stub (retryPending fires
    // uploadOne via `unawaited`); that wiring is out of scope for
    // Session 2's unit test surface.
  });
}
