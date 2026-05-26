// Unit tests for `ShelfItem` — `copyWith` semantics and the
// hand-written Hive TypeAdapters (`dump_item.g.dart`).
//
// The `.g.dart` is committed source (not codegen-generated at build
// time) so these tests catch silent regressions in the adapter
// byte layout, default-value handling, and enum mapping.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:fula_files/core/models/shelf_item.dart';

ShelfItem _sampleItem({
  String id = 'item-1',
  DateTime? receivedAt,
  String originalName = 'sample.jpg',
  String? mimeType = 'image/jpeg',
  int sizeBytes = 12345,
  String localCachePath = '/tmp/dump_pending/item-1-sample.jpg',
  String? remoteKey,
  ShelfCategory category = ShelfCategory.image,
  ShelfUploadStatus uploadStatus = ShelfUploadStatus.queued,
  String? sourceAppPackage = 'com.example.app',
  String? textPayload,
  List<String> mlLabels = const <String>[],
  String contentSha = 'sha-deadbeef',
  String? errorMessage,
  String? autoTitle,
  String? autoDescription,
  String? thumbnailPath,
  ShelfEnrichmentStatus enrichmentStatus = ShelfEnrichmentStatus.pending,
}) {
  return ShelfItem(
    id: id,
    receivedAt: receivedAt ?? DateTime.utc(2026, 5, 21, 12, 30, 0),
    originalName: originalName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    localCachePath: localCachePath,
    remoteKey: remoteKey,
    category: category,
    uploadStatus: uploadStatus,
    sourceAppPackage: sourceAppPackage,
    textPayload: textPayload,
    mlLabels: mlLabels,
    contentSha: contentSha,
    errorMessage: errorMessage,
    autoTitle: autoTitle,
    autoDescription: autoDescription,
    thumbnailPath: thumbnailPath,
    enrichmentStatus: enrichmentStatus,
  );
}

void main() {
  group('ShelfItem.copyWith', () {
    test('returns a new instance with the changed field updated', () {
      final original = _sampleItem();
      final updated = original.copyWith(uploadStatus: ShelfUploadStatus.uploaded);

      expect(updated.uploadStatus, ShelfUploadStatus.uploaded);
      expect(updated.id, original.id);
      expect(updated.originalName, original.originalName);
    });

    test('preserves every unchanged field when only one is updated', () {
      final original = _sampleItem(
        autoTitle: 'A title',
        autoDescription: 'A description',
        mlLabels: const ['dog', 'park'],
      );
      final updated = original.copyWith(remoteKey: '2026/05/item-1.bin');

      expect(updated.remoteKey, '2026/05/item-1.bin');
      expect(updated.autoTitle, 'A title');
      expect(updated.autoDescription, 'A description');
      expect(updated.mlLabels, const ['dog', 'park']);
      expect(updated.uploadStatus, original.uploadStatus);
      expect(updated.category, original.category);
      expect(updated.contentSha, original.contentSha);
    });

    test('does not mutate the original instance', () {
      final original = _sampleItem(uploadStatus: ShelfUploadStatus.queued);
      final updated = original.copyWith(uploadStatus: ShelfUploadStatus.failed);

      expect(original.uploadStatus, ShelfUploadStatus.queued);
      expect(updated.uploadStatus, ShelfUploadStatus.failed);
    });
  });

  group('ShelfItem defaults', () {
    test('uploadStatus defaults to queued', () {
      final item = ShelfItem(
        id: 'i',
        receivedAt: DateTime.utc(2026, 5, 21),
        originalName: 'n',
        sizeBytes: 1,
        localCachePath: '/tmp/n',
        category: ShelfCategory.other,
        contentSha: 'sha',
      );
      expect(item.uploadStatus, ShelfUploadStatus.queued);
    });

    test('enrichmentStatus defaults to pending', () {
      final item = ShelfItem(
        id: 'i',
        receivedAt: DateTime.utc(2026, 5, 21),
        originalName: 'n',
        sizeBytes: 1,
        localCachePath: '/tmp/n',
        category: ShelfCategory.other,
        contentSha: 'sha',
      );
      expect(item.enrichmentStatus, ShelfEnrichmentStatus.pending);
    });

    test('mlLabels defaults to empty list', () {
      final item = ShelfItem(
        id: 'i',
        receivedAt: DateTime.utc(2026, 5, 21),
        originalName: 'n',
        sizeBytes: 1,
        localCachePath: '/tmp/n',
        category: ShelfCategory.other,
        contentSha: 'sha',
      );
      expect(item.mlLabels, isEmpty);
    });
  });

  group('ShelfItem boolean status getters', () {
    test('isUploaded / isQueued / isPendingAuth / hasFailed', () {
      expect(
        _sampleItem(uploadStatus: ShelfUploadStatus.uploaded).isUploaded,
        isTrue,
      );
      expect(
        _sampleItem(uploadStatus: ShelfUploadStatus.queued).isQueued,
        isTrue,
      );
      expect(
        _sampleItem(uploadStatus: ShelfUploadStatus.pendingAuth).isPendingAuth,
        isTrue,
      );
      expect(
        _sampleItem(uploadStatus: ShelfUploadStatus.failed).hasFailed,
        isTrue,
      );
      expect(
        _sampleItem(uploadStatus: ShelfUploadStatus.uploading).isUploading,
        isTrue,
      );
    });
  });

  group('Hive TypeAdapter round-trip', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dump_item_test_');
      Hive.init(tempDir.path);
      if (!Hive.isAdapterRegistered(60)) {
        Hive.registerAdapter(ShelfCategoryAdapter());
      }
      if (!Hive.isAdapterRegistered(61)) {
        Hive.registerAdapter(ShelfUploadStatusAdapter());
      }
      if (!Hive.isAdapterRegistered(62)) {
        Hive.registerAdapter(ShelfItemAdapter());
      }
      if (!Hive.isAdapterRegistered(63)) {
        Hive.registerAdapter(ShelfEnrichmentStatusAdapter());
      }
    });

    tearDown(() async {
      await Hive.deleteFromDisk();
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {
        // Windows sometimes holds the dir briefly; harmless.
      }
    });

    test('every field survives put/get with non-default values', () async {
      final box = await Hive.openBox<ShelfItem>('roundtrip_test');
      final original = _sampleItem(
        id: 'roundtrip-1',
        receivedAt: DateTime.utc(2026, 5, 21, 14, 0, 0),
        originalName: 'Screenshot_2026-05-21.png',
        mimeType: 'image/png',
        sizeBytes: 987654,
        localCachePath: '/data/dump_pending/roundtrip-1-shot.png',
        remoteKey: '2026/05/roundtrip-1-shot.png',
        category: ShelfCategory.screenshot,
        uploadStatus: ShelfUploadStatus.uploaded,
        sourceAppPackage: 'com.android.gallery',
        textPayload: null,
        mlLabels: const ['document', 'text'],
        contentSha: 'sha-roundtrip',
        errorMessage: null,
        autoTitle: 'Screenshot of receipt',
        autoDescription: 'document, text',
        thumbnailPath: '/data/dump_thumbs/roundtrip-1.jpg',
        enrichmentStatus: ShelfEnrichmentStatus.done,
      );

      await box.put(original.id, original);
      final read = box.get(original.id)!;

      expect(read.id, original.id);
      expect(read.receivedAt, original.receivedAt);
      expect(read.originalName, original.originalName);
      expect(read.mimeType, original.mimeType);
      expect(read.sizeBytes, original.sizeBytes);
      expect(read.localCachePath, original.localCachePath);
      expect(read.remoteKey, original.remoteKey);
      expect(read.category, original.category);
      expect(read.uploadStatus, original.uploadStatus);
      expect(read.sourceAppPackage, original.sourceAppPackage);
      expect(read.textPayload, original.textPayload);
      expect(read.mlLabels, original.mlLabels);
      expect(read.contentSha, original.contentSha);
      expect(read.errorMessage, original.errorMessage);
      expect(read.autoTitle, original.autoTitle);
      expect(read.autoDescription, original.autoDescription);
      expect(read.thumbnailPath, original.thumbnailPath);
      expect(read.enrichmentStatus, original.enrichmentStatus);

      await box.close();
    });

    test('every ShelfCategory enum value survives round-trip', () async {
      final box = await Hive.openBox<ShelfItem>('roundtrip_cats');
      for (final cat in ShelfCategory.values) {
        final item = _sampleItem(id: 'cat-${cat.name}', category: cat);
        await box.put(item.id, item);
        expect(box.get(item.id)!.category, cat, reason: cat.name);
      }
      await box.close();
    });

    test('every ShelfUploadStatus enum value survives round-trip', () async {
      final box = await Hive.openBox<ShelfItem>('roundtrip_upload');
      for (final s in ShelfUploadStatus.values) {
        final item = _sampleItem(id: 'up-${s.name}', uploadStatus: s);
        await box.put(item.id, item);
        expect(box.get(item.id)!.uploadStatus, s, reason: s.name);
      }
      await box.close();
    });

    test('every ShelfEnrichmentStatus enum value survives round-trip', () async {
      final box = await Hive.openBox<ShelfItem>('roundtrip_enrich');
      for (final s in ShelfEnrichmentStatus.values) {
        final item = _sampleItem(id: 'enr-${s.name}', enrichmentStatus: s);
        await box.put(item.id, item);
        expect(box.get(item.id)!.enrichmentStatus, s, reason: s.name);
      }
      await box.close();
    });
  });
}
