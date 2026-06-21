// P14.1 — AI-file open routing: unit tests (device-free, FFI-free).
//
// P14 surfaced the AI/MCP's `fula-ai-workspace` items in the native category
// views (tagged sourceBucket='fula-ai-workspace'), but the OPEN/DOWNLOAD call
// sites still routed every tap to the master-KEK client, so an adopted AI file
// failed to decrypt. P14.1 adds two routing helpers that send AI files to the
// workspace client and everything else to the normal download path:
//
//   downloadBySourceBucket(bucket, key, sourceBucket)
//   downloadBySourceBucketWithLocalFallback(bucket, key, sourceBucket)
//
// These tests pin the routing at the FulaApi boundary (the same boundary the
// real FulaApiService and the FakeFulaApi both implement): an AI sourceBucket
// MUST hit downloadWorkspaceObject and MUST NOT hit downloadObject; a normal
// sourceBucket MUST hit downloadObject and MUST NOT hit the workspace client.
//
// Run: flutter test test/unit/core/services/ai_open_routing_test.dart

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/fula_api_service.dart'
    show FulaApiService;

import '../../../helpers/fake_fula_api.dart';

const String _ws = FulaApiService.aiWorkspaceBucket; // 'fula-ai-workspace'

void main() {
  group('downloadBySourceBucket routes by sourceBucket', () {
    test('AI sourceBucket → workspace client (NOT the master-KEK client)',
        () async {
      final fake = FakeFulaApi();
      fake.aiConnectionExists = true;
      const key = 'ai/images/x.png';
      final aiBytes = Uint8List.fromList([1, 2, 3]);
      fake.workspaceDownloadResponseFor['$_ws:$key'] = aiBytes;

      final out = await fake.downloadBySourceBucket(_ws, key, _ws);

      expect(out, aiBytes, reason: 'bytes came from the workspace client');
      expect(fake.downloadWorkspaceCalls['$_ws:$key'], 1,
          reason: 'AI files decrypt only via downloadWorkspaceObject');
      expect(fake.downloadCalls['$_ws:$key'], isNull,
          reason: 'must NOT touch the normal master-KEK downloadObject path');
    });

    test('normal sourceBucket → downloadObject (NOT the workspace client)',
        () async {
      final fake = FakeFulaApi();
      // No AI connection needed for a normal-file download — and asserting it
      // works with the gate OFF proves the normal path is independent of AI.
      const bucket = 'images';
      const key = 'photos/x.jpg';
      final userBytes = Uint8List.fromList([9, 8, 7]);
      fake.downloadResponseFor['$bucket:$key'] = userBytes;

      final out = await fake.downloadBySourceBucket(bucket, key, 'images');

      expect(out, userBytes, reason: 'bytes came from the normal client');
      expect(fake.downloadCalls['$bucket:$key'], 1,
          reason: "the user's own file uses downloadObject");
      expect(fake.downloadWorkspaceCalls['$bucket:$key'], isNull,
          reason: 'a normal file must NEVER hit the workspace client');
      expect(fake.hasAiConnectionCalls, 0,
          reason: 'routing a normal file must not even probe the AI gate');
    });

    test('null sourceBucket → downloadObject (legacy items with no tag)',
        () async {
      final fake = FakeFulaApi();
      const bucket = 'documents';
      const key = 'a.pdf';
      final bytes = Uint8List.fromList([4, 2]);
      fake.downloadResponseFor['$bucket:$key'] = bytes;

      final out = await fake.downloadBySourceBucket(bucket, key, null);

      expect(out, bytes);
      expect(fake.downloadCalls['$bucket:$key'], 1);
      expect(fake.downloadWorkspaceCalls.isEmpty, isTrue);
    });
  });

  group('downloadBySourceBucketWithLocalFallback routes by sourceBucket', () {
    test('AI sourceBucket → workspace client, skipping the LAN fallback',
        () async {
      final fake = FakeFulaApi();
      fake.aiConnectionExists = true;
      const key = 'ai/videos/clip.mp4';
      final aiBytes = Uint8List.fromList([5, 5, 5]);
      fake.workspaceDownloadResponseFor['$_ws:$key'] = aiBytes;

      final out =
          await fake.downloadBySourceBucketWithLocalFallback(_ws, key, _ws);

      expect(out, aiBytes);
      expect(fake.downloadWorkspaceCalls['$_ws:$key'], 1,
          reason: 'AI files decrypt only via the cloud-only workspace client');
      expect(fake.downloadCalls['$_ws:$key'], isNull,
          reason: 'AI branch must skip the LAN/master downloadObject path');
    });

    test('normal sourceBucket → LAN-first path (NOT the workspace client)',
        () async {
      final fake = FakeFulaApi();
      const bucket = 'images';
      const key = 'photos/y.jpg';
      final userBytes = Uint8List.fromList([3, 1, 4, 1, 5]);
      // The fake's downloadWithLocalFallback delegates to downloadObject when no
      // local stub is set, so assert the normal-download counter incremented.
      fake.downloadResponseFor['$bucket:$key'] = userBytes;

      final out = await fake.downloadBySourceBucketWithLocalFallback(
          bucket, key, 'images');

      expect(out, userBytes);
      expect(fake.downloadCalls['$bucket:$key'], 1,
          reason: 'the LAN-fallback variant resolves via the normal client');
      expect(fake.downloadWorkspaceCalls.isEmpty, isTrue,
          reason: 'a normal file must NEVER hit the workspace client');
    });
  });
}
