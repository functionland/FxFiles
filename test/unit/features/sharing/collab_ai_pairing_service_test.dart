// Tests for the collab↔AI pairing service. Exercises the FFI-FREE seams:
//  1. buildCollabCapabilityJson — EXACT capability.rs CapabilityBundleJson key
//     set + optional-omission rules (the wrap itself is an FFI-blocked seam).
//  2. platform MCP configs — shape + the triple-nested-JSON escaping that
//     wrapped_link_secret (JSON string) → capability (JSON) → env (config) must
//     survive intact.
//  3. FULA-id encode/decode — a cross-impl known-answer matching the Rust
//     fula-mcp `encode_fula_id`.
//  4. the REAL wrap seam (realWrapper, fula_client 0.6.18) fails closed on a
//     non-32-byte secret / recipient key / elapsed TTL BEFORE the FFI call. The
//     happy-path FFI wrap is proven by `flutter build web`, not unit tests.
//  5. authorizeCollabGroups — server PR #69 POST, via MockClient + the mocked
//     secure-storage channel.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/share_link_builder.dart';
import 'package:fula_files/features/sharing/services/collab_ai_pairing_service.dart';

const _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildCollabCapabilityJson (pure, matches fula-mcp capability.rs)', () {
    test('emits EXACTLY the CapabilityBundleJson keys with all optionals', () {
      final json = CollabAiPairingService.buildCollabCapabilityJson(
        webuiBase: 'https://cloud.fx.land',
        groupId: 'group-1',
        manifestBucket: 'fula-metadata',
        manifestKey: 'm/group-1.json',
        wrappedLinkSecret: '{"id":"tok","version":5}',
        collabWriteToken: 'cw.tok',
        refreshToken: 'refresh.tok',
        refreshUrl: 'https://cloud.fx.land/api/mcp/tokens/refresh-connection',
        storageApiUrl: 'https://cloud.fx.land',
        userId: 'deadbeef01234567',
      );
      final map = jsonDecode(json) as Map<String, dynamic>;
      expect(map.keys.toSet(), {
        'webui_base',
        'group_id',
        'manifest_bucket',
        'manifest_key',
        'wrapped_link_secret',
        'collab_write_token',
        'refresh_token',
        'refresh_url',
        'storage_api_url',
        'user_id',
      });
      expect(map['webui_base'], 'https://cloud.fx.land');
      expect(map['group_id'], 'group-1');
      expect(map['manifest_bucket'], 'fula-metadata');
      expect(map['manifest_key'], 'm/group-1.json');
      expect(map['collab_write_token'], 'cw.tok');
    });

    test('required-only: omits every optional', () {
      final map = jsonDecode(
        CollabAiPairingService.buildCollabCapabilityJson(
          webuiBase: 'https://cloud.fx.land',
          groupId: 'g',
          manifestBucket: 'b',
          manifestKey: 'k',
          wrappedLinkSecret: '{}',
        ),
      ) as Map<String, dynamic>;
      expect(map.keys.toSet(), {
        'webui_base',
        'group_id',
        'manifest_bucket',
        'manifest_key',
        'wrapped_link_secret',
      });
    });

    test('refresh_url is omitted unless refresh_token is present', () {
      final map = jsonDecode(
        CollabAiPairingService.buildCollabCapabilityJson(
          webuiBase: 'https://cloud.fx.land',
          groupId: 'g',
          manifestBucket: 'b',
          manifestKey: 'k',
          wrappedLinkSecret: '{}',
          refreshUrl: 'https://cloud.fx.land/api/mcp/tokens/refresh-connection',
        ),
      ) as Map<String, dynamic>;
      expect(map.containsKey('refresh_url'), isFalse);
      expect(map.containsKey('refresh_token'), isFalse);
    });
  });

  group('platform MCP configs (pure)', () {
    // A realistic wrapped_link_secret IS itself a JSON string — the worst case
    // for nesting/escaping.
    const wrapped =
        '{"id":"abc","wrapped_key":{"ct":"AA=="},"path_scope":"/collab/g","version":5}';
    final capability = CollabAiPairingService.buildCollabCapabilityJson(
      webuiBase: 'https://cloud.fx.land',
      groupId: 'g',
      manifestBucket: 'b',
      manifestKey: 'k',
      wrappedLinkSecret: wrapped,
      collabWriteToken: 'cw',
    );

    test('local stdio config launches the npm package via npx', () {
      final cfg = jsonDecode(
        CollabAiPairingService.buildLocalStdioMcpConfig(capability),
      ) as Map<String, dynamic>;
      final fula = (cfg['mcpServers'] as Map)['fula'] as Map;
      expect(fula['command'], 'npx');
      expect(fula['args'], ['-y', '@functionland/fula-mcp']);
      expect((fula['env'] as Map)['FULA_MCP_CAPABILITY'], capability);
    });

    test('triple-nested wrapped_link_secret survives env→capability→token', () {
      // config(JSON) → env.FULA_MCP_CAPABILITY(JSON string) →
      // capability(JSON) → wrapped_link_secret(JSON string) → original wrap.
      final cfg = jsonDecode(
        CollabAiPairingService.buildLocalStdioMcpConfig(capability),
      ) as Map<String, dynamic>;
      final env = ((cfg['mcpServers'] as Map)['fula'] as Map)['env'] as Map;
      final capStr = env['FULA_MCP_CAPABILITY'] as String;
      final cap = jsonDecode(capStr) as Map<String, dynamic>;
      expect(cap['wrapped_link_secret'], wrapped);
      // And the inner wrap is still valid JSON with its fields intact.
      final tok = jsonDecode(cap['wrapped_link_secret'] as String)
          as Map<String, dynamic>;
      expect(tok['version'], 5);
      expect(tok['id'], 'abc');
    });

    test('hosted config targets the official hosted Worker', () {
      final cfg = jsonDecode(
        CollabAiPairingService.buildHostedMcpConfig(capability),
      ) as Map<String, dynamic>;
      final fula = (cfg['mcpServers'] as Map)['fula'] as Map;
      expect(fula['url'], kHostedMcpBaseUrl);
      expect((fula['env'] as Map)['FULA_MCP_CAPABILITY'], capability);
    });
  });

  group('FULA share id (cross-impl known-answer with fula-mcp)', () {
    test('encode of 0x00..0x1f matches the Rust encode_fula_id KAT', () {
      final pk = Uint8List.fromList(List<int>.generate(32, (i) => i));
      expect(encodeFulaShareId(pk),
          'FULA-AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8');
    });

    test('decode of a FULA id yields the 32-byte public key', () {
      const id = 'FULA-AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';
      final pk = decodeFulaShareId(id);
      expect(pk.length, 32);
      expect(pk, List<int>.generate(32, (i) => i));
    });
  });

  group('wrap seam (real binding, fula_client 0.6.18)', () {
    // The happy-path wrap is FFI (RustLib), so it can't run under `flutter test`
    // — it is proven by `flutter build web`. Here we assert the REAL wrapper's
    // fail-closed input guards, which run BEFORE the FFI call.
    test('realWrapper rejects a non-32-byte link secret before FFI', () async {
      await expectLater(
        CollabAiPairingService.realWrapper(
          linkSecret: Uint8List(16),
          recipientPublicKey: Uint8List(32),
          pathScope: '/collab/g',
        ),
        throwsA(isA<CollabPairingException>()),
      );
    });

    test('realWrapper rejects a non-32-byte recipient key before FFI', () async {
      await expectLater(
        CollabAiPairingService.realWrapper(
          linkSecret: Uint8List(32),
          recipientPublicKey: Uint8List(31),
          pathScope: '/collab/g',
        ),
        throwsA(isA<CollabPairingException>()),
      );
    });

    test('realWrapper rejects an already-elapsed TTL before FFI', () async {
      await expectLater(
        CollabAiPairingService.realWrapper(
          linkSecret: Uint8List(32),
          recipientPublicKey: Uint8List(32),
          pathScope: '/collab/g',
          expiresInSeconds: 0,
        ),
        throwsA(isA<CollabPairingException>()),
      );
    });
  });

  group('authorizeCollabGroups (server PR #69)', () {
    late Map<String, String> store;

    setUp(() async {
      store = <String, String>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_secureStorageChannel, (call) async {
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
          .setMockMethodCallHandler(_secureStorageChannel, null);
    });

    test('POSTs to the connection endpoint and returns the collab token',
        () async {
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'test-jwt');
      http.Request? seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(
          jsonEncode({
            'collabToken': 'ct.value',
            'jti': 'jti-1',
            'expiresAt': 123,
            'groupIds': ['g1'],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final res = await CollabAiPairingService.instance.authorizeCollabGroups(
        connectionId: 'conn-1',
        groupIds: ['g1'],
        httpClient: client,
      );

      expect(res.collabToken, 'ct.value');
      expect(res.jti, 'jti-1');
      expect(res.expiresAt, 123);
      expect(res.groupIds, ['g1']);

      expect(seen!.method, 'POST');
      expect(seen!.url.path, '/api/mcp/connections/conn-1/collab-groups');
      expect(seen!.headers['Authorization'], 'Bearer test-jwt');
      expect((jsonDecode(seen!.body) as Map)['groupIds'], ['g1']);
    });

    test('throws when not signed in (no session jwt)', () async {
      final client = MockClient((_) async => http.Response('{}', 200));
      await expectLater(
        CollabAiPairingService.instance.authorizeCollabGroups(
          connectionId: 'conn-1',
          groupIds: ['g1'],
          httpClient: client,
        ),
        throwsA(isA<CollabPairingException>()),
      );
    });

    test('throws on a non-2xx response', () async {
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'test-jwt');
      final client =
          MockClient((_) async => http.Response('nope', 500));
      await expectLater(
        CollabAiPairingService.instance.authorizeCollabGroups(
          connectionId: 'conn-1',
          groupIds: ['g1'],
          httpClient: client,
        ),
        throwsA(isA<CollabPairingException>()),
      );
    });

    test('throws when the response omits collabToken', () async {
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'test-jwt');
      final client = MockClient(
          (_) async => http.Response(jsonEncode({'jti': 'x'}), 200));
      await expectLater(
        CollabAiPairingService.instance.authorizeCollabGroups(
          connectionId: 'conn-1',
          groupIds: ['g1'],
          httpClient: client,
        ),
        throwsA(isA<CollabPairingException>()),
      );
    });
  });
}
