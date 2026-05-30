import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fula_files/core/models/website_group_pointer.dart';

/// Covers the hand-written [WebsiteGroupPointerAdapter] + JSON round-trips —
/// bespoke serialization is exactly what breaks silently from a field-index
/// slip, so we exercise the real Hive read/write path (open → put → reopen →
/// get), not just the annotations.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('wgp_test');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(28)) {
      Hive.registerAdapter(WebsiteGroupPointerAdapter());
    }
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  WebsiteGroupPointer sample() => WebsiteGroupPointer(
        tagId: 'tag-1',
        ipnsName: 'k51qzi5uqu5dabc',
        sequence: 7,
        currentCid: 'bafycid',
        frontDoorUrl: 'https://fxfiles.top/w/k51qzi5uqu5dabc',
        ipnsGatewayUrl: 'https://k51qzi5uqu5dabc.ipns.dweb.link/',
        published: true,
        createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        updatedAt: DateTime.utc(2026, 1, 2, 3, 4, 6),
      );

  test('Hive adapter round-trips every field through a real box', () async {
    final box = await Hive.openBox<WebsiteGroupPointer>('wgp');
    await box.put('tag-1', sample());
    await box.close();

    final reopened = await Hive.openBox<WebsiteGroupPointer>('wgp');
    final got = reopened.get('tag-1')!;
    expect(got.tagId, 'tag-1');
    expect(got.ipnsName, 'k51qzi5uqu5dabc');
    expect(got.sequence, 7);
    expect(got.currentCid, 'bafycid');
    expect(got.frontDoorUrl, 'https://fxfiles.top/w/k51qzi5uqu5dabc');
    expect(got.ipnsGatewayUrl, 'https://k51qzi5uqu5dabc.ipns.dweb.link/');
    expect(got.published, isTrue);
    // Hive stores DateTime as an epoch instant (drops the isUtc flag), so
    // compare instants rather than the objects.
    expect(got.createdAt.millisecondsSinceEpoch,
        DateTime.utc(2026, 1, 2, 3, 4, 5).millisecondsSinceEpoch);
    expect(got.updatedAt.millisecondsSinceEpoch,
        DateTime.utc(2026, 1, 2, 3, 4, 6).millisecondsSinceEpoch);
  });

  test('Hive adapter handles null currentCid + defaults', () async {
    final box = await Hive.openBox<WebsiteGroupPointer>('wgp2');
    await box.put(
      'tag-2',
      WebsiteGroupPointer(
        tagId: 'tag-2',
        ipnsName: 'k51xyz',
        frontDoorUrl: 'f',
        ipnsGatewayUrl: 'g',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );
    await box.close();

    final got =
        (await Hive.openBox<WebsiteGroupPointer>('wgp2')).get('tag-2')!;
    expect(got.currentCid, isNull);
    expect(got.published, isFalse);
    expect(got.sequence, 0);
  });

  test('toJson / fromJson round-trips every field', () {
    final p = sample();
    final back = WebsiteGroupPointer.fromJson(p.toJson());
    expect(back.tagId, p.tagId);
    expect(back.ipnsName, p.ipnsName);
    expect(back.sequence, p.sequence);
    expect(back.currentCid, p.currentCid);
    expect(back.frontDoorUrl, p.frontDoorUrl);
    expect(back.ipnsGatewayUrl, p.ipnsGatewayUrl);
    expect(back.published, p.published);
    expect(back.createdAt.toUtc(), p.createdAt);
    expect(back.updatedAt.toUtc(), p.updatedAt);
  });

  test('fromJson tolerates a minimal/partial map', () {
    final back = WebsiteGroupPointer.fromJson({
      'tagId': 'x',
      'ipnsName': 'k51',
      'createdAt': '2026-05-30T00:00:00.000Z',
      'updatedAt': '2026-05-30T00:00:00.000Z',
    });
    expect(back.sequence, 0);
    expect(back.currentCid, isNull);
    expect(back.published, isFalse);
    expect(back.frontDoorUrl, '');
  });
}
