import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fula_files/core/services/secure_storage_service.dart';

/// Result of minting a CONNECTION token (L1d): the scoped gateway `jwt` plus the
/// two connection credentials the server registers when the mint body carries
/// `mcp_pub_b64`.
///
///   - [refreshToken]: a SEPARATE random refresh credential (NOT the jwt, NOT
///     the user's session JWT). The AI later POSTs it to the issuer's
///     `/api/mcp/tokens/refresh-connection` to auto-renew its scoped jwt. It is
///     placed in the one-time capability as `refresh_token` and is NEVER
///     persisted.
///   - [connectionId]: the server's connection uuid — NON-SECRET. The collab
///     pairing flow uses it to authorize a group for this connection (and it can
///     be used to revoke the connection server-side).
///
/// Both are NULLABLE: an older issuer that doesn't understand `mcp_pub_b64`
/// returns only `token`, so the caller then omits the capability's refresh
/// fields and gets a null connectionId (the legacy expiry-bound behaviour).
typedef McpConnectionToken = ({
  String jwt,
  String? refreshToken,
  String? connectionId,
  int? expiresAt,
});

/// Mints an MCP **connection** token for the collaboration "Share with AI Agent"
/// flow.
///
/// This is the shared infrastructure the collaboration pivot reuses: it POSTs to
/// `{issuerBase}/api/mcp/tokens` with the user's session JWT + `mcp_pub_b64` (the
/// AI agent's X25519 PUBLIC key, base64) to register the AI's connection
/// server-side and return the scoped jwt plus the connection's `refreshToken` +
/// `connectionId`.
///
/// Kept as a small, self-contained collab-owned helper (rather than depending on
/// the removed bespoke `AiConnectionService`) so the collaboration pairing path
/// compiles independently of the bespoke AI-workspace feature.
class McpConnectionMinter {
  McpConnectionMinter._();
  static final McpConnectionMinter instance = McpConnectionMinter._();

  /// Web-safe issuer base (billing-server override, else cloud.fx.land) — mirrors
  /// `CollabAiPairingService._issuerBaseUrl` so the mint/authorize/refresh all
  /// target one origin.
  Future<String> _issuerBaseUrl() async {
    final stored = await SecureStorageService.instance
        .read(SecureStorageKeys.billingServerUrl);
    if (stored != null && stored.isNotEmpty) return stored;
    return 'https://cloud.fx.land';
  }

  /// Mint a scoped gateway JWT AND register a server-side **connection** (L1d).
  ///
  /// POSTs `{mcp_pub_b64, ttlSeconds?}` to `{issuerBase}/api/mcp/tokens` with the
  /// user's SESSION JWT as bearer auth. `mcp_pub_b64` is the connection's X25519
  /// PUBLIC key (base64) — never the secret — and registering it unlocks the
  /// `refreshToken` + `connectionId` in the response (CONTRACT: pinning-service
  /// `feat/mcp-connection-lifecycle`).
  ///
  /// Returns an [McpConnectionToken]. `refreshToken`/`connectionId` are NULLABLE
  /// (only `token` is required) so an older issuer that ignores `mcp_pub_b64`
  /// still works — the caller then omits the capability's refresh fields and
  /// stores a null connectionId.
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
}
