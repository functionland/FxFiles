// Device-free wiring test for the read-only-legacy guard (Phase 1).
//
// Unlike the pure-logic resolver test, this verifies the guard is actually
// CALLED by FulaApiService's write methods. The guard is the first statement
// of each method — before `_ensureConfigured()` and any SDK call — so it fires
// with no configured client, which is exactly what makes it unit-testable
// without a device or login.
//
// Run: flutter test test/unit/core/services/fula_api_legacy_guard_test.dart

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';

void main() {
  setUp(() => BucketVersionResolver.enabled = false);
  tearDown(() => BucketVersionResolver.enabled = false);

  bool isGuardError(Object? e) =>
      e is FulaApiException &&
      e.toString().contains('Refusing to write to legacy bucket');

  bool isDeleteGuardError(Object? e) =>
      e is FulaApiException &&
      e.toString().contains('does not support deletion');

  group('FulaApiService read-only-legacy guard wiring (device-free)', () {
    test('enabled: every write method blocks a legacy managed bucket', () async {
      BucketVersionResolver.enabled = true;
      final api = FulaApiService.instance;
      await expectLater(
        api.createBucket('images'),
        throwsA(predicate(isGuardError)),
      );
      await expectLater(
        api.uploadObject('videos', 'k', Uint8List(0)),
        throwsA(predicate(isGuardError)),
      );
      await expectLater(
        api.uploadLargeFile('documents', 'k', Uint8List(0)),
        throwsA(predicate(isGuardError)),
      );
      await expectLater(
        api.uploadLargeFileFromPath('audio', 'k', '/tmp/x'),
        throwsA(predicate(isGuardError)),
      );
      await expectLater(
        api.uploadLargeFileResumable('documents', 'k', '/tmp/x', '/tmp/m'),
        throwsA(predicate(isGuardError)),
      );
    });

    test('enabled: a v8 sibling is NOT blocked by the guard', () async {
      BucketVersionResolver.enabled = true;
      // Guard lets it through; it then fails on "not configured" (no client in
      // a unit test) — a DIFFERENT error, proving the guard did not fire.
      await expectLater(
        FulaApiService.instance.createBucket('images-v8'),
        throwsA(predicate((Object? e) => !isGuardError(e))),
      );
    });

    test('disabled (default): the guard is inert — zero behavior change', () async {
      await expectLater(
        FulaApiService.instance.createBucket('images'),
        throwsA(predicate((Object? e) => !isGuardError(e))),
      );
    });

    test('P4 enabled: deleteObject blocks a managed legacy bucket', () async {
      BucketVersionResolver.enabled = true;
      await expectLater(
        FulaApiService.instance.deleteObject('images', 'k'),
        throwsA(predicate(isDeleteGuardError)),
      );
    });

    test('P4 enabled: deleteObject on a v8 sibling is NOT delete-guarded', () async {
      BucketVersionResolver.enabled = true;
      // Guard lets it through; then it fails on "not configured" — a different
      // error, proving the delete-guard did not fire.
      await expectLater(
        FulaApiService.instance.deleteObject('images-v8', 'k'),
        throwsA(predicate((Object? e) => !isDeleteGuardError(e))),
      );
    });

    test('P4 disabled: deleteObject is NOT delete-guarded (normal delete)', () async {
      await expectLater(
        FulaApiService.instance.deleteObject('images', 'k'),
        throwsA(predicate((Object? e) => !isDeleteGuardError(e))),
      );
    });

    test('Type-B enabled: playlists + face-metadata writes are guarded', () async {
      BucketVersionResolver.enabled = true;
      final api = FulaApiService.instance;
      for (final b in <String>['playlists', 'face-metadata']) {
        await expectLater(api.createBucket(b),
            throwsA(predicate(isGuardError)), reason: b);
        await expectLater(api.uploadObject(b, 'k', Uint8List(0)),
            throwsA(predicate(isGuardError)), reason: b);
      }
      // playlists has live deletes — the delete-guard must arm on legacy...
      await expectLater(
        api.deleteObject('playlists', 'k'),
        throwsA(predicate(isDeleteGuardError)),
      );
      // ...but the v8 siblings escape both guards (routing target).
      await expectLater(
        api.createBucket('playlists-v8'),
        throwsA(predicate((Object? e) => !isGuardError(e))),
      );
      await expectLater(
        api.deleteObject('playlists-v8', 'k'),
        throwsA(predicate((Object? e) => !isDeleteGuardError(e))),
      );
    });
  });
}
