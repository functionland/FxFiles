import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/upload_queue_lock.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Test double for `path_provider` so `getApplicationDocumentsDirectory`
/// resolves to a temp dir during unit tests. Without this the lock's
/// `_lockFile()` would throw `MissingPluginException` and the lock
/// would degrade to no-lock mode (which is what the no-stub test
/// below exercises).
class _TempDirPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TempDirPathProvider(this.tempDir);
  final Directory tempDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => tempDir.path;

  @override
  Future<String?> getTemporaryPath() async => tempDir.path;

  @override
  Future<String?> getApplicationSupportPath() async => tempDir.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UploadQueueLock', () {
    test(
      'degrades to no-lock mode when path_provider is missing — tryAcquire '
      'returns true, isUnavailable is true, release is a no-op',
      () async {
        // No PathProviderPlatform stub installed → getApplicationDocumentsDirectory
        // throws MissingPluginException. The lock must NOT block uploads
        // in this configuration; production-side single-isolate behaviour
        // wins.
        final lock = UploadQueueLock();
        final acquired = await lock.tryAcquire();
        expect(acquired, isTrue,
            reason: 'unavailable lock should fall through to "acquired" '
                'so callers proceed in test/web/single-isolate environments');
        expect(lock.isUnavailable, isTrue);
        expect(lock.isHeld, isFalse);

        // Release is idempotent and never throws.
        await lock.release();
        await lock.release();

        // Subsequent tryAcquire still returns true (fall-through mode
        // is sticky for this instance).
        expect(await lock.tryAcquire(), isTrue);
      },
    );

    test(
      'acquires the lock when path_provider returns a real directory',
      () async {
        final dir = await Directory.systemTemp.createTemp('uql-test-');
        try {
          PathProviderPlatform.instance = _TempDirPathProvider(dir);

          final lock = UploadQueueLock();
          expect(await lock.tryAcquire(), isTrue);
          expect(lock.isHeld, isTrue);
          expect(lock.isUnavailable, isFalse);

          // Lock file exists on disk.
          expect(File(p.join(dir.path, 'sync_queue.lock')).existsSync(), isTrue);

          await lock.release();
          expect(lock.isHeld, isFalse);
        } finally {
          try {
            await dir.delete(recursive: true);
          } catch (_) {/* ignore */}
          // Leave the platform interface pointing at our mock — the
          // next test installs its own, and the no-stub test runs in
          // isolation (test file ordering doesn't guarantee teardown
          // restores anything useful).
        }
      },
    );

    test(
      're-acquiring while already held is a no-op (idempotent)',
      () async {
        final dir = await Directory.systemTemp.createTemp('uql-test-');
        try {
          PathProviderPlatform.instance = _TempDirPathProvider(dir);

          final lock = UploadQueueLock();
          expect(await lock.tryAcquire(), isTrue);
          // Calling again must not deadlock or throw.
          expect(await lock.tryAcquire(), isTrue);
          expect(lock.isHeld, isTrue);

          await lock.release();
        } finally {
          try {
            await dir.delete(recursive: true);
          } catch (_) {/* ignore */}
          // Leave the platform interface pointing at our mock — the
          // next test installs its own, and the no-stub test runs in
          // isolation (test file ordering doesn't guarantee teardown
          // restores anything useful).
        }
      },
    );

    test(
      'two lock instances on the same file: second blocks while first '
      'holds, succeeds after release',
      () async {
        final dir = await Directory.systemTemp.createTemp('uql-test-');
        try {
          PathProviderPlatform.instance = _TempDirPathProvider(dir);

          final lockA = UploadQueueLock();
          final lockB = UploadQueueLock();

          expect(await lockA.tryAcquire(), isTrue,
              reason: 'first acquirer wins');
          expect(lockA.isHeld, isTrue);

          // Second acquire should NOT block forever; acquireWithTimeout
          // polls, so we give it a short window — and confirm it fails
          // while A holds.
          final blockedResult = await lockB.acquireWithTimeout(
            const Duration(milliseconds: 600),
          );
          expect(blockedResult, isFalse,
              reason: 'B must not acquire while A holds');
          expect(lockB.isHeld, isFalse);

          // Release A → B can grab it.
          await lockA.release();
          expect(await lockB.tryAcquire(), isTrue);
          expect(lockB.isHeld, isTrue);

          await lockB.release();
        } finally {
          try {
            await dir.delete(recursive: true);
          } catch (_) {/* ignore */}
          // Leave the platform interface pointing at our mock — the
          // next test installs its own, and the no-stub test runs in
          // isolation (test file ordering doesn't guarantee teardown
          // restores anything useful).
        }
      },
      // File-locking semantics differ enough across platforms that this
      // is the spec-by-example. The mock above exercises a real OS-level
      // exclusive lock via dart:io.
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });
}
