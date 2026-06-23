// P13 — AI Connections service tests.
//
// These tests target the FFI-FREE seams of AiConnectionService (the rust bridge
// `fula.*` is not loaded under `flutter test`, so anything that calls it — i.e.
// generateMcpKeypair / deriveWorkspaceSecret / ownerPublicKey / createConnection
// — is intentionally NOT exercised here; those wrap FFI which is assumed correct):
//
//  1. buildBundleJson (PURE) — exact contract key set + each *_b64 = 32 bytes.
//  2. mintScopedJwt — POST body/headers + JWT parse, via an injected MockClient.
//  3. listConnections / deleteConnection — the REAL persistence round-trip,
//     proving the persisted record format carries no secrets.
//  4. AiConnection.encodeList — record JSON key set.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/features/ai_connections/models/ai_connection.dart';
import 'package:fula_files/features/ai_connections/services/ai_connection_service.dart';

/// Wire contract of the flutter_secure_storage method channel (see
/// method_channel_flutter_secure_storage.dart). We back it with an in-memory map
/// so the real SecureStorageService read/write paths run without a native plugin.
const _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // In-memory store backing the mocked secure-storage channel.
  late Map<String, String> store;

  setUp(() async {
    store = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureStorageChannel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
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

  final service = AiConnectionService.instance;

  group('buildBundleJson (pure, FFI-free)', () {
    // Distinct 32-byte buffers so a field swap would be detectable.
    final workspaceSecret =
        Uint8List.fromList(List<int>.generate(32, (i) => i));
    final mcpSecret = Uint8List.fromList(List<int>.generate(32, (i) => 100 + i));
    final ownerPublic = Uint8List.fromList(List<int>.generate(32, (i) => 200 - i));

    test('emits EXACTLY the CapabilityBundle contract keys (with optionals)', () {
      final json = service.buildBundleJson(
        endpoint: 'https://s3.cloud.fx.land',
        jwt: 'jwt.token.value',
        workspaceSecret: workspaceSecret,
        mcpSecretKey: mcpSecret,
        ownerPublicKey: ownerPublic,
        userId: 'deadbeef01234567',
        storageApiUrl: 'https://cloud.fx.land',
      );
      final map = jsonDecode(json) as Map<String, dynamic>;

      // EXACT key set — no extras, none missing. Matches capability.rs
      // CapabilityBundleJson (endpoint/jwt/workspace_secret_b64/mcp_secret_b64/
      // owner_public_b64 required; user_id/storage_api_url optional).
      expect(
        map.keys.toSet(),
        {
          'endpoint',
          'jwt',
          'workspace_secret_b64',
          'mcp_secret_b64',
          'owner_public_b64',
          'user_id',
          'storage_api_url',
        },
      );

      expect(map['endpoint'], 'https://s3.cloud.fx.land');
      expect(map['jwt'], 'jwt.token.value');
      expect(map['user_id'], 'deadbeef01234567');
      expect(map['storage_api_url'], 'https://cloud.fx.land');
    });

    test('each *_b64 is base64 that decodes to 32 bytes', () {
      final map = jsonDecode(
        service.buildBundleJson(
          endpoint: 'https://s3.cloud.fx.land',
          jwt: 'j',
          workspaceSecret: workspaceSecret,
          mcpSecretKey: mcpSecret,
          ownerPublicKey: ownerPublic,
        ),
      ) as Map<String, dynamic>;

      for (final k in ['workspace_secret_b64', 'mcp_secret_b64', 'owner_public_b64']) {
        final decoded = base64Decode(map[k] as String);
        expect(decoded.length, 32, reason: '$k must decode to 32 bytes');
      }
    });

    test('field direction: mcp_secret_b64=SECRET, owner_public_b64=PUBLIC', () {
      final map = jsonDecode(
        service.buildBundleJson(
          endpoint: 'e',
          jwt: 'j',
          workspaceSecret: workspaceSecret,
          mcpSecretKey: mcpSecret,
          ownerPublicKey: ownerPublic,
        ),
      ) as Map<String, dynamic>;

      expect(base64Decode(map['workspace_secret_b64'] as String), workspaceSecret);
      expect(base64Decode(map['mcp_secret_b64'] as String), mcpSecret);
      expect(base64Decode(map['owner_public_b64'] as String), ownerPublic);
    });

    test('omits optional user_id / storage_api_url when absent', () {
      final map = jsonDecode(
        service.buildBundleJson(
          endpoint: 'e',
          jwt: 'j',
          workspaceSecret: workspaceSecret,
          mcpSecretKey: mcpSecret,
          ownerPublicKey: ownerPublic,
        ),
      ) as Map<String, dynamic>;

      expect(map.containsKey('user_id'), isFalse);
      expect(map.containsKey('storage_api_url'), isFalse);
      // Required fields still present.
      expect(map.keys.toSet(), {
        'endpoint',
        'jwt',
        'workspace_secret_b64',
        'mcp_secret_b64',
        'owner_public_b64',
      });
    });
  });

  group('mintScopedJwt (POST contract, injected http.Client)', () {
    test('posts to /api/mcp/tokens with bearer auth and parses the token', () async {
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'session-jwt-xyz');

      http.Request? captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'token': 'minted.mcp.jwt',
            'jti': 'abc',
            'expiresAt': 1718903600,
            'tokenType': 'mcp_s3',
            'scope': {'v': 1},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final token = await service.mintScopedJwt(httpClient: mock);

      expect(token, 'minted.mcp.jwt');
      expect(captured, isNotNull);
      expect(captured!.method, 'POST');
      // Default issuer base URL (no override seeded).
      expect(captured!.url.toString(), 'https://cloud.fx.land/api/mcp/tokens');
      expect(captured!.headers['Authorization'], 'Bearer session-jwt-xyz');

      // Body is JSON; MCP pubkey is intentionally NOT sent (server scopes by sub).
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body.containsKey('mcp_secret_b64'), isFalse);
      expect(body.containsKey('owner_public_b64'), isFalse);
      expect(body.containsKey('publicKey'), isFalse);
      // No ttlSeconds unless requested.
      expect(body.containsKey('ttlSeconds'), isFalse);
    });

    test('sends ttlSeconds when provided', () async {
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'session-jwt');

      http.Request? captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode({'token': 't'}), 200);
      });

      await service.mintScopedJwt(httpClient: mock, ttlSeconds: 600);
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['ttlSeconds'], 600);
    });

    test('throws when no session JWT is present', () async {
      final mock = MockClient((_) async => http.Response('{}', 200));
      expect(
        () => service.mintScopedJwt(httpClient: mock),
        throwsA(isA<StateError>()),
      );
    });

    test('throws on a non-2xx response', () async {
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'session-jwt');
      final mock = MockClient((_) async => http.Response('nope', 401));
      expect(
        () => service.mintScopedJwt(httpClient: mock),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('persistence (real path, FFI-free): record only, no secrets', () {
    AiConnection record(String id, String label) => AiConnection(
          id: id,
          label: label,
          mcpPublicKeyB64: base64Encode(Uint8List.fromList(List.filled(32, 7))),
          createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        );

    test('listConnections reads back persisted records', () async {
      await SecureStorageService.instance.write(
        SecureStorageKeys.aiConnections,
        AiConnection.encodeList([record('id1', 'A'), record('id2', 'B')]),
      );

      final list = await service.listConnections();
      expect(list.map((c) => c.id), ['id1', 'id2']);
      expect(list.map((c) => c.label), ['A', 'B']);
    });

    test('deleteConnection rewrites storage with the remaining record only', () async {
      await SecureStorageService.instance.write(
        SecureStorageKeys.aiConnections,
        AiConnection.encodeList([record('id1', 'A'), record('id2', 'B')]),
      );

      await service.deleteConnection('id1');

      final raw =
          await SecureStorageService.instance.read(SecureStorageKeys.aiConnections);
      final decoded = (jsonDecode(raw!) as List).cast<Map<String, dynamic>>();
      expect(decoded.length, 1);
      expect(decoded.single['id'], 'id2');
    });

    test('persisted JSON contains NO bundle secrets', () async {
      await SecureStorageService.instance.write(
        SecureStorageKeys.aiConnections,
        AiConnection.encodeList([record('id1', 'A')]),
      );
      final raw =
          await SecureStorageService.instance.read(SecureStorageKeys.aiConnections);

      // The persisted record must never carry any bundle secret / token field.
      expect(raw, isNot(contains('mcp_secret')));
      expect(raw, isNot(contains('workspace_secret')));
      expect(raw, isNot(contains('"jwt"')));
      expect(raw, isNot(contains('secretKey')));
    });

    test('listConnections tolerates missing / malformed storage', () async {
      // Nothing seeded.
      expect(await service.listConnections(), isEmpty);
      // Garbage.
      await SecureStorageService.instance
          .write(SecureStorageKeys.aiConnections, 'not-json');
      expect(await service.listConnections(), isEmpty);
    });
  });

  group('AiConnection.encodeList record shape', () {
    test('record JSON has EXACTLY id/label/mcpPublicKeyB64/createdAt', () {
      final json = AiConnection.encodeList([
        AiConnection(
          id: 'i',
          label: 'l',
          mcpPublicKeyB64: 'pub',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      ]);
      final entry = (jsonDecode(json) as List).single as Map<String, dynamic>;
      expect(entry.keys.toSet(), {'id', 'label', 'mcpPublicKeyB64', 'createdAt'});
    });
  });

  // ===========================================================================
  // L1d — connection lifecycle: refresh-in-bundle + server-side disconnect.
  // ===========================================================================

  group('L1d buildBundleJson: refresh_token / refresh_url', () {
    final workspaceSecret = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final mcpSecret = Uint8List.fromList(List<int>.generate(32, (i) => 100 + i));
    final ownerPublic =
        Uint8List.fromList(List<int>.generate(32, (i) => 200 - i));

    test('includes refresh_token (= server refreshToken, NOT the jwt) + '
        'refresh_url when a refreshToken is supplied', () {
      final map = jsonDecode(
        service.buildBundleJson(
          endpoint: 'https://s3.cloud.fx.land',
          jwt: 'scoped.jwt.value',
          workspaceSecret: workspaceSecret,
          mcpSecretKey: mcpSecret,
          ownerPublicKey: ownerPublic,
          refreshToken: 'server-refresh-credential-xyz',
          refreshUrl: 'https://cloud.fx.land/api/mcp/tokens/refresh-connection',
        ),
      ) as Map<String, dynamic>;

      // Snake_case keys the MCP (fula-mcp) reads.
      expect(map['refresh_token'], 'server-refresh-credential-xyz');
      expect(
        map['refresh_url'],
        'https://cloud.fx.land/api/mcp/tokens/refresh-connection',
      );
      // The refresh credential is SEPARATE from the jwt — never the same value.
      expect(map['refresh_token'], isNot(equals(map['jwt'])));
    });

    test('omits both refresh fields when refreshToken is null (backward-compat)',
        () {
      final map = jsonDecode(
        service.buildBundleJson(
          endpoint: 'e',
          jwt: 'j',
          workspaceSecret: workspaceSecret,
          mcpSecretKey: mcpSecret,
          ownerPublicKey: ownerPublic,
          // No refreshToken (older issuer). refresh_url must not leak in alone.
          refreshUrl: 'https://cloud.fx.land/api/mcp/tokens/refresh-connection',
        ),
      ) as Map<String, dynamic>;

      expect(map.containsKey('refresh_token'), isFalse);
      expect(map.containsKey('refresh_url'), isFalse);
    });
  });

  group('L1d mintConnectionToken (sends mcp_pub_b64, captures refresh creds)',
      () {
    const mcpPubB64 = 'bWNwLXB1YmtleS1iYXNlNjQ='; // arbitrary non-empty base64

    test('posts mcp_pub_b64 in the body and parses '
        'token/refreshToken/connectionId/expiresAt', () async {
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'session-jwt-xyz');

      http.Request? captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'token': 'minted.scoped.jwt',
            'jti': 'jti-1',
            'expiresAt': 1718903600,
            'refreshToken': 'server-refresh-credential',
            'connectionId': '11111111-2222-3333-4444-555555555555',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final result =
          await service.mintConnectionToken(mcpPublicKeyB64: mcpPubB64, httpClient: mock);

      // Captured request: same endpoint + bearer auth as the legacy mint.
      expect(captured!.method, 'POST');
      expect(captured!.url.toString(), 'https://cloud.fx.land/api/mcp/tokens');
      expect(captured!.headers['Authorization'], 'Bearer session-jwt-xyz');

      // The connection pubkey IS now sent (this is what registers the
      // connection); secrets are still never sent.
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['mcp_pub_b64'], mcpPubB64);
      expect(body.containsKey('mcp_secret_b64'), isFalse);

      // Parsed result: jwt + the SEPARATE refresh credential + connectionId.
      expect(result.jwt, 'minted.scoped.jwt');
      expect(result.refreshToken, 'server-refresh-credential');
      expect(result.connectionId, '11111111-2222-3333-4444-555555555555');
      expect(result.expiresAt, 1718903600);
      // refreshToken is NOT the jwt.
      expect(result.refreshToken, isNot(equals(result.jwt)));
    });

    test('tolerates an older issuer: missing refreshToken/connectionId → null',
        () async {
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'session-jwt');
      final mock = MockClient(
        (_) async => http.Response(jsonEncode({'token': 'only.a.token'}), 200),
      );

      final result =
          await service.mintConnectionToken(mcpPublicKeyB64: mcpPubB64, httpClient: mock);

      expect(result.jwt, 'only.a.token');
      expect(result.refreshToken, isNull);
      expect(result.connectionId, isNull);
      expect(result.expiresAt, isNull);
    });

    test('throws StateError when no session JWT is present', () async {
      final mock = MockClient((_) async => http.Response('{}', 200));
      expect(
        () => service.mintConnectionToken(mcpPublicKeyB64: mcpPubB64, httpClient: mock),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('L1d AiConnection round-trips connectionId', () {
    test('toJson includes connectionId when present; fromJson reads it back', () {
      final original = AiConnection(
        id: 'id1',
        label: 'Claude Desktop',
        mcpPublicKeyB64: base64Encode(Uint8List.fromList(List.filled(32, 9))),
        createdAt: DateTime.utc(2026, 6, 22, 10, 11, 12),
        connectionId: 'conn-uuid-abc',
      );
      final json = original.toJson();
      expect(json['connectionId'], 'conn-uuid-abc');

      final restored = AiConnection.fromJson(json);
      expect(restored.connectionId, 'conn-uuid-abc');
      expect(restored.id, 'id1');
    });

    test('legacy record (no connectionId) round-trips with null connectionId',
        () {
      // A record persisted before L1d: JSON has no connectionId key.
      final legacy = AiConnection.fromJson(<String, dynamic>{
        'id': 'old1',
        'label': 'Old',
        'mcpPublicKeyB64': 'pub',
        'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
      });
      expect(legacy.connectionId, isNull);
      // And it serialises WITHOUT a connectionId key (minimal, byte-compat).
      expect(legacy.toJson().containsKey('connectionId'), isFalse);
    });
  });

  group('L1d deleteConnection → server revoke + HARD-FAIL', () {
    AiConnection record(String id, String label, {String? connectionId}) =>
        AiConnection(
          id: id,
          label: label,
          mcpPublicKeyB64: base64Encode(Uint8List.fromList(List.filled(32, 7))),
          createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
          connectionId: connectionId,
        );

    test('revoke SUCCEEDS (POST .../connections/:id/revoke, bearer auth) → the '
        'local record is deleted', () async {
      // Seed the SESSION JWT — revokeConnection reads it; without it the revoke
      // throws StateError before ever hitting the mock.
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'session-jwt-xyz');
      await SecureStorageService.instance.write(
        SecureStorageKeys.aiConnections,
        AiConnection.encodeList([
          record('id1', 'A', connectionId: 'conn-1'),
          record('id2', 'B'),
        ]),
      );

      http.Request? captured;
      final mock = MockClient((request) async {
        captured = request;
        // Server contract: fresh revoke → 200 { revoked:true, alreadyRevoked:false }.
        return http.Response(
          jsonEncode({'revoked': true, 'alreadyRevoked': false}),
          200,
        );
      });

      await service.deleteConnection('id1', httpClient: mock);

      // Revoke called with the right URL + bearer auth.
      expect(captured, isNotNull);
      expect(captured!.method, 'POST');
      expect(
        captured!.url.toString(),
        'https://cloud.fx.land/api/mcp/connections/conn-1/revoke',
      );
      expect(captured!.headers['Authorization'], 'Bearer session-jwt-xyz');

      // Record deleted.
      final raw = await SecureStorageService.instance
          .read(SecureStorageKeys.aiConnections);
      final decoded = (jsonDecode(raw!) as List).cast<Map<String, dynamic>>();
      expect(decoded.map((e) => e['id']), ['id2']);
    });

    test('HARD-FAIL: a non-2xx revoke does NOT delete the record and rethrows',
        () async {
      // The whole point of L1d hard-fail: a failed server revoke must leave the
      // connection in place (the AI may still hold a working refresh_token), and
      // the error must propagate so the UI can surface it.
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'session-jwt');
      await SecureStorageService.instance.write(
        SecureStorageKeys.aiConnections,
        AiConnection.encodeList([record('id1', 'A', connectionId: 'conn-1')]),
      );

      var called = false;
      final mock = MockClient((_) async {
        called = true;
        return http.Response('server boom', 500);
      });

      // Must THROW — the revoke failure is NOT swallowed.
      await expectLater(
        service.deleteConnection('id1', httpClient: mock),
        throwsA(isA<Exception>()),
      );

      expect(called, isTrue);
      // Record is STILL present — disconnect did not "succeed".
      final raw = await SecureStorageService.instance
          .read(SecureStorageKeys.aiConnections);
      final remaining = AiConnection.decodeList(raw);
      expect(remaining.map((c) => c.id), ['id1']);
    });

    test('HARD-FAIL: signed out (no session JWT) does NOT delete and throws '
        'StateError before any request', () async {
      // No session JWT seeded. This is the canonical silent-leak scenario: the
      // user thinks they disconnected while the AI keeps renewing. revokeConnection
      // throws StateError BEFORE issuing any request, so the record must remain.
      await SecureStorageService.instance.write(
        SecureStorageKeys.aiConnections,
        AiConnection.encodeList([record('id1', 'A', connectionId: 'conn-1')]),
      );

      var called = false;
      final mock = MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      });

      await expectLater(
        service.deleteConnection('id1', httpClient: mock),
        throwsA(isA<StateError>()),
      );

      expect(called, isFalse, reason: 'no JWT → no request is ever made');
      final raw = await SecureStorageService.instance
          .read(SecureStorageKeys.aiConnections);
      expect(AiConnection.decodeList(raw).map((c) => c.id), ['id1']);
    });

    test('IDEMPOTENT: already-revoked (200 { alreadyRevoked:true }) is treated '
        'as success → record deleted', () async {
      // Server contract (L1a app.ts): an already-revoked / unknown id still
      // returns HTTP 200 (alreadyRevoked:true) — there is NO 404. A retry after a
      // partial success must therefore succeed and remove the record, never stick.
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'session-jwt');
      await SecureStorageService.instance.write(
        SecureStorageKeys.aiConnections,
        AiConnection.encodeList([record('id1', 'A', connectionId: 'conn-1')]),
      );

      final mock = MockClient(
        (_) async => http.Response(
          jsonEncode({'revoked': true, 'alreadyRevoked': true}),
          200,
        ),
      );

      await service.deleteConnection('id1', httpClient: mock);

      final raw = await SecureStorageService.instance
          .read(SecureStorageKeys.aiConnections);
      expect(AiConnection.decodeList(raw), isEmpty);
    });

    test('legacy record without connectionId: revoke is NOT called, record '
        'deleted locally', () async {
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'session-jwt');
      await SecureStorageService.instance.write(
        SecureStorageKeys.aiConnections,
        AiConnection.encodeList([record('id1', 'A')]), // no connectionId
      );

      var called = false;
      final mock = MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      });

      await service.deleteConnection('id1', httpClient: mock);

      expect(called, isFalse, reason: 'no connectionId → no server revoke');
      final raw = await SecureStorageService.instance
          .read(SecureStorageKeys.aiConnections);
      expect(AiConnection.decodeList(raw), isEmpty);
    });
  });
}
