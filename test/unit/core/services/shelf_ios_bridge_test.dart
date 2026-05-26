// Tests for ShelfIosBridge — verifies that descriptor maps coming from
// the AppDelegate's `drainAppGroupContainer` MethodChannel are
// correctly funneled into ShelfService.ingestAndSchedule, including
// the per-txn paths / mimes / originalNames / optional textPayload
// mapping.
//
// Heavy collaborators (FulaApiService / SyncService / AuthService)
// are stubbed via the ShelfService test seams introduced in Session
// 2; only the storage layer + Hive tmp box are real.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_ios_bridge.dart';
import 'package:fula_files/core/services/shelf_notification_service.dart';
import 'package:fula_files/core/services/shelf_service.dart';
import 'package:fula_files/core/services/shelf_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late List<MethodCall> calls;
  // Default mock response — overridable per-test.
  Object? mockResponse;

  Future<File> writeBytes(String name, List<int> bytes) async {
    final f = File('${tempDir.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dump_ios_bridge_test_');
    Hive.init(tempDir.path);

    calls = <MethodCall>[];
    mockResponse = null;
    ShelfIosBridge.debugForceIos = true;
    ShelfNotificationService.debugForceAndroid = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(ShelfIosBridge.channelName),
      (call) async {
        calls.add(call);
        return mockResponse;
      },
    );
    // Mute the notification channel — ShelfService.ingestAndSchedule
    // fires showReceived / showPendingAuth and those would try to
    // reach a non-existent platform handler.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(ShelfNotificationService.androidChannelName),
      (_) async => true,
    );

    await ShelfService.instance.resetForTesting();
    await ShelfStorageService.instance.resetForTesting();
    await ShelfService.instance.initForTesting();
    // Force the pendingAuth path so ingestAndSchedule doesn't try to
    // call SyncService.queueUpload / FulaApiService in the test
    // environment.
    ShelfService.instance.encryptionKeyProvider = () async => null;
  });

  tearDown(() async {
    ShelfIosBridge.debugForceIos = null;
    ShelfNotificationService.debugForceAndroid = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(ShelfIosBridge.channelName),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(ShelfNotificationService.androidChannelName),
      null,
    );
    await ShelfService.instance.resetForTesting();
    await ShelfStorageService.instance.resetForTesting();
    await Hive.deleteFromDisk();
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {
      // Windows occasionally holds the dir briefly; harmless.
    }
  });

  test('returns 0 when channel returns null', () async {
    mockResponse = null;
    final count = await ShelfIosBridge.instance.drainAppGroupContainer();
    expect(count, 0);
    expect(calls.length, 1);
    expect(calls.first.method, 'drainAppGroupContainer');
  });

  test('returns 0 when channel returns empty list', () async {
    mockResponse = <Object>[];
    final count = await ShelfIosBridge.instance.drainAppGroupContainer();
    expect(count, 0);
  });

  test('single descriptor with one file → ingest creates 1 ShelfItem',
      () async {
    final f = await writeBytes('photo.jpg', [0xFF, 0xD8, 0xFF, 0xE0]);
    mockResponse = <Object?>[
      <String, Object?>{
        'txnId': 'txn-1',
        'paths': <String>[f.path],
        'mimeTypes': <String?>['image/jpeg'],
        'originalNames': <String>['photo.jpg'],
        'sourceApp': 'ios-share',
      },
    ];

    final count = await ShelfIosBridge.instance.drainAppGroupContainer();
    expect(count, 1);
    final all = ShelfStorageService.instance.getAll();
    expect(all.length, 1);
    expect(all.first.originalName, 'photo.jpg');
    expect(all.first.mimeType, 'image/jpeg');
    expect(all.first.category, ShelfCategory.image);
    expect(all.first.sourceAppPackage, 'ios-share');
  });

  test('descriptor with textPayload preserves it', () async {
    final f = await writeBytes('note.txt', 'https://example.com'.codeUnits);
    mockResponse = <Object?>[
      <String, Object?>{
        'txnId': 'txn-2',
        'paths': <String>[f.path],
        'mimeTypes': <String?>['text/plain'],
        'originalNames': <String>['Shared link'],
        'textPayload': 'https://example.com',
        'sourceApp': 'ios-share',
      },
    ];

    final count = await ShelfIosBridge.instance.drainAppGroupContainer();
    expect(count, 1);
    final created = ShelfStorageService.instance.getAll().single;
    expect(created.textPayload, 'https://example.com');
    expect(created.category, ShelfCategory.link);
  });

  test('multi-file descriptor ingests each file', () async {
    final a = await writeBytes('a.jpg', [0xAA]);
    final b = await writeBytes('b.png', [0xBB]);
    mockResponse = <Object?>[
      <String, Object?>{
        'txnId': 'txn-3',
        'paths': <String>[a.path, b.path],
        'mimeTypes': <String?>['image/jpeg', 'image/png'],
        'originalNames': <String>['a.jpg', 'b.png'],
        'sourceApp': 'ios-share',
      },
    ];

    final count = await ShelfIosBridge.instance.drainAppGroupContainer();
    expect(count, 2);
    expect(ShelfStorageService.instance.getAll().length, 2);
  });

  test('multi-descriptor (separate txns) each ingest independently',
      () async {
    final a = await writeBytes('first.bin', [0x01]);
    final b = await writeBytes('second.bin', [0x02]);
    mockResponse = <Object?>[
      <String, Object?>{
        'txnId': 'txn-A',
        'paths': <String>[a.path],
        'mimeTypes': <String?>[null],
        'originalNames': <String>['first.bin'],
        'sourceApp': 'ios-share',
      },
      <String, Object?>{
        'txnId': 'txn-B',
        'paths': <String>[b.path],
        'mimeTypes': <String?>[null],
        'originalNames': <String>['second.bin'],
        'sourceApp': 'ios-share',
      },
    ];

    final count = await ShelfIosBridge.instance.drainAppGroupContainer();
    expect(count, 2);
    expect(ShelfStorageService.instance.getAll().length, 2);
  });

  test('descriptor with missing paths is skipped, not errored', () async {
    final present = await writeBytes('present.bin', [0x03]);
    mockResponse = <Object?>[
      <String, Object?>{
        'txnId': 'txn-empty',
        'paths': const <String>[],
        'mimeTypes': const <String?>[],
        'originalNames': const <String>[],
        'sourceApp': 'ios-share',
      },
      <String, Object?>{
        'txnId': 'txn-good',
        'paths': <String>[present.path],
        'mimeTypes': <String?>[null],
        'originalNames': <String>['present.bin'],
        'sourceApp': 'ios-share',
      },
    ];

    final count = await ShelfIosBridge.instance.drainAppGroupContainer();
    expect(count, 1);
    expect(ShelfStorageService.instance.getAll().single.originalName,
        'present.bin');
  });

  test('non-iOS host returns 0 without calling the channel', () async {
    ShelfIosBridge.debugForceIos = false;
    mockResponse = <Object?>[
      <String, Object?>{
        'txnId': 'txn-x',
        'paths': const <String>['/should/not/touch'],
        'mimeTypes': const <String?>[null],
        'originalNames': const <String>['x.bin'],
      },
    ];

    final count = await ShelfIosBridge.instance.drainAppGroupContainer();
    expect(count, 0);
    expect(calls, isEmpty);
  });

  test('channel error returns 0 (degraded — does not throw)', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(ShelfIosBridge.channelName),
      (_) async => throw PlatformException(code: 'BOOM'),
    );
    final count = await ShelfIosBridge.instance.drainAppGroupContainer();
    expect(count, 0);
  });
}
