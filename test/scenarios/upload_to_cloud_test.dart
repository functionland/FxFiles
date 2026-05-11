// Scenario #3 — Upload to Cloud (post-login).
//
// **Tier:** unit tests of the FulaApi boundary. Widget tests are
// scoped to UI logic that consumes the provider; the actual upload
// button is screen-specific and may need a separate dedicated test
// once the screen is refactored to read `ref.watch(fulaApiProvider)`.
//
// **What's covered:**
// - Happy path: `uploadObject` returns the expected `UploadResult`.
// - Large-file dispatch: `uploadLargeFile` fires final progress event
//   and returns an etag.
// - Error path: `uploadObject` throws → callers see `FulaApiException`.
// - Call shape: only one PUT per (bucket, key) on happy path.
//
// **Out of scope here (file as integration/manual):**
// - Real device upload flow (permissions, file picker, OS-level
//   share intents).
// - Cellular-vs-WiFi gating in `SyncService` (separate scenario).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/providers/fula_api_provider.dart';
import 'package:fula_files/core/services/fula_api.dart';

import '../helpers/fake_fula_api.dart';
import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

void main() {
  group('Scenario #3 — Upload to Cloud', () {
    test('uploadObject returns the canned UploadResult', () async {
      final fake = FakeFulaApi();
      fake.uploadResponseFor['images:foo.jpg'] = UploadResult(
        etag: 'bafkr4ihhardcodedetagcidstringgoeshere',
        contentCid: 'bafkr4ihhardcodedetagcidstringgoeshere',
      );

      final container = makeTestContainer(fulaApi: fake);
      final api = container.read(fulaApiProvider);

      final result = await api.uploadObject(
        'images',
        'foo.jpg',
        smallUploadPayload,
        contentType: 'image/jpeg',
      );

      expect(result.etag, 'bafkr4ihhardcodedetagcidstringgoeshere');
      expect(result.contentCid, isNotNull);
      expect(fake.uploadCalls['images:foo.jpg'], 1,
          reason: 'exactly one PUT per (bucket, key) on happy path');
    });

    test('uploadObject without canned response yields a synthetic etag',
        () async {
      // Tests that don't care about the specific etag value still
      // get a well-formed return so they can chain follow-up logic.
      final fake = FakeFulaApi();
      final result = await fake.uploadObject(
        'documents',
        'note.txt',
        smallUploadPayload,
      );
      expect(result.etag, isNotEmpty);
      expect(result.contentCid, equals(result.etag),
          reason: 'synthetic result mirrors etag → cid as v0.4.4+ master would');
    });

    test('uploadLargeFile fires a final progress event', () async {
      final fake = FakeFulaApi();
      final events = <UploadProgress>[];
      final etag = await fake.uploadLargeFile(
        'videos',
        'clip.mp4',
        secondUploadPayload,
        onProgress: events.add,
      );
      expect(etag, isNotEmpty);
      expect(events, isNotEmpty,
          reason: 'progress callback must fire at least once for UI');
      expect(events.last.bytesUploaded, secondUploadPayload.length);
      expect(events.last.totalBytes, secondUploadPayload.length);
      expect(events.last.percentage, 100.0);
    });

    test('upload error propagates as FulaApiException', () async {
      final fake = FakeFulaApi();
      fake.uploadObjectError = FulaApiException('master 503');

      await expectLater(
        fake.uploadObject('images', 'fail.jpg', smallUploadPayload),
        throwsA(isA<FulaApiException>()),
      );
      expect(fake.uploadCalls['images:fail.jpg'], 1,
          reason: 'the call was attempted before throwing');
    });

    test('uploadLargeFileFromPath surfaces a progress event for empty file',
        () async {
      final fake = FakeFulaApi();
      final events = <UploadProgress>[];
      final etag = await fake.uploadLargeFileFromPath(
        'images',
        'from-path.jpg',
        '/nonexistent/test/path.jpg',
        onProgress: events.add,
      );
      expect(etag, isNotEmpty);
      // Fake reports 0/0 because no bytes are read on the Rust side.
      // The contract guarantees at least one event fires so UI state
      // resolves cleanly to "completed".
      expect(events, isNotEmpty);
    });
  });
}
