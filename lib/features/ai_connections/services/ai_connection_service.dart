import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:fula_client/fula_client.dart' as fula;

import 'package:uuid/uuid.dart';

import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/utils/user_id.dart';
import 'package:fula_files/features/ai_connections/models/ai_connection.dart';

/// Result of generating a fresh MCP X25519 keypair.
typedef McpKeypair = ({Uint8List publicKey, Uint8List secretKey});

/// Result of minting a CONNECTION token (L1d) — the connection-aware variant of
/// [AiConnectionService.mintScopedJwt].
///
/// Beyond the scoped gateway `jwt`, a connection mint (one that sends
/// `mcp_pub_b64`) returns two extra credentials the server registered for this
/// connection:
///   - [refreshToken]: a SEPARATE random refresh credential (NOT the jwt, NOT
///     the user's session JWT). The MCP later POSTs it to the issuer's
///     `/api/mcp/tokens/refresh-connection` to auto-renew its scoped jwt. It is
///     placed in the one-time bundle as `refresh_token` and is NEVER persisted.
///   - [connectionId]: the server's connection uuid. Persisted in the
///     [AiConnection] record (non-secret) so disconnect can revoke the
///     connection server-side.
///
/// Both are NULLABLE: an older issuer that doesn't understand `mcp_pub_b64`
/// returns only `token`, so the bundle simply omits the refresh fields and the
/// record stores a null connectionId (the legacy expiry-bound behaviour).
typedef McpConnectionToken = ({
  String jwt,
  String? refreshToken,
  String? connectionId,
  int? expiresAt,
});

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
    // Web-safe: read the KEK directly from secure storage (the same place the
    // native AuthService.getEncryptionKey reads it), avoiding the native FFI
    // auth layer so this compiles for web.
    final storedKek = await SecureStorageService.instance.read(
      SecureStorageKeys.encryptionKey,
    );
    final kek =
        (storedKek == null || storedKek.isEmpty) ? null : base64Decode(storedKek);
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
    // Web-safe: the native AuthService.getPublicKey() just delegates to
    // FulaApiService.getPublicKey() (the fula-client keypair pubkey) — the
    // SAME recipient key, byte-identical on native, and web-compilable.
    if (!FulaApiService.instance.isConfigured) {
      throw StateError(
        'Owner public key not available. Please sign in before creating an AI connection.',
      );
    }
    return FulaApiService.instance.getPublicKey();
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
    final baseUrl = await _issuerBaseUrl();
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

  /// Mint a scoped gateway JWT AND register a server-side **connection** (L1d).
  ///
  /// Same endpoint + bearer-session-JWT auth as [mintScopedJwt], but the body
  /// additionally carries `mcp_pub_b64` = base64 of THIS connection's X25519
  /// PUBLIC key (NOT the secret). On a server that understands it, that
  /// registers a connection and the JSON response includes, beyond
  /// `token`/`jti`/`expiresAt`, a separate `refreshToken` credential and a
  /// `connectionId` uuid (CONTRACT: pinning-service `feat/mcp-connection-lifecycle`).
  ///
  /// Returns an [McpConnectionToken]. `refreshToken`/`connectionId` are NULLABLE
  /// (only `token` is required) so an older issuer that ignores `mcp_pub_b64`
  /// still works — the caller then omits the bundle's refresh fields and stores
  /// a null connectionId.
  ///
  /// [httpClient] is injected for tests. Throws [StateError] with no session
  /// JWT; throws [Exception] on a non-2xx response or a missing `token`.
  Future<McpConnectionToken> mintConnectionToken({
    required String mcpPublicKeyB64,
    http.Client? httpClient,
    int? ttlSeconds,
  }) async {
    final sessionJwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    if (sessionJwt == null || sessionJwt.isEmpty) {
      throw StateError(
        'No session token. Please sign in before creating an AI connection.',
      );
    }
    final baseUrl = await _issuerBaseUrl();
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
            // `mcp_pub_b64` registers the connection server-side and unlocks the
            // refreshToken + connectionId in the response. It is the connection's
            // PUBLIC key (base64) — never the secret.
            body: jsonEncode({
              'mcp_pub_b64': mcpPublicKeyB64,
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
      final refreshToken = decoded['refreshToken'];
      final connectionId = decoded['connectionId'];
      final expiresAt = decoded['expiresAt'];
      return (
        jwt: token,
        refreshToken: (refreshToken is String && refreshToken.isNotEmpty)
            ? refreshToken
            : null,
        connectionId: (connectionId is String && connectionId.isNotEmpty)
            ? connectionId
            : null,
        expiresAt: expiresAt is int ? expiresAt : null,
      );
    } finally {
      // Only close clients we created; never close an injected (test) client.
      if (httpClient == null) client.close();
    }
  }

  /// Revoke a server-side MCP connection by its [connectionId] (L1d).
  ///
  /// POSTs to `{issuerBase}/api/mcp/connections/:id/revoke` with the user's
  /// SESSION JWT as bearer auth (same auth as the mint). With gateway revocation
  /// enforcement enabled the connection's access is cut within ~30s; otherwise
  /// it lapses at the scoped token's expiry at the latest.
  ///
  /// IDEMPOTENT by server contract (L1a `app.ts`): the endpoint returns HTTP
  /// **200** `{ revoked: true, alreadyRevoked: <bool> }` for ANY id the caller
  /// owns — freshly revoked OR already revoked. The DB update is
  /// `... WHERE user_id=? AND id=? AND NOT revoked`, so an already-revoked id
  /// (and an unknown / not-owned id) matches zero rows yet still 200s with
  /// `alreadyRevoked: true`. There is **no 404 path**. A retry after a partial
  /// success therefore 200s and is SUCCESS — disconnect never gets stuck.
  ///
  /// HARD-FAIL contract: this throws on a genuine failure so the caller keeps
  /// the local record (the AI may still have a working refresh_token):
  ///   - [StateError] when there is no session JWT (signed out) — thrown before
  ///     any request, so an offline/signed-out disconnect never silently drops
  ///     the record;
  ///   - [Exception] on a non-2xx response (401/5xx) or a network/timeout error.
  /// A 2xx (including the already-revoked 200) returns normally = success.
  ///
  /// [httpClient] is injected for tests.
  Future<void> revokeConnection(
    String connectionId, {
    http.Client? httpClient,
  }) async {
    final sessionJwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    if (sessionJwt == null || sessionJwt.isEmpty) {
      throw StateError('No session token; cannot revoke MCP connection.');
    }
    final baseUrl = await _issuerBaseUrl();
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .post(
            Uri.parse(
              '$baseUrl/api/mcp/connections/${Uri.encodeComponent(connectionId)}/revoke',
            ),
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Bearer $sessionJwt',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'Failed to revoke MCP connection: ${response.statusCode} - ${response.body}',
        );
      }
    } finally {
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
  /// Optional: user_id, storage_api_url, refresh_token, refresh_url.
  ///
  /// NOTE the key direction (the one catastrophic swap to avoid):
  ///   mcp_secret_b64  = base64(MCP **secret** key)
  ///   owner_public_b64 = base64(owner **public** key)
  ///
  /// L1d connection-lifecycle fields (snake_case, read by the MCP at
  /// `fula-mcp` — keys `refresh_token` + `refresh_url`):
  ///   - [refreshToken]: the server's SEPARATE refresh credential (the
  ///     `refreshToken` from the connection mint — NOT the `jwt`/session JWT).
  ///   - [refreshUrl]: `{issuerBase}/api/mcp/tokens/refresh-connection`.
  /// Both are emitted ONLY when [refreshToken] is non-null/non-empty, so an
  /// older mint (no refresh credential) yields a backward-compatible bundle.
  String buildBundleJson({
    required String endpoint,
    required String jwt,
    required Uint8List workspaceSecret,
    required Uint8List mcpSecretKey,
    required Uint8List ownerPublicKey,
    String? userId,
    String? storageApiUrl,
    String? refreshToken,
    String? refreshUrl,
  }) {
    final hasRefresh = refreshToken != null && refreshToken.isNotEmpty;
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
      // The server's separate refresh credential + the refresh endpoint, so the
      // MCP can auto-renew its scoped jwt. Omitted together when absent.
      if (hasRefresh) 'refresh_token': refreshToken,
      if (hasRefresh && refreshUrl != null && refreshUrl.isNotEmpty)
        'refresh_url': refreshUrl,
    };
    return jsonEncode(bundle);
  }

  /// Resolve the S3 gateway endpoint for the bundle: the user's configured
  /// gateway override, else the default S3 gateway.
  Future<String> _resolveEndpoint() async {
    final stored = await SecureStorageService.instance
        .read(SecureStorageKeys.apiGatewayUrl);
    if (stored != null && stored.isNotEmpty) return stored;
    return 'https://s3.cloud.fx.land';
  }

  /// Web-safe inline of AuthCore.issuerBaseUrl() (the billing-server override,
  /// else the cloud.fx.land default) — avoids importing the FFI auth_core.
  Future<String> _issuerBaseUrl() async {
    final stored = await SecureStorageService.instance.read(
      SecureStorageKeys.billingServerUrl,
    );
    if (stored != null && stored.isNotEmpty) return stored;
    return 'https://cloud.fx.land';
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
    final endpoint = await _resolveEndpoint();
    final issuerBase = await _issuerBaseUrl();
    // FxFiles' canonical per-user id (sha256(base64(pubkey))[..16]). Reused
    // verbatim so it matches what the MCP stamps onto tag metadata and what
    // FxFiles derives elsewhere — do NOT re-roll the hash/slice here.
    final userId = await deriveUserId();

    // Mint the scoped jwt AND register the connection: send mcp_pub_b64 (the
    // connection's PUBLIC key) so the server returns the separate refreshToken
    // credential + the connectionId.
    final minted = await mintConnectionToken(
      mcpPublicKeyB64: base64Encode(keypair.publicKey),
    );

    final bundle = buildBundleJson(
      endpoint: endpoint,
      jwt: minted.jwt,
      workspaceSecret: workspaceSecret,
      mcpSecretKey: keypair.secretKey,
      ownerPublicKey: ownerPub,
      userId: userId,
      storageApiUrl: issuerBase,
      // The server's separate refresh credential (NOT the jwt) + the refresh
      // endpoint, so the MCP can auto-renew. Omitted by buildBundleJson when
      // refreshToken is null (older issuer).
      refreshToken: minted.refreshToken,
      refreshUrl: '$issuerBase/api/mcp/tokens/refresh-connection',
    );

    // Persist ONLY the non-secret record — public key + label + id + createdAt +
    // the server connectionId (for revoke). NO secrets (no refreshToken/jwt).
    final record = AiConnection(
      id: const Uuid().v4(),
      label: label,
      mcpPublicKeyB64: base64Encode(keypair.publicKey),
      createdAt: DateTime.now(),
      connectionId: minted.connectionId,
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

  /// Disconnect: revoke the connection server-side (L1d), then delete the local
  /// record by [id].
  ///
  /// HARD-FAIL (security-correctness): the local record is removed ONLY when the
  /// AI's access has actually been cut server-side. The honest control flow:
  ///
  ///   - Record HAS a [AiConnection.connectionId]: POST the server revoke
  ///     (`/api/mcp/connections/:id/revoke`, session-JWT auth) FIRST.
  ///       * SUCCESS (2xx — incl. the idempotent already-revoked 200) → delete
  ///         the local record. Access is cut within ~30s where the gateway
  ///         enforces revocation; the AI cannot self-renew once revoked.
  ///       * FAILURE (signed out → [StateError]; non-2xx / network / timeout →
  ///         [Exception]) → do NOT delete; **rethrow**. The connection stays in
  ///         the list so the UI can surface it: an offline/failed disconnect
  ///         must not silently leave the AI with a working refresh_token while
  ///         the user believes they disconnected.
  ///   - Record has NO connectionId (legacy / pre-L1d / older issuer): there is
  ///     no server connection to revoke, so delete locally. Such a record's
  ///     access is bound to its scoped token's expiry — that's the honest
  ///     behaviour for a record that never registered a server connection.
  ///
  /// Idempotency: a retry after a partial success is safe — the server returns a
  /// 2xx (already-revoked) which this treats as success (see [revokeConnection]),
  /// so a stuck-forever disconnect is impossible for a caller who can
  /// authenticate.
  ///
  /// [httpClient] is injected for tests.
  Future<void> deleteConnection(String id, {http.Client? httpClient}) async {
    final connections = await listConnections();
    AiConnection? target;
    for (final c in connections) {
      if (c.id == id) {
        target = c;
        break;
      }
    }

    final connectionId = target?.connectionId;
    if (connectionId != null && connectionId.isNotEmpty) {
      // HARD-FAIL: revoke must succeed before we drop the local record. Any
      // failure (StateError when signed out, Exception on non-2xx/network)
      // propagates so the record is kept and the UI surfaces it.
      await revokeConnection(connectionId, httpClient: httpClient);
    }

    final remaining = connections.where((c) => c.id != id).toList();
    await _persist(remaining);
  }

  Future<void> _persist(List<AiConnection> connections) async {
    await SecureStorageService.instance.write(
      SecureStorageKeys.aiConnections,
      AiConnection.encodeList(connections),
    );
  }
}
