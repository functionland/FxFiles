// Session 5 — `DumpService.retryPending` behavior tests.
//
// Verifies the user-visible contract of the pendingAuth → queued
// handoff that fires when `AuthService` finishes restoring a session
// (R10 in the Dump plan):
//   - returns the number of items it flipped
//   - flips every `pendingAuth` row OUT of `pendingAuth` (i.e. the
//     post-state is either queued or, if the fire-and-forget upload
//     spawn already failed against the un-initialized test
//     FulaApiService, `failed` — either way the row no longer needs
//     re-attempt by a future `retryPending`)
//   - is idempotent: a second invocation finds 0 candidates and
//     returns 0
//   - is a no-op when the encryption key is unavailable
//   - is a no-op when there are no pendingAuth items at all
//
// Heavy collaborators (`SyncService`, `FulaApiService`, the real
// `AuthService`) are bypassed via `encryptionKeyProvider` /
// `initForTesting` seams introduced in Session 2; only the storage
// layer + a tmp Hive box are real.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/core/services/dump_notification_service.dart';
import 'package:fula_files/core/services/dump_service.dart';
import 'package:fula_files/core/services/dump_storage_service.dart';

DumpItem _pendingItem({required String id}) {
  return DumpItem(
    id: id,
    receivedAt: DateTime.utc(2026, 5, 21),
    originalName: '$id.bin',
    sizeBytes: 16,
    localCachePath: '/tmp/$id.bin',
    category: DumpCategory.other,
    uploadStatus: DumpUploadStatus.pendingAuth,
    contentSha: 'sha-$id',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dump_retry_test_');
    Hive.init(tempDir.path);

    // Silence the notification MethodChannel — uploadOne fires
    // showReceived / showFailed off the back of the queue, and an
    // unhandled MethodChannel call would otherwise warn.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(DumpNotificationService.androidChannelName),
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
      MethodChannel(DumpNotificationService.androidChannelName),
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

  test('returns 0 + no flips when there are no pendingAuth items',
      () async {
    DumpService.instance.encryptionKeyProvider =
        () async => Uint8List.fromList(List<int>.filled(32, 0xCC));
    expect(await DumpService.instance.retryPending(), 0);
  });

  test('returns 0 + no flips when encryption key is unavailable',
      () async {
    await DumpStorageService.instance.add(_pendingItem(id: 'p1'));
    await DumpStorageService.instance.add(_pendingItem(id: 'p2'));
    DumpService.instance.encryptionKeyProvider = () async => null;

    expect(await DumpService.instance.retryPending(), 0);
    expect(
      DumpStorageService.instance.getPendingAuthItems().length,
      2,
      reason: 'No key → items stay pendingAuth',
    );
  });

  test('returns the count and flips every pendingAuth row to non-pending',
      () async {
    await DumpStorageService.instance.add(_pendingItem(id: 'a'));
    await DumpStorageService.instance.add(_pendingItem(id: 'b'));
    await DumpStorageService.instance.add(_pendingItem(id: 'c'));
    DumpService.instance.encryptionKeyProvider =
        () async => Uint8List.fromList(List<int>.filled(32, 0x42));

    final flipped = await DumpService.instance.retryPending();
    expect(flipped, 3);

    expect(
      DumpStorageService.instance.getPendingAuthItems(),
      isEmpty,
      reason: 'Every pendingAuth row should have moved on',
    );
    // The synchronous return-point of retryPending leaves the rows in
    // `queued`; the fire-and-forget uploadOne spawned after may flip
    // some of them to `uploading`/`failed` in the background — we
    // only assert the user-visible "no longer waiting on a sign-in"
    // post-condition.
    for (final id in const ['a', 'b', 'c']) {
      final after = DumpStorageService.instance.getById(id);
      expect(after, isNotNull);
      expect(after!.uploadStatus, isNot(DumpUploadStatus.pendingAuth));
    }
  });

  test('is idempotent — a second call returns 0', () async {
    await DumpStorageService.instance.add(_pendingItem(id: 'x'));
    DumpService.instance.encryptionKeyProvider =
        () async => Uint8List.fromList(List<int>.filled(32, 0x99));

    expect(await DumpService.instance.retryPending(), 1);
    expect(await DumpService.instance.retryPending(), 0);
  });

  test('does NOT touch items already in queued / uploading / uploaded',
      () async {
    final queued = DumpItem(
      id: 'q',
      receivedAt: DateTime.utc(2026, 5, 21),
      originalName: 'q.bin',
      sizeBytes: 4,
      localCachePath: '/tmp/q.bin',
      category: DumpCategory.file,
      uploadStatus: DumpUploadStatus.queued,
      contentSha: 'sha-q',
    );
    final uploading = queued.copyWith(
      id: 'u', uploadStatus: DumpUploadStatus.uploading,
    );
    final uploaded = queued.copyWith(
      id: 'd', uploadStatus: DumpUploadStatus.uploaded,
    );
    await DumpStorageService.instance.add(queued);
    await DumpStorageService.instance.add(uploading);
    await DumpStorageService.instance.add(uploaded);
    await DumpStorageService.instance.add(_pendingItem(id: 'p'));

    DumpService.instance.encryptionKeyProvider =
        () async => Uint8List.fromList(List<int>.filled(32, 0xAA));

    final flipped = await DumpService.instance.retryPending();
    expect(flipped, 1, reason: 'Only the pendingAuth row should be flipped');

    // The pre-existing queued / uploading / uploaded rows are
    // unchanged on the user-observable dimension.
    expect(
      DumpStorageService.instance.getById('u')!.uploadStatus,
      DumpUploadStatus.uploading,
    );
    expect(
      DumpStorageService.instance.getById('d')!.uploadStatus,
      DumpUploadStatus.uploaded,
    );
  });
}
