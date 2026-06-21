import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:fula_client/fula_client.dart' as fula;

import 'package:uuid/uuid.dart';

import 'package:fula_files/core/services/auth_core.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/utils/user_id.dart';
import 'package:fula_files/features/ai_connections/models/ai_connection.dart';

/// Result of generating a fresh MCP X25519 keypair.
typedef McpKeypair = ({Uint8List publicKey, Uint8List secretKey});

/// P13 — "AI Connections": builds the MCP **connection bundle** and persists the
/// non-secret pairing record.
///
/// The bundle JSON is the MCP's `CapabilityBundle` wire contract
/// (`fula-api/crates/fula-mcp/src/capability.rs`). FxFiles shows it ONCE for the
/// user to copy into their AI client; only the public key + record are persisted
/// (see [AiConnection]).
///
/// Testable seams (no FFI mocks — FFI is assumed correct):
///  - [buildBundleJson] is PURE: raw bytes + strings in, contract JSON out.
///  - [mintScopedJwt] takes an injected [http.Client].
class AiConnectionService {
  AiConnectionService._();
  static final AiConnectionService instance = AiConnectionService._();

  /// Cryptographically-secure RNG for keypair generation.
  final Random _random = Random.secure();

  /// Generate a fresh MCP X25519 keypair.
  ///
  /// Mirrors `sharing_service.dart`: 32 bytes from `Random.secure()` ARE the
  /// X25519 *secret* key; the *public* key is derived from it via FFI. The MCP
  /// (capability.rs) expects `mcp_secret_b64` = base64(secretKey) and treats the
  /// public key as the connection identity.
  ///
  /// Returns `(publicKey, secretKey)` as raw 32-byte buffers. Caller decides
  /// what to do with each: only the SECRET goes into the one-time bundle; only
  /// the PUBLIC is persisted in the record.
  Future<McpKeypair> generateMcpKeypair() async {
    final secretKey = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      secretKey[i] = _random.nextInt(256);
    }
    final publicKey = Uint8List.fromList(
      await fula.derivePublicKeyFromSecret(secretKeyBytes: secretKey.toList()),
    );
    return (publicKey: publicKey, secretKey: secretKey);
  }

  /// BLAKE3 context label for the AI-workspace secret. Load-bearing: the MCP
  /// derives the SAME label so both sides agree on the workspace key.
  static const String workspaceSecretContext = 'fula:ai-workspace-secret:v1';

  /// Derive the 32-byte AI-workspace secret from the user's master KEK.
  ///
  /// This is a ONE-WAY derivation: `BLAKE3_derive_key(context, KEK)`. The MCP
  /// receives only the derived secret (`workspace_secret_b64`) and therefore
  /// CANNOT recover the master KEK from it — the workspace is cryptographically
  /// isolated from the rest of the user's encrypted data. Mirrors the
  /// `auth_core.deriveBucketsIndexKeys` pattern (blake3DeriveKey over the KEK).
  ///
  /// Throws [StateError] if the user is signed out (no KEK available).
  Future<Uint8List> deriveWorkspaceSecret() async {
    final kek = await AuthService.instance.getEncryptionKey();
    if (kek == null) {
      throw StateError(
        'No encryption key available. Please sign in before creating an AI connection.',
      );
    }
    return Uint8List.fromList(
      await fula.blake3DeriveKey(
        context: workspaceSecretContext,
        input: kek,
      ),
    );
  }

  /// The owner's X25519 **public** key — the same sharing/recipient public key
  /// FxFiles derives from the user's secret (`AuthService.getPublicKey()`, which
  /// `sharing_service` uses as `ownerPublicKey`). Goes into the bundle as
  /// `owner_public_b64`.
  ///
  /// Throws [StateError] if the user is signed out.
  Future<Uint8List> ownerPublicKey() async {
    final pub = await AuthService.instance.getPublicKey();
    if (pub == null) {
      throw StateError(
        'Owner public key not available. Please sign in before creating an AI connection.',
      );
    }
    return pub;
  }

  /// Mint a short-lived, scoped MCP gateway JWT via P11's issuer endpoint
  /// (`POST {issuerBaseUrl}/api/mcp/tokens`).
  ///
  /// CONTRACT (pinning-webui `mcpIssueAndRespond` / `mintMcpToken`): the request
  /// is authenticated with the user's SESSION JWT as a bearer token; the minted
  /// token's scope is derived server-side from that session's `sub` (the MCP
  /// public key is NOT sent — the server ignores it). The body is JSON; the only
  /// honoured field is an optional `ttlSeconds` (clamped server-side to
  /// [60, 86400]). The response is JSON `{ token, jti, expiresAt, tokenType,
  /// scope }`; the bundle's `jwt` is the `token` field.
  ///
  /// [httpClient] is injected for tests (mirrors `issuer_client.dart`).
  /// Throws [StateError] if there is no session JWT; throws [Exception] on a
  /// non-2xx response or a malformed body.
  Future<String> mintScopedJwt({http.Client? httpClient, int? ttlSeconds}) async {
    final sessionJwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    if (sessionJwt == null || sessionJwt.isEmpty) {
      throw StateError(
        'No session token. Please sign in before creating an AI connection.',
      );
    }
    final baseUrl = await AuthCore.issuerBaseUrl();
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .post(
            Uri.parse('$baseUrl/api/mcp/tokens'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': 'Bearer $sessionJwt',
            },
            // The MCP pubkey is intentionally NOT sent: the server scopes the
            // token to the session `sub`. Only ttlSeconds is honoured.
            body: jsonEncode({
              if (ttlSeconds != null) 'ttlSeconds': ttlSeconds,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'Failed to mint MCP token: ${response.statusCode} - ${response.body}',
        );
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final token = decoded['token'];
      if (token is! String || token.isEmpty) {
        throw Exception('MCP token response missing "token" field.');
      }
      return token;
    } finally {
      // Only close clients we created; never close an injected (test) client.
      if (httpClient == null) client.close();
    }
  }

  /// Build the MCP connection bundle JSON string. PURE (no I/O): every value is
  /// passed in, so this is fully unit-testable without FFI or the network.
  ///
  /// The shape MUST match the MCP's `CapabilityBundleJson`
  /// (`fula-api/crates/fula-mcp/src/capability.rs`) — field names + base64 are
  /// load-bearing (Rust `#[derive(Deserialize)]`). Required fields:
  ///   endpoint, jwt, workspace_secret_b64, mcp_secret_b64, owner_public_b64.
  /// Optional: user_id, storage_api_url.
  ///
  /// NOTE the key direction (the one catastrophic swap to avoid):
  ///   mcp_secret_b64  = base64(MCP **secret** key)
  ///   owner_public_b64 = base64(owner **public** key)
  String buildBundleJson({
    required String endpoint,
    required String jwt,
    required Uint8List workspaceSecret,
    required Uint8List mcpSecretKey,
    required Uint8List ownerPublicKey,
    String? userId,
    String? storageApiUrl,
  }) {
    final bundle = <String, dynamic>{
      'endpoint': endpoint,
      'jwt': jwt,
      'workspace_secret_b64': base64Encode(workspaceSecret),
      // base64 of the 32-byte MCP X25519 SECRET key (NOT the public key).
      'mcp_secret_b64': base64Encode(mcpSecretKey),
      // base64 of the 32-byte owner X25519 PUBLIC key.
      'owner_public_b64': base64Encode(ownerPublicKey),
      if (userId != null && userId.isNotEmpty) 'user_id': userId,
      if (storageApiUrl != null && storageApiUrl.isNotEmpty)
        'storage_api_url': storageApiUrl,
    };
    return jsonEncode(bundle);
  }

  /// Resolve the S3 gateway endpoint for the bundle: the user's configured
  /// gateway override, else the default S3 gateway.
  Future<String> _resolveEndpoint() async {
    final stored = await SecureStorageService.instance
        .read(SecureStorageKeys.apiGatewayUrl);
    if (stored != null && stored.isNotEmpty) return stored;
    return AuthCore.defaultS3GatewayUrl;
  }

  /// Orchestrate steps 2–5 and return the one-time bundle JSON string.
  ///
  /// Generates a fresh MCP keypair, derives the workspace secret + owner public
  /// key, mints the scoped JWT, builds the contract JSON, then persists ONLY the
  /// NON-secret record (mcp public key + label + createdAt). The bundle (with
  /// its secrets) is returned to the caller to show ONCE and is never stored.
  Future<String> createConnection({required String label}) async {
    final keypair = await generateMcpKeypair();
    final workspaceSecret = await deriveWorkspaceSecret();
    final ownerPub = await ownerPublicKey();
    final jwt = await mintScopedJwt();
    final endpoint = await _resolveEndpoint();
    final storageApiUrl = await AuthCore.issuerBaseUrl();
    // FxFiles' canonical per-user id (sha256(base64(pubkey))[..16]). Reused
    // verbatim so it matches what the MCP stamps onto tag metadata and what
    // FxFiles derives elsewhere — do NOT re-roll the hash/slice here.
    final userId = await deriveUserId();

    final bundle = buildBundleJson(
      endpoint: endpoint,
      jwt: jwt,
      workspaceSecret: workspaceSecret,
      mcpSecretKey: keypair.secretKey,
      ownerPublicKey: ownerPub,
      userId: userId,
      storageApiUrl: storageApiUrl,
    );

    // Persist ONLY the record — public key + label + id + createdAt. No secrets.
    final record = AiConnection(
      id: const Uuid().v4(),
      label: label,
      mcpPublicKeyB64: base64Encode(keypair.publicKey),
      createdAt: DateTime.now(),
    );
    final existing = await listConnections();
    await _persist([...existing, record]);

    return bundle;
  }

  /// List the persisted (non-secret) connection records.
  Future<List<AiConnection>> listConnections() async {
    final raw =
        await SecureStorageService.instance.read(SecureStorageKeys.aiConnections);
    return AiConnection.decodeList(raw);
  }

  /// Delete a persisted connection record by id. (Does not revoke the remote
  /// token — that lapses on its short exp.)
  Future<void> deleteConnection(String id) async {
    final remaining =
        (await listConnections()).where((c) => c.id != id).toList();
    await _persist(remaining);
  }

  Future<void> _persist(List<AiConnection> connections) async {
    await SecureStorageService.instance.write(
      SecureStorageKeys.aiConnections,
      AiConnection.encodeList(connections),
    );
  }
}
