// P16 — "AI Connections: activity view + honest disconnect" unit tests.
//
// All FFI-FREE and device-free:
//   1. listAiActivity (standalone, over FulaApi) — GATED on the AI connection
//      (empty when none), surfaces the shared workspace objects when connected,
//      and sorts newest-first. Exercised directly against FakeFulaApi (no
//      Riverpod container, no async-build timing).
//   2. AiActivityNotifier — the provider wrapper: empty + hasConnection=false
//      when no connection (the gate the UI keys off); objects + hasConnection
//      =true when connected. Driven via makeTestContainer(fulaApi: fake) with an
//      EXPLICIT await load() (never relying on the build() microtask).
//   3. Honest disconnect — AiConnectionsNotifier.deleteConnection drives the
//      real AiConnectionService.deleteConnection through to (mocked) secure
//      storage, removing exactly the chosen record. deleteConnection touches
//      ONLY SecureStorage (no FFI/network), so this is the real path.
//
// Run: flutter test test/unit/features/ai_connections/ai_activity_test.dart

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/fula_api_service.dart' show FulaApiService;
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/features/ai_connections/models/ai_connection.dart';
import 'package:fula_files/features/ai_connections/providers/ai_activity_provider.dart';
import 'package:fula_files/features/ai_connections/providers/ai_connections_provider.dart';
import 'package:fula_files/features/ai_connections/services/ai_activity_service.dart';

import '../../../helpers/fake_fula_api.dart';
import '../../../helpers/test_container.dart';

const String _ws = FulaApiService.aiWorkspaceBucket; // 'fula-ai-workspace'

FulaObject obj(String key, {int size = 1, DateTime? modified}) =>
    FulaObject(key: key, size: size, lastModified: modified);

void main() {
  group('listAiActivity (standalone, FulaApi)', () {
    test('GATE: no AI connection ⇒ empty, workspace never listed', () async {
      final fake = FakeFulaApi();
      // aiConnectionExists defaults to FALSE (non-AI user).
      fake.objectsResponseFor[_ws] = [obj('ai/images/sketch.png')]; // ignored

      final items = await listAiActivity(fake);

      expect(items, isEmpty,
          reason: 'non-AI user sees nothing from the AI workspace');
      expect(fake.listWorkspaceObjectsCalls[_ws], isNull,
          reason: 'the gate short-circuits before any workspace list call');
    });

    test('connected ⇒ returns the shared ai/ workspace objects', () async {
      final fake = FakeFulaApi();
      fake.aiConnectionExists = true;
      fake.objectsResponseFor[_ws] = [
        obj('ai/images/sketch.png', size: 10),
        obj('ai/documents/notes.md', size: 20),
      ];

      final items = await listAiActivity(fake);

      expect(items.map((o) => o.key).toSet(),
          {'ai/images/sketch.png', 'ai/documents/notes.md'});
      // Listed under the ai/ prefix on the workspace bucket.
      expect(fake.listWorkspaceObjectsCalls[_ws], 1);
      // Tagged with the workspace bucket by the listing layer.
      expect(items.every((o) => o.sourceBucket == _ws), isTrue);
    });

    test('sorts newest-first; unknown-modified last', () async {
      final fake = FakeFulaApi();
      fake.aiConnectionExists = true;
      fake.objectsResponseFor[_ws] = [
        obj('ai/a.txt', modified: DateTime.utc(2026, 1, 1)),
        obj('ai/c.txt', modified: DateTime.utc(2026, 3, 1)), // newest
        obj('ai/b.txt', modified: DateTime.utc(2026, 2, 1)),
        obj('ai/z.txt'), // no modified time → sorts last
      ];

      final items = await listAiActivity(fake);

      expect(items.map((o) => o.key).toList(),
          ['ai/c.txt', 'ai/b.txt', 'ai/a.txt', 'ai/z.txt']);
    });

    test('connected but empty workspace ⇒ empty list (still listed)', () async {
      final fake = FakeFulaApi();
      fake.aiConnectionExists = true;
      fake.objectsResponseFor[_ws] = const <FulaObject>[];

      final items = await listAiActivity(fake);

      expect(items, isEmpty);
      expect(fake.listWorkspaceObjectsCalls[_ws], 1,
          reason: 'a connected user DOES read the workspace (just empty)');
    });
  });

  group('AiActivityNotifier (provider wrapper, injected FulaApi)', () {
    test('no connection ⇒ hasConnection=false, empty objects (gated)', () async {
      final fake = FakeFulaApi();
      // aiConnectionExists defaults to FALSE.
      fake.objectsResponseFor[_ws] = [obj('ai/images/x.png')]; // ignored

      final container = makeTestContainer(fulaApi: fake);
      // EXPLICIT load — do NOT rely on the build() microtask having flushed.
      await container.read(aiActivityProvider.notifier).load();
      final state = container.read(aiActivityProvider);

      expect(state.hasConnection, isFalse);
      expect(state.objects, isEmpty);
      expect(state.isBusy, isFalse);
      expect(state.error, isNull);
    });

    test('connected ⇒ hasConnection=true, objects populated', () async {
      final fake = FakeFulaApi();
      fake.aiConnectionExists = true;
      fake.objectsResponseFor[_ws] = [
        obj('ai/images/sketch.png'),
        obj('ai/documents/notes.md'),
      ];

      final container = makeTestContainer(fulaApi: fake);
      await container.read(aiActivityProvider.notifier).load();
      final state = container.read(aiActivityProvider);

      expect(state.hasConnection, isTrue);
      expect(state.objects.map((o) => o.key).toSet(),
          {'ai/images/sketch.png', 'ai/documents/notes.md'});
      expect(state.isBusy, isFalse);
      expect(state.error, isNull);
    });
  });

  group('honest disconnect (AiConnectionsNotifier → service → storage)', () {
    // In-memory secure-storage method-channel mock (mirrors
    // ai_connection_service_test.dart) so the REAL persistence path runs with no
    // native plugin. deleteConnection touches ONLY SecureStorage — no FFI.
    const secureStorageChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    late Map<String, String> store;

    setUp(() async {
      store = <String, String>{};
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, (call) async {
        final args =
            (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
        switch (call.method) {
          case 'read':
            return store[args['key'] as String];
          case 'write':
            store[args['key'] as String] = args['value'] as String;
            return null;
          case 'delete':
            store.remove(args['key'] as String);
            return null;
          case 'deleteAll':
            store.clear();
            return null;
          case 'containsKey':
            return store.containsKey(args['key'] as String);
          case 'readAll':
            return Map<String, String>.from(store);
          default:
            return null;
        }
      });
      await SecureStorageService.instance.init();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, null);
    });

    AiConnection record(String id, String label) => AiConnection(
          id: id,
          label: label,
          mcpPublicKeyB64: base64Encode(Uint8List.fromList(List.filled(32, 7))),
          createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        );

    test('deleteConnection removes exactly the chosen record', () async {
      // Seed two records DIRECTLY (not via createConnection — that pulls in FFI
      // keypair + network mint).
      await SecureStorageService.instance.write(
        SecureStorageKeys.aiConnections,
        AiConnection.encodeList([record('id1', 'A'), record('id2', 'B')]),
      );

      // Drive the provider's disconnect action (what the screen calls).
      final fake = FakeFulaApi();
      final container = makeTestContainer(fulaApi: fake);
      await container.read(aiConnectionsProvider.notifier).deleteConnection('id1');

      // Storage now holds only the survivor — proving deleteConnection ran.
      final raw = await SecureStorageService.instance
          .read(SecureStorageKeys.aiConnections);
      final decoded = (jsonDecode(raw!) as List).cast<Map<String, dynamic>>();
      expect(decoded.length, 1);
      expect(decoded.single['id'], 'id2');

      // And the provider's in-memory list reflects the deletion.
      final state = container.read(aiConnectionsProvider);
      expect(state.connections.map((c) => c.id), ['id2']);
      expect(state.isBusy, isFalse);
    });
  });
}
