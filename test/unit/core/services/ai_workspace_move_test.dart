// AI-workspace move-as-access-control: unit tests for [aiAwareMove] (device-free,
// FFI-free). Pins the security-critical REVOKE: a move-out must verify the
// re-encrypted master-KEK copy decrypts BEFORE deleting the only-AI copy, and
// then verify the AI copy is actually gone.
//
// Run: flutter test test/unit/core/services/ai_workspace_move_test.dart

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/ai_workspace_move.dart';
import 'package:fula_files/core/services/fula_api_service.dart'
    show FulaApiService;

import '../../../helpers/fake_fula_api.dart';

const String _ws = FulaApiService.aiWorkspaceBucket; // 'fula-ai-workspace'
final Uint8List _bytes = Uint8List.fromList([1, 2, 3, 4]);

void main() {
  group('aiAwareMove — grant (move INTO the AI bucket)', () {
    test('re-encrypts via the workspace client + deletes the source', () async {
      final fake = FakeFulaApi();
      fake.aiConnectionExists = true;
      fake.downloadResponseFor['images:photo.jpg'] = _bytes;
      fake.objectsResponseFor['images'] = [FulaObject(key: 'photo.jpg', size: 4)];

      final r = await aiAwareMove(
        fake,
        srcBucket: 'images',
        srcKey: 'photo.jpg',
        destBucket: _ws,
        destKey: 'ai/image/photo.jpg',
      );

      expect(r, AiMoveResult.grantedToAi);
      // Written via the WORKSPACE client (grant), under the ai/image/ key.
      expect(fake.workspaceUploadCalls['$_ws:ai/image/photo.jpg'], 1);
      // Now enumerable in the workspace (the AI can list it).
      final ws = await fake.listWorkspaceObjects(_ws, prefix: 'ai/');
      expect(ws.map((o) => o.key), contains('ai/image/photo.jpg'));
      // The source (normal bucket) was removed — a move, not a copy.
      expect(fake.deletedKeys, contains('images:photo.jpg'));
    });
  });

  group('aiAwareMove — revoke (move OUT of the AI bucket)', () {
    FakeFulaApi revokeFake() {
      final fake = FakeFulaApi();
      fake.aiConnectionExists = true;
      fake.objectsResponseFor[_ws] = [FulaObject(key: 'ai/note/x.txt', size: 4)];
      fake.workspaceDownloadResponseFor['$_ws:ai/note/x.txt'] = _bytes;
      // The re-encrypted master-KEK copy is readable at the destination.
      fake.downloadResponseFor['documents:x.txt'] = _bytes;
      return fake;
    }

    test('verifies the master copy, then deletes + verifies the AI copy gone',
        () async {
      final fake = revokeFake();

      final r = await aiAwareMove(
        fake,
        srcBucket: _ws,
        srcKey: 'ai/note/x.txt',
        destBucket: 'documents',
        destKey: 'x.txt',
      );

      expect(r, AiMoveResult.revokedFromAi);
      expect(fake.workspaceDeleteCalls['$_ws:ai/note/x.txt'], 1);
      final still = await fake.listWorkspaceObjects(_ws, prefix: 'ai/');
      expect(still.any((o) => o.key == 'ai/note/x.txt'), isFalse,
          reason: 'the AI copy is verified gone');
    });

    test('ABORTS without deleting if the re-encrypted copy does not verify',
        () async {
      final fake = revokeFake();
      // The destination read FAILS (bad re-encrypt) — the AI copy MUST be kept.
      fake.downloadErrorFor['documents:x.txt'] = Exception('decrypt failed');

      final r = await aiAwareMove(
        fake,
        srcBucket: _ws,
        srcKey: 'ai/note/x.txt',
        destBucket: 'documents',
        destKey: 'x.txt',
      );

      expect(r, AiMoveResult.verifyFailed);
      expect(fake.workspaceDeleteCalls['$_ws:ai/note/x.txt'], isNull,
          reason: 'must NOT delete the only readable copy when verify fails');
      final still = await fake.listWorkspaceObjects(_ws, prefix: 'ai/');
      expect(still.any((o) => o.key == 'ai/note/x.txt'), isTrue,
          reason: 'the AI copy is kept on a failed verify');
    });
  });

  group('aiAwareMove — normal move (no AI bucket involved)', () {
    test('routes both sides to the master-KEK client; no workspace calls',
        () async {
      final fake = FakeFulaApi();
      fake.downloadResponseFor['images:a.jpg'] = _bytes;

      final r = await aiAwareMove(
        fake,
        srcBucket: 'images',
        srcKey: 'a.jpg',
        destBucket: 'documents',
        destKey: 'a.jpg',
      );

      expect(r, AiMoveResult.moved);
      expect(fake.deletedKeys, contains('images:a.jpg'));
      expect(fake.workspaceUploadCalls.isEmpty, isTrue);
      expect(fake.workspaceDeleteCalls.isEmpty, isTrue);
    });
  });
}
