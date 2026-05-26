// Session 5 — `ShelfService.retryPending` behavior tests.
//
// Verifies the user-visible contract of the pendingAuth → queued
// handoff that fires when `AuthService` finishes restoring a session
// (R10 in the Shelf plan):
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

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_notification_service.dart';
import 'package:fula_files/core/services/shelf_service.dart';
import 'package:fula_files/core/services/shelf_storage_service.dart';

ShelfItem _pendingItem({required String id}) {
  return ShelfItem(
    id: id,
    receivedAt: DateTime.utc(2026, 5, 21),
    originalName: '$id.bin',
    sizeBytes: 16,
    localCachePath: '/tmp/$id.bin',
    category: ShelfCategory.other,
    uploadStatus: ShelfUploadStatus.pendingAuth,
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
      MethodChannel(ShelfNotificationService.androidChannelName),
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
      MethodChannel(ShelfNotificationService.androidChannelName),
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
    ShelfService.instance.encryptionKeyProvider =
        () async => Uint8List.fromList(List<int>.filled(32, 0xCC));
    expect(await ShelfService.instance.retryPending(), 0);
  });

  test('returns 0 + no flips when encryption key is unavailable',
      () async {
    await ShelfStorageService.instance.add(_pendingItem(id: 'p1'));
    await ShelfStorageService.instance.add(_pendingItem(id: 'p2'));
    ShelfService.instance.encryptionKeyProvider = () async => null;

    expect(await ShelfService.instance.retryPending(), 0);
    expect(
      ShelfStorageService.instance.getPendingAuthItems().length,
      2,
      reason: 'No key → items stay pendingAuth',
    );
  });

  test('returns the count and flips every pendingAuth row to non-pending',
      () async {
    await ShelfStorageService.instance.add(_pendingItem(id: 'a'));
    await ShelfStorageService.instance.add(_pendingItem(id: 'b'));
    await ShelfStorageService.instance.add(_pendingItem(id: 'c'));
    ShelfService.instance.encryptionKeyProvider =
        () async => Uint8List.fromList(List<int>.filled(32, 0x42));

    final flipped = await ShelfService.instance.retryPending();
    expect(flipped, 3);

    expect(
      ShelfStorageService.instance.getPendingAuthItems(),
      isEmpty,
      reason: 'Every pendingAuth row should have moved on',
    );
    // The synchronous return-point of retryPending leaves the rows in
    // `queued`; the fire-and-forget uploadOne spawned after may flip
    // some of them to `uploading`/`failed` in the background — we
    // only assert the user-visible "no longer waiting on a sign-in"
    // post-condition.
    for (final id in const ['a', 'b', 'c']) {
      final after = ShelfStorageService.instance.getById(id);
      expect(after, isNotNull);
      expect(after!.uploadStatus, isNot(ShelfUploadStatus.pendingAuth));
    }
  });

  test('is idempotent — a second call returns 0', () async {
    await ShelfStorageService.instance.add(_pendingItem(id: 'x'));
    ShelfService.instance.encryptionKeyProvider =
        () async => Uint8List.fromList(List<int>.filled(32, 0x99));

    expect(await ShelfService.instance.retryPending(), 1);
    expect(await ShelfService.instance.retryPending(), 0);
  });

  test('does NOT touch items already in queued / uploading / uploaded',
      () async {
    final queued = ShelfItem(
      id: 'q',
      receivedAt: DateTime.utc(2026, 5, 21),
      originalName: 'q.bin',
      sizeBytes: 4,
      localCachePath: '/tmp/q.bin',
      category: ShelfCategory.file,
      uploadStatus: ShelfUploadStatus.queued,
      contentSha: 'sha-q',
    );
    final uploading = queued.copyWith(
      id: 'u', uploadStatus: ShelfUploadStatus.uploading,
    );
    final uploaded = queued.copyWith(
      id: 'd', uploadStatus: ShelfUploadStatus.uploaded,
    );
    await ShelfStorageService.instance.add(queued);
    await ShelfStorageService.instance.add(uploading);
    await ShelfStorageService.instance.add(uploaded);
    await ShelfStorageService.instance.add(_pendingItem(id: 'p'));

    ShelfService.instance.encryptionKeyProvider =
        () async => Uint8List.fromList(List<int>.filled(32, 0xAA));

    final flipped = await ShelfService.instance.retryPending();
    expect(flipped, 1, reason: 'Only the pendingAuth row should be flipped');

    // The pre-existing queued / uploading / uploaded rows are
    // unchanged on the user-observable dimension.
    expect(
      ShelfStorageService.instance.getById('u')!.uploadStatus,
      ShelfUploadStatus.uploading,
    );
    expect(
      ShelfStorageService.instance.getById('d')!.uploadStatus,
      ShelfUploadStatus.uploaded,
    );
  });
}
