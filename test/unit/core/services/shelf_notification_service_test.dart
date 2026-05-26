// Verifies that ShelfNotificationService translates each high-level
// call into the right Android MethodChannel invocation. The channel
// is intercepted via TestDefaultBinaryMessengerBinding so no real
// native code is involved.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_notification_service.dart';

class _Call {
  final String method;
  final Map<String, dynamic> args;
  _Call(this.method, this.args);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <_Call>[];

  setUp(() {
    calls.clear();
    ShelfNotificationService.debugForceAndroid = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(ShelfNotificationService.channelName),
      (call) async {
        calls.add(_Call(
          call.method,
          (call.arguments as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{},
        ));
        return true;
      },
    );
  });

  tearDown(() {
    ShelfNotificationService.debugForceAndroid = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(ShelfNotificationService.channelName),
      null,
    );
  });

  ShelfItem makeItem({
    String id = 'item-1',
    String originalName = 'Photo.jpg',
    String? autoTitle,
    ShelfUploadStatus uploadStatus = ShelfUploadStatus.uploaded,
  }) =>
      ShelfItem(
        id: id,
        receivedAt: DateTime.utc(2026, 5, 21, 12, 0),
        originalName: originalName,
        sizeBytes: 1234,
        localCachePath: '/tmp/$id',
        category: ShelfCategory.image,
        uploadStatus: uploadStatus,
        contentSha: 'sha-$id',
        autoTitle: autoTitle,
      );

  test('showReceived(count: 1) invokes showShelfReceived with singular body',
      () async {
    await ShelfNotificationService.instance.showReceived(count: 1);
    expect(calls.length, 1);
    expect(calls.first.method, 'showShelfReceived');
    expect(calls.first.args['title'], 'Shelf');
    expect(calls.first.args['body'], 'Processing 1 item…');
    expect(calls.first.args['count'], 1);
  });

  test('showReceived(count: 5) uses the plural body', () async {
    await ShelfNotificationService.instance.showReceived(count: 5);
    expect(calls.first.args['body'], 'Processing 5 items…');
    expect(calls.first.args['count'], 5);
  });

  test(
      'showComplete with one item builds title="Shelfed" + body from autoTitle',
      () async {
    await ShelfNotificationService.instance.showComplete(
      items: [makeItem(autoTitle: 'Sunset photo')],
    );
    expect(calls.first.method, 'showShelfComplete');
    expect(calls.first.args['title'], 'Saved to Shelf');
    expect(calls.first.args['body'], 'Sunset photo');
    expect(calls.first.args['count'], 1);
    expect(calls.first.args['deepLink'], 'fxfiles://shelf');
    expect(calls.first.args['hasErrors'], false);
  });

  test('showComplete falls back to originalName when autoTitle is null',
      () async {
    await ShelfNotificationService.instance.showComplete(
      items: [makeItem(originalName: 'IMG_4242.jpg', autoTitle: null)],
    );
    expect(calls.first.args['body'], 'IMG_4242.jpg');
  });

  test('showComplete with multiple items batches the body', () async {
    await ShelfNotificationService.instance.showComplete(
      items: [makeItem(id: 'a'), makeItem(id: 'b'), makeItem(id: 'c')],
    );
    expect(calls.first.args['body'], '3 items saved to Shelf');
    expect(calls.first.args['count'], 3);
  });

  test('showComplete with hasErrors swaps the title', () async {
    await ShelfNotificationService.instance.showComplete(
      items: [makeItem()],
      hasErrors: true,
    );
    expect(calls.first.args['title'], 'Some Shelf uploads failed');
    expect(calls.first.args['hasErrors'], true);
  });

  test('showComplete with empty list is a no-op (no channel call)', () async {
    await ShelfNotificationService.instance.showComplete(items: const []);
    expect(calls, isEmpty);
  });

  test('showPendingAuth uses singular/plural copy', () async {
    await ShelfNotificationService.instance.showPendingAuth(count: 1);
    expect(calls.last.method, 'showShelfPendingAuth');
    expect(calls.last.args['body'], 'Sign in to upload 1 saved item');

    await ShelfNotificationService.instance.showPendingAuth(count: 4);
    expect(calls.last.args['body'], 'Sign in to upload 4 saved items');
  });

  test('showFailed uses item.errorMessage if present', () async {
    await ShelfNotificationService.instance.showFailed(
      item: makeItem(originalName: 'big.mp4')
        ..errorMessage = 'Disk full',
    );
    expect(calls.first.method, 'showShelfFailed');
    expect(calls.first.args['body'], 'Disk full');
  });

  test('showFailed falls back to a generic body when errorMessage is null',
      () async {
    await ShelfNotificationService.instance.showFailed(
      item: makeItem(originalName: 'big.mp4', autoTitle: null),
    );
    expect(calls.first.args['body'], contains('big.mp4'));
  });

  test('hide invokes hideShelfNotification', () async {
    await ShelfNotificationService.instance.hide();
    expect(calls.first.method, 'hideShelfNotification');
  });

  group('iOS branch', () {
    final iosCalls = <_Call>[];

    setUp(() {
      iosCalls.clear();
      // Activate the iOS branch; deactivate Android so methods don't
      // double-fire across both channels.
      ShelfNotificationService.debugForceAndroid = false;
      ShelfNotificationService.debugForceIos = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        MethodChannel(ShelfNotificationService.iosChannelName),
        (call) async {
          iosCalls.add(_Call(
            call.method,
            (call.arguments as Map?)?.cast<String, dynamic>() ??
                const <String, dynamic>{},
          ));
          // requestAuthorization returns granted=true in tests.
          if (call.method == 'requestAuthorization') return true;
          return true;
        },
      );
    });

    tearDown(() {
      ShelfNotificationService.debugForceAndroid = null;
      ShelfNotificationService.debugForceIos = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        MethodChannel(ShelfNotificationService.iosChannelName),
        null,
      );
    });

    ShelfItem makeItem({String id = 'i', String originalName = 'photo.jpg'}) =>
        ShelfItem(
          id: id,
          receivedAt: DateTime.utc(2026, 5, 21, 12, 0),
          originalName: originalName,
          sizeBytes: 1234,
          localCachePath: '/tmp/$id',
          category: ShelfCategory.image,
          uploadStatus: ShelfUploadStatus.uploaded,
          contentSha: 'sha-$id',
        );

    test('showReceived is a no-op on iOS (extension already posted queued)',
        () async {
      await ShelfNotificationService.instance.showReceived(count: 3);
      expect(iosCalls, isEmpty);
    });

    test('showComplete posts dump.uploaded AND dismisses queued', () async {
      await ShelfNotificationService.instance.showComplete(
        items: [makeItem(originalName: 'first.jpg')],
      );
      expect(iosCalls.length, 2);
      expect(iosCalls[0].method, 'showShelfComplete');
      expect(iosCalls[0].args['title'], 'Saved to Shelf');
      expect(iosCalls[0].args['body'], 'first.jpg');
      expect(iosCalls[1].method, 'dismissQueued');
    });

    test('showPendingAuth uses iOS channel', () async {
      await ShelfNotificationService.instance.showPendingAuth(count: 2);
      expect(iosCalls.single.method, 'showShelfPendingAuth');
      expect(iosCalls.single.args['count'], 2);
    });

    test('showFailed uses iOS channel', () async {
      await ShelfNotificationService.instance.showFailed(item: makeItem());
      expect(iosCalls.single.method, 'showShelfFailed');
    });

    test('hide uses iOS channel', () async {
      await ShelfNotificationService.instance.hide();
      expect(iosCalls.single.method, 'hideShelfNotification');
    });

    test('requestAuthorization returns granted=true', () async {
      final granted =
          await ShelfNotificationService.instance.requestAuthorization();
      expect(granted, isTrue);
      expect(iosCalls.single.method, 'requestAuthorization');
    });

    test('requestAuthorization handles platform exception → false',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        MethodChannel(ShelfNotificationService.iosChannelName),
        (_) async => throw PlatformException(code: 'DENIED'),
      );
      final granted =
          await ShelfNotificationService.instance.requestAuthorization();
      expect(granted, isFalse);
    });

    test('empty items list on showComplete is a no-op', () async {
      await ShelfNotificationService.instance.showComplete(items: const []);
      expect(iosCalls, isEmpty);
    });
  });
}
