// Unit tests for CloudSyncMappingService hazard H1: a hard cloud-read error
// must NOT wipe the in-memory mapping cache. `ensureLoaded`/`relinkMappings`
// clear-then-load, so they clear ONLY after a successful download; the v8
// merge-read (`downloadObjectMerged`) RETHROWS hard (non-404) errors precisely
// so those callers keep their existing cache instead of replacing it with a
// partial (v8-only) set.
//
// Device-free: uses the service's `downloadMappingsOverride` seam — no live
// FulaApiService, no Hive, no platform channels.

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/cloud_sync_mapping_service.dart';

void main() {
  final svc = CloudSyncMappingService.instance;

  SyncMapping mapping(String id) => SyncMapping(
        localPath: '/local/$id',
        remoteKey: 'remote/$id',
        bucket: 'images',
        uploadedAt: DateTime.utc(2026, 1, 1),
      );

  setUp(svc.resetForTesting);
  tearDown(svc.resetForTesting);

  group('CloudSyncMappingService H1 — clear-only-after-success', () {
    test('ensureLoaded does NOT wipe the cache when the read hard-errors',
        () async {
      svc.seedMappingsForTest([mapping('a'), mapping('b')]);
      svc.downloadMappingsOverride =
          () async => throw Exception('hard gateway error');

      await svc.ensureLoaded();

      // A transient hard error must leave the existing mappings intact.
      expect(svc.cachedMappingsForTest.length, 2);
      expect(
        svc.cachedMappingsForTest.map((m) => m.identifier),
        containsAll(<String>['/local/a', '/local/b']),
      );
    });

    test('ensureLoaded replaces the cache on a successful (merged) read',
        () async {
      svc.seedMappingsForTest([mapping('old')]);
      svc.downloadMappingsOverride = () async => [mapping('new')];

      await svc.ensureLoaded();

      expect(svc.cachedMappingsForTest.length, 1);
      expect(svc.cachedMappingsForTest.single.identifier, '/local/new');
    });
  });
}
