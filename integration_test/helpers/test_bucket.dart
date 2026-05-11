// Bucket isolation for integration tests.
//
// All tests share ONE bucket on the real master: `__integration_test__`.
// Per-test isolation comes from a unique key prefix (timestamp +
// random). Why a shared bucket?
//
// - Bucket creation on master is expensive (~2-5 s each).
// - Buckets accumulate metadata in `BucketManager` even if "empty"
//   on the user's account; per-test buckets would leave debris
//   visible in the user's account forever.
// - The Phase 1.2 / walkable-v8 forest is per-bucket — re-using
//   a single bucket means we exercise the upgrade path (same forest
//   gets read + written across tests).
//
// Per-test teardown deletes the keys that test created. The bucket
// itself stays.

import 'package:fula_files/core/services/fula_api_service.dart';

import 'failure_logger.dart';

/// Stable bucket name used across all integration tests on the
/// real master. Not user-visible in normal operation.
const String integrationTestBucket = '__integration_test__';

/// Per-test prefix manager. Construct in `setUp`, call
/// [trackKey] after every upload, [cleanup] in `tearDown`.
class TestBucket {
  final String _runStamp;
  final List<String> _createdKeys = <String>[];
  final _logger = FailureLogger();

  TestBucket()
      : _runStamp = DateTime.now().millisecondsSinceEpoch.toString();

  /// Produce a unique key for [name] within this test run. Format:
  /// `test/<timestamp>/<name>`.
  String key(String name) => 'test/$_runStamp/$name';

  /// Bucket name to pass to all FulaApiService calls in this test.
  String get bucket => integrationTestBucket;

  /// Ensure the shared test bucket exists (creates if needed).
  Future<void> ensureBucketExists() async {
    final api = FulaApiService.instance;
    final exists = await api.bucketExists(integrationTestBucket);
    if (!exists) {
      _logger.step('test bucket "$integrationTestBucket" missing — creating');
      await api.createBucket(integrationTestBucket);
    } else {
      _logger.step('test bucket "$integrationTestBucket" exists');
    }
  }

  /// Mark [key] for cleanup at test end.
  void trackKey(String key) {
    _createdKeys.add(key);
    _logger.step('tracking key for cleanup: $key');
  }

  /// Delete every key tracked by this instance. Best-effort: a failure
  /// to clean up one key doesn't block the others.
  Future<void> cleanup() async {
    if (_createdKeys.isEmpty) return;
    _logger.step('cleanup: deleting ${_createdKeys.length} tracked keys');
    final api = FulaApiService.instance;
    for (final key in _createdKeys) {
      try {
        await api.deleteObject(integrationTestBucket, key);
      } catch (e) {
        _logger.step('cleanup: deleteObject($key) failed: $e (continuing)');
      }
    }
  }
}
