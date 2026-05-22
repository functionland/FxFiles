// Verifies that DumpNotificationService translates each high-level
// call into the right Android MethodChannel invocation. The channel
// is intercepted via TestDefaultBinaryMessengerBinding so no real
// native code is involved.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/core/services/dump_notification_service.dart';

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
    DumpNotificationService.debugForceAndroid = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(DumpNotificationService.channelName),
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
    DumpNotificationService.debugForceAndroid = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel(DumpNotificationService.channelName),
      null,
    );
  });

  DumpItem makeItem({
    String id = 'item-1',
    String originalName = 'Photo.jpg',
    String? autoTitle,
    DumpUploadStatus uploadStatus = DumpUploadStatus.uploaded,
  }) =>
      DumpItem(
        id: id,
        receivedAt: DateTime.utc(2026, 5, 21, 12, 0),
        originalName: originalName,
        sizeBytes: 1234,
        localCachePath: '/tmp/$id',
        category: DumpCategory.image,
        uploadStatus: uploadStatus,
        contentSha: 'sha-$id',
        autoTitle: autoTitle,
      );

  test('showReceived(count: 1) invokes showDumpReceived with singular body',
      () async {
    await DumpNotificationService.instance.showReceived(count: 1);
    expect(calls.length, 1);
    expect(calls.first.method, 'showDumpReceived');
    expect(calls.first.args['title'], 'FxFiles Dump');
    expect(calls.first.args['body'], 'Processing 1 dump…');
    expect(calls.first.args['count'], 1);
  });

  test('showReceived(count: 5) uses the plural body', () async {
    await DumpNotificationService.instance.showReceived(count: 5);
    expect(calls.first.args['body'], 'Processing 5 dumps…');
    expect(calls.first.args['count'], 5);
  });

  test(
      'showComplete with one item builds title="Dumped" + body from autoTitle',
      () async {
    await DumpNotificationService.instance.showComplete(
      items: [makeItem(autoTitle: 'Sunset photo')],
    );
    expect(calls.first.method, 'showDumpComplete');
    expect(calls.first.args['title'], 'Dumped');
    expect(calls.first.args['body'], 'Sunset photo');
    expect(calls.first.args['count'], 1);
    expect(calls.first.args['deepLink'], 'fxfiles://dump');
    expect(calls.first.args['hasErrors'], false);
  });

  test('showComplete falls back to originalName when autoTitle is null',
      () async {
    await DumpNotificationService.instance.showComplete(
      items: [makeItem(originalName: 'IMG_4242.jpg', autoTitle: null)],
    );
    expect(calls.first.args['body'], 'IMG_4242.jpg');
  });

  test('showComplete with multiple items batches the body', () async {
    await DumpNotificationService.instance.showComplete(
      items: [makeItem(id: 'a'), makeItem(id: 'b'), makeItem(id: 'c')],
    );
    expect(calls.first.args['body'], '3 items dumped');
    expect(calls.first.args['count'], 3);
  });

  test('showComplete with hasErrors swaps the title', () async {
    await DumpNotificationService.instance.showComplete(
      items: [makeItem()],
      hasErrors: true,
    );
    expect(calls.first.args['title'], 'Some dumps failed');
    expect(calls.first.args['hasErrors'], true);
  });

  test('showComplete with empty list is a no-op (no channel call)', () async {
    await DumpNotificationService.instance.showComplete(items: const []);
    expect(calls, isEmpty);
  });

  test('showPendingAuth uses singular/plural copy', () async {
    await DumpNotificationService.instance.showPendingAuth(count: 1);
    expect(calls.last.method, 'showDumpPendingAuth');
    expect(calls.last.args['body'], 'Sign in to upload 1 saved dump');

    await DumpNotificationService.instance.showPendingAuth(count: 4);
    expect(calls.last.args['body'], 'Sign in to upload 4 saved dumps');
  });

  test('showFailed uses item.errorMessage if present', () async {
    await DumpNotificationService.instance.showFailed(
      item: makeItem(originalName: 'big.mp4')
        ..errorMessage = 'Disk full',
    );
    expect(calls.first.method, 'showDumpFailed');
    expect(calls.first.args['body'], 'Disk full');
  });

  test('showFailed falls back to a generic body when errorMessage is null',
      () async {
    await DumpNotificationService.instance.showFailed(
      item: makeItem(originalName: 'big.mp4', autoTitle: null),
    );
    expect(calls.first.args['body'], contains('big.mp4'));
  });

  test('hide invokes hideDumpNotification', () async {
    await DumpNotificationService.instance.hide();
    expect(calls.first.method, 'hideDumpNotification');
  });

  group('iOS branch', () {
    final iosCalls = <_Call>[];

    setUp(() {
      iosCalls.clear();
      // Activate the iOS branch; deactivate Android so methods don't
      // double-fire across both channels.
      DumpNotificationService.debugForceAndroid = false;
      DumpNotificationService.debugForceIos = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        MethodChannel(DumpNotificationService.iosChannelName),
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
      DumpNotificationService.debugForceAndroid = null;
      DumpNotificationService.debugForceIos = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        MethodChannel(DumpNotificationService.iosChannelName),
        null,
      );
    });

    DumpItem makeItem({String id = 'i', String originalName = 'photo.jpg'}) =>
        DumpItem(
          id: id,
          receivedAt: DateTime.utc(2026, 5, 21, 12, 0),
          originalName: originalName,
          sizeBytes: 1234,
          localCachePath: '/tmp/$id',
          category: DumpCategory.image,
          uploadStatus: DumpUploadStatus.uploaded,
          contentSha: 'sha-$id',
        );

    test('showReceived is a no-op on iOS (extension already posted queued)',
        () async {
      await DumpNotificationService.instance.showReceived(count: 3);
      expect(iosCalls, isEmpty);
    });

    test('showComplete posts dump.uploaded AND dismisses queued', () async {
      await DumpNotificationService.instance.showComplete(
        items: [makeItem(originalName: 'first.jpg')],
      );
      expect(iosCalls.length, 2);
      expect(iosCalls[0].method, 'showDumpComplete');
      expect(iosCalls[0].args['title'], 'Dumped');
      expect(iosCalls[0].args['body'], 'first.jpg');
      expect(iosCalls[1].method, 'dismissQueued');
    });

    test('showPendingAuth uses iOS channel', () async {
      await DumpNotificationService.instance.showPendingAuth(count: 2);
      expect(iosCalls.single.method, 'showDumpPendingAuth');
      expect(iosCalls.single.args['count'], 2);
    });

    test('showFailed uses iOS channel', () async {
      await DumpNotificationService.instance.showFailed(item: makeItem());
      expect(iosCalls.single.method, 'showDumpFailed');
    });

    test('hide uses iOS channel', () async {
      await DumpNotificationService.instance.hide();
      expect(iosCalls.single.method, 'hideDumpNotification');
    });

    test('requestAuthorization returns granted=true', () async {
      final granted =
          await DumpNotificationService.instance.requestAuthorization();
      expect(granted, isTrue);
      expect(iosCalls.single.method, 'requestAuthorization');
    });

    test('requestAuthorization handles platform exception → false',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        MethodChannel(DumpNotificationService.iosChannelName),
        (_) async => throw PlatformException(code: 'DENIED'),
      );
      final granted =
          await DumpNotificationService.instance.requestAuthorization();
      expect(granted, isFalse);
    });

    test('empty items list on showComplete is a no-op', () async {
      await DumpNotificationService.instance.showComplete(items: const []);
      expect(iosCalls, isEmpty);
    });
  });
}
