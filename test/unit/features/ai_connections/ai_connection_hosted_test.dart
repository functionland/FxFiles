// H5 — Hosted-connect ("connect a hosted AI") tests.
//
// These target the FFI-FREE seams of the hosted flow (the rust bridge `fula.*`
// is not loaded under `flutter test`, so `createHostedConnection` itself — which
// calls generateMcpKeypair / deriveWorkspaceSecret — is intentionally NOT
// exercised here, exactly like `createConnection` in the sibling service test):
//
//  1. buildCapabilityJson (PURE) — the EXACT 5-field Worker contract
//     (capability.ts `validateCapability`): keys + base64 values + key direction.
//  2. deliverCapability — POST {workerUrl}/capability with Bearer + body, 204
//     success, non-2xx fail-closed, trailing-slash normalization — via MockClient.
//  3. The hosted AiConnection record — persists + round-trips kind/workerUrl/
//     connectionId, carries NO secrets, and leaves legacy/local records intact.
//  4. deleteConnection on a HOSTED record — reuses the L1d hard-fail server
//     revoke (a hosted record has a connectionId, so the same path applies):
//     success → deleted; non-2xx → kept + throws.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/features/ai_connections/models/ai_connection.dart';
import 'package:fula_files/features/ai_connections/services/ai_connection_service.dart';
import 'package:fula_files/features/ai_connections/services/hosted_oauth_client.dart';

/// Wire contract of the flutter_secure_storage method channel — backed by an
/// in-memory map so the real SecureStorageService read/write paths run without a
/// native plugin (identical to the sibling ai_connection_service_test harness).
const _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  // ===========================================================================
  // 1. buildCapabilityJson — the Worker's validateCapability contract (H2).
  // ===========================================================================
  group('buildCapabilityJson (pure, FFI-free): the Worker 5-field contract', () {
    // Distinct 32-byte buffers so a field swap would be detectable.
    final workspaceSecret =
        Uint8List.fromList(List<int>.generate(32, (i) => i));
    final mcpSecret = Uint8List.fromList(List<int>.generate(32, (i) => 100 + i));

    test('emits EXACTLY the 5 capability keys the Worker accepts', () {
      final map = jsonDecode(
        service.buildCapabilityJson(
          endpoint: 'https://s3.cloud.fx.land',
          workspaceSecret: workspaceSecret,
          mcpSecretKey: mcpSecret,
          refreshToken: 'server-refresh-credential-xyz',
          refreshUrl: 'https://cloud.fx.land/api/mcp/tokens/refresh-connection',
        ),
      ) as Map<String, dynamic>;

      // EXACT key set — matches capability.ts validateCapability. NOTE: keys are
      // `workspace_secret` / `mcp_secret` (NO `_b64` suffix) and there is NO
      // owner_public_b64 and NO user_id (the Worker derives userId from OAuth).
      expect(
        map.keys.toSet(),
        {
          'workspace_secret',
          'mcp_secret',
          'refresh_token',
          'refresh_url',
          'endpoint',
        },
      );
      expect(map['endpoint'], 'https://s3.cloud.fx.land');
      expect(map['refresh_token'], 'server-refresh-credential-xyz');
      expect(
        map['refresh_url'],
        'https://cloud.fx.land/api/mcp/tokens/refresh-connection',
      );
      // The bundle-only keys must NOT leak into the capability contract.
      expect(map.containsKey('owner_public_b64'), isFalse);
      expect(map.containsKey('user_id'), isFalse);
      expect(map.containsKey('jwt'), isFalse);
      expect(map.containsKey('workspace_secret_b64'), isFalse);
    });

    test('secret values are base64 that decodes to 32 bytes; direction is '
        'mcp_secret=SECRET', () {
      final map = jsonDecode(
        service.buildCapabilityJson(
          endpoint: 'https://s3.cloud.fx.land',
          workspaceSecret: workspaceSecret,
          mcpSecretKey: mcpSecret,
          refreshToken: 'r',
          refreshUrl: 'https://cloud.fx.land/api/mcp/tokens/refresh-connection',
        ),
      ) as Map<String, dynamic>;

      for (final k in ['workspace_secret', 'mcp_secret']) {
        expect(base64Decode(map[k] as String).length, 32,
            reason: '$k must decode to 32 bytes');
      }
      // The mcp_secret carries the SECRET key bytes we passed (never the public).
      expect(base64Decode(map['workspace_secret'] as String), workspaceSecret);
      expect(base64Decode(map['mcp_secret'] as String), mcpSecret);
    });
  });

  // ===========================================================================
  // 2. deliverCapability — POST contract via an injected MockClient.
  // ===========================================================================
  group('deliverCapability (POST /capability, injected http.Client)', () {
    const capabilityJson = '{"endpoint":"https://s3.cloud.fx.land"}';

    test('POSTs to {workerUrl}/capability with Bearer + the body; 204 succeeds',
        () async {
      http.Request? captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response('', 204);
      });

      await service.deliverCapability(
        workerUrl: 'https://fula-mcp.alice.workers.dev',
        workerToken: 'worker-access-token-abc',
        capabilityJson: capabilityJson,
        httpClient: mock,
      );

      expect(captured, isNotNull);
      expect(captured!.method, 'POST');
      expect(
        captured!.url.toString(),
        'https://fula-mcp.alice.workers.dev/capability',
      );
      // The Worker access token is the Bearer (NOT the session JWT).
      expect(captured!.headers['Authorization'], 'Bearer worker-access-token-abc');
      expect(captured!.headers['Content-Type'], contains('application/json'));
      expect(captured!.body, capabilityJson);
    });

    test('normalizes a trailing slash on the Worker base URL', () async {
      http.Request? captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response('', 204);
      });

      await service.deliverCapability(
        workerUrl: 'https://fula-mcp.alice.workers.dev/',
        workerToken: 't',
        capabilityJson: capabilityJson,
        httpClient: mock,
      );

      // No `//capability`.
      expect(
        captured!.url.toString(),
        'https://fula-mcp.alice.workers.dev/capability',
      );
    });

    test('FAIL-CLOSED: a non-2xx Worker response throws', () async {
      final mock = MockClient(
        (_) async => http.Response('{"error":"invalid_token"}', 401),
      );
      await expectLater(
        service.deliverCapability(
          workerUrl: 'https://fula-mcp.alice.workers.dev',
          workerToken: 'bad',
          capabilityJson: capabilityJson,
          httpClient: mock,
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  // ===========================================================================
  // 3. The hosted AiConnection record — persistence round-trip + no secrets.
  // ===========================================================================
  group('hosted AiConnection record: round-trip + backward-compat', () {
    test('hosted record round-trips kind=hosted + workerUrl + connectionId', () {
      final original = AiConnection(
        id: 'id-h',
        label: 'Claude.ai',
        mcpPublicKeyB64: base64Encode(Uint8List.fromList(List.filled(32, 5))),
        createdAt: DateTime.utc(2026, 6, 23, 1, 2, 3),
        connectionId: 'conn-hosted-1',
        kind: AiConnectionKind.hosted,
        workerUrl: 'https://fula-mcp.alice.workers.dev',
      );

      final json = original.toJson();
      expect(json['kind'], 'hosted');
      expect(json['workerUrl'], 'https://fula-mcp.alice.workers.dev');
      expect(json['connectionId'], 'conn-hosted-1');

      final restored = AiConnection.fromJson(json);
      expect(restored.kind, AiConnectionKind.hosted);
      expect(restored.workerUrl, 'https://fula-mcp.alice.workers.dev');
      expect(restored.connectionId, 'conn-hosted-1');
      expect(restored.id, 'id-h');
    });

    test('a LOCAL record omits kind + workerUrl (byte-compatible key set)', () {
      // The existing "record JSON has EXACTLY id/label/mcpPublicKeyB64/createdAt"
      // test must stay green: a default (local) record adds NO new keys.
      final local = AiConnection(
        id: 'id-l',
        label: 'Claude Desktop',
        mcpPublicKeyB64: 'pub',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final json = local.toJson();
      expect(json.containsKey('kind'), isFalse);
      expect(json.containsKey('workerUrl'), isFalse);
      expect(json.keys.toSet(), {'id', 'label', 'mcpPublicKeyB64', 'createdAt'});

      // And it reads back as local.
      expect(AiConnection.fromJson(json).kind, AiConnectionKind.local);
      expect(AiConnection.fromJson(json).workerUrl, isNull);
    });

    test('a legacy record (no kind key) decodes as local', () {
      final legacy = AiConnection.fromJson(<String, dynamic>{
        'id': 'old',
        'label': 'Old',
        'mcpPublicKeyB64': 'pub',
        'createdAt': DateTime.utc(2026, 1, 1).toIso8601String(),
        'connectionId': 'conn-old',
      });
      expect(legacy.kind, AiConnectionKind.local);
      expect(legacy.workerUrl, isNull);
      expect(legacy.connectionId, 'conn-old');
    });

    test('persisted hosted record carries NO secret material', () async {
      final record = AiConnection(
        id: 'id-h',
        label: 'Claude.ai',
        mcpPublicKeyB64: base64Encode(Uint8List.fromList(List.filled(32, 5))),
        createdAt: DateTime.utc(2026, 6, 23),
        connectionId: 'conn-hosted-1',
        kind: AiConnectionKind.hosted,
        workerUrl: 'https://fula-mcp.alice.workers.dev',
      );
      await SecureStorageService.instance.write(
        SecureStorageKeys.aiConnections,
        AiConnection.encodeList([record]),
      );
      final raw = await SecureStorageService.instance
          .read(SecureStorageKeys.aiConnections);

      // No capability secret, no Worker token, no refresh token in the record.
      expect(raw, isNot(contains('workspace_secret')));
      expect(raw, isNot(contains('mcp_secret')));
      expect(raw, isNot(contains('refresh_token')));
      expect(raw, isNot(contains('"jwt"')));
      expect(raw, isNot(contains('access_token')));
      // The non-secret hosted fields ARE present.
      expect(raw, contains('"kind":"hosted"'));
      expect(raw, contains('fula-mcp.alice.workers.dev'));
    });
  });

  // ===========================================================================
  // 4. deleteConnection on a HOSTED record — reuses the L1d hard-fail revoke.
  // ===========================================================================
  group('disconnect a hosted connection: L1d hard-fail revoke is reused', () {
    AiConnection hosted(String id, {String? connectionId}) => AiConnection(
          id: id,
          label: 'Claude.ai',
          mcpPublicKeyB64: base64Encode(Uint8List.fromList(List.filled(32, 7))),
          createdAt: DateTime.utc(2026, 6, 23),
          connectionId: connectionId,
          kind: AiConnectionKind.hosted,
          workerUrl: 'https://fula-mcp.alice.workers.dev',
        );

    test('revoke SUCCEEDS → the hosted record is deleted', () async {
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'session-jwt-xyz');
      await SecureStorageService.instance.write(
        SecureStorageKeys.aiConnections,
        AiConnection.encodeList([hosted('id1', connectionId: 'conn-1')]),
      );

      http.Request? captured;
      final mock = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'revoked': true, 'alreadyRevoked': false}),
          200,
        );
      });

      await service.deleteConnection('id1', httpClient: mock);

      // Same L1d server-revoke endpoint + bearer auth as the local flow.
      expect(
        captured!.url.toString(),
        'https://cloud.fx.land/api/mcp/connections/conn-1/revoke',
      );
      expect(captured!.headers['Authorization'], 'Bearer session-jwt-xyz');
      final raw = await SecureStorageService.instance
          .read(SecureStorageKeys.aiConnections);
      expect(AiConnection.decodeList(raw), isEmpty);
    });

    test('HARD-FAIL preserved: a non-2xx revoke keeps the hosted record + throws',
        () async {
      await SecureStorageService.instance
          .write(SecureStorageKeys.jwtToken, 'session-jwt');
      await SecureStorageService.instance.write(
        SecureStorageKeys.aiConnections,
        AiConnection.encodeList([hosted('id1', connectionId: 'conn-1')]),
      );

      var called = false;
      final mock = MockClient((_) async {
        called = true;
        return http.Response('server boom', 500);
      });

      await expectLater(
        service.deleteConnection('id1', httpClient: mock),
        throwsA(isA<Exception>()),
      );
      expect(called, isTrue);
      // Hosted record is STILL present — a failed revoke is not a success.
      final raw = await SecureStorageService.instance
          .read(SecureStorageKeys.aiConnections);
      expect(AiConnection.decodeList(raw).map((c) => c.id), ['id1']);
      // And it is still the hosted record (kind preserved through the failure).
      expect(AiConnection.decodeList(raw).single.kind, AiConnectionKind.hosted);
    });
  });

  // ===========================================================================
  // 5. HostedOauthClient PKCE S256 — the one correctness bug to avoid (the
  //    challenge MUST be SHA256 over the verifier STRING's ASCII bytes). Pinned
  //    against the canonical RFC 7636 Appendix B test vector.
  // ===========================================================================
  group('HostedOauthClient.deriveS256Challenge (RFC 7636 §B vector)', () {
    test('matches the RFC 7636 Appendix B verifier→challenge vector', () {
      // RFC 7636, Appendix B.
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      const expectedChallenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
      expect(HostedOauthClient.deriveS256Challenge(verifier), expectedChallenge);
    });

    test('challenge is unpadded base64url (no =, no + or /)', () {
      final challenge = HostedOauthClient.deriveS256Challenge('any-verifier-123');
      expect(challenge.contains('='), isFalse);
      expect(challenge.contains('+'), isFalse);
      expect(challenge.contains('/'), isFalse);
    });
  });
}
