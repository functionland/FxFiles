import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:http/http.dart' as http;

import 'package:fula_files/core/models/collaboration_group.dart';
import 'package:fula_files/core/platform/frb_u64.dart';
import 'package:fula_files/core/services/collaboration_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/share_link_builder.dart';
import 'package:fula_files/core/utils/user_id.dart';
import 'package:fula_files/features/sharing/services/mcp_connection_minter.dart';

/// Official hosted MCP Worker base (Method-2 hosted transport).
const String kHostedMcpBaseUrl = 'https://mcp.cloud.fx.land';

/// The npm package the desktop/local-stdio transport launches via `npx`.
const String kFulaMcpNpmPackage = '@functionland/fula-mcp';

/// Signature of the function that wraps the group's 32-byte **link secret** as a
/// `wrapped_link_secret` string for an AI agent's X25519 public key.
///
/// PRODUCTION IMPL ([CollabAiPairingService.realWrapper]) calls the published
/// `fula_client` 0.6.18 binding
/// `wrapSecretForRecipient(secret, recipientPublicKey, pathScope, expiresInSeconds)
/// -> ShareToken JSON`. Tests inject a fake via [pairGroupWithAi].
///
/// CONTRACT (the consumer is `fula-api/crates/fula-mcp/src/capability.rs`): the
/// returned string MUST be a `serde_json` serialization of a fula **v5
/// `ShareToken`** (`fula_crypto::sharing::ShareToken`) whose wrapped DEK *is* the
/// 32-byte [linkSecret], addressed to [recipientPublicKey]. The MCP recovers it
/// with `ShareRecipient::accept_share(token) -> accepted.dek` (identity.rs
/// `accept_link_secret`).
///
/// The v5 wrap is fula-INTERNAL HPKE with a canonical, length-prefixed binary
/// AAD binding every token field + the recipient public key
/// (`fula_crypto::sharing::build_share_token_aad`, domain-tag
/// `b"fula:v5:share-token|"`); the sender keypair is generated EPHEMERALLY inside
/// fula-crypto (the AAD binds the RECIPIENT key, not the sender). It is NOT a
/// generic ECIES and MUST NOT be hand-reimplemented — the consumer rejects any
/// non-v5 shape (and the strict AAD makes a byte-imperfect clone fail).
///
/// [expiresInSeconds] is a **TTL — seconds-from-now**, matching the binding's
/// `expires_in_seconds` (NOT an absolute Unix timestamp). `null` ⇒ never expires.
typedef CollabLinkSecretWrapper = Future<String> Function({
  required Uint8List linkSecret,
  required Uint8List recipientPublicKey,
  required String pathScope,
  int? expiresInSeconds,
});

/// Signals that the cryptographic wrap of the link secret cannot be produced, so
/// the caller should fall back to the Method-1 collaboration LINK.
///
/// As of `fula_client` 0.6.18 the wrap IS supported — the default wrapper
/// ([CollabAiPairingService.realWrapper]) calls `wrapSecretForRecipient`. This
/// type is retained as a defensive seam: an injected wrapper (or a hypothetical
/// future binding-less build) may still throw it, and the "Share with AI Agent"
/// dialog catches it to offer the collaboration link instead of a hard error.
class CollabPairingUnsupported implements Exception {
  final String message;
  CollabPairingUnsupported(this.message);
  @override
  String toString() => 'CollabPairingUnsupported: $message';
}

/// General pairing failure (group not found, not signed in, HTTP error, …).
class CollabPairingException implements Exception {
  final String message;
  CollabPairingException(this.message);
  @override
  String toString() => 'CollabPairingException: $message';
}

/// Result of authorizing groups for a connection (server PR #69 contract):
/// `POST /api/mcp/connections/:id/collab-groups {groupIds} -> {collabToken, …}`.
typedef CollabAuthorizeResult = ({
  String collabToken,
  String? jti,
  int? expiresAt,
  List<String> groupIds,
});

/// The output of a successful pairing: the capability JSON plus both
/// platform-shaped MCP client configs and the Method-1 fallback link.
class CollabAiPairing {
  /// The MCP capability JSON (the `FULA_MCP_CAPABILITY` contract). Always built
  /// (it is the canonical artifact); the two configs below embed it.
  final String capabilityJson;

  /// Desktop/Windows local-stdio MCP client config (launches the npm package).
  final String localStdioConfig;

  /// Mobile/web hosted-Worker MCP client config (points at `mcp.cloud.fx.land`).
  final String hostedConfig;

  /// The existing collaboration LINK (Method 1) — a working fallback that already
  /// carries the link secret in its `sk` fragment, so a web AI agent can consume
  /// the group without the wrapped-secret binding.
  final String fallbackCollabUrl;

  const CollabAiPairing({
    required this.capabilityJson,
    required this.localStdioConfig,
    required this.hostedConfig,
    required this.fallbackCollabUrl,
  });
}

/// Pairs a collaboration group with an AI agent (MCP) — "Share with AI Agent".
///
/// Method 2 of the collaboration flow: the AI presents its STABLE X25519 identity
/// as a `FULA-…` share id; the owner authorizes the group for the AI's connection
/// and hands it a per-group capability. The AI recovers the group link secret from
/// `wrapped_link_secret` and thereafter reads/writes the group exactly like any
/// human collaborator (bidirectional — the AI can see the group's files and add to
/// it; it CANNOT hard-delete — server PR #69 keeps DELETE off collab tokens).
class CollabAiPairingService {
  CollabAiPairingService._();
  static final CollabAiPairingService instance = CollabAiPairingService._();

  /// The production wrapper: wraps the group's 32-byte [linkSecret] for the AI
  /// agent's [recipientPublicKey] as a fula **v5 ShareToken** JSON via the
  /// published `fula_client` 0.6.18 binding [fula.wrapSecretForRecipient]. This is
  /// the default for [pairGroupWithAi]; tests inject a fake.
  ///
  /// Fail-closed: a non-32-byte secret or recipient key, or a non-positive TTL, is
  /// rejected with [CollabPairingException] BEFORE the FFI call. (The Rust side
  /// also rejects non-32-byte inputs; this guard just yields a clean message and
  /// never reaches FFI in the unit-test environment.) The wrapped secret is the
  /// EXACT 32 link-secret bytes — the MCP recovers them verbatim via
  /// `accept_link_secret`.
  static Future<String> _realWrap({
    required Uint8List linkSecret,
    required Uint8List recipientPublicKey,
    required String pathScope,
    int? expiresInSeconds,
  }) async {
    if (linkSecret.length != 32) {
      throw CollabPairingException(
        'Internal error: group link secret is ${linkSecret.length} bytes '
        '(need 32); refusing to wrap.',
      );
    }
    if (recipientPublicKey.length != 32) {
      throw CollabPairingException(
        'AI agent id decodes to ${recipientPublicKey.length} bytes (need 32).',
      );
    }
    if (expiresInSeconds != null && expiresInSeconds <= 0) {
      throw CollabPairingException('Collaboration has expired.');
    }
    return fula.wrapSecretForRecipient(
      secret: linkSecret,
      recipientPublicKey: recipientPublicKey,
      pathScope: pathScope,
      // i64 seconds-from-now via FRB: int natively, BigInt on web.
      expiresInSeconds: intToFrbU64(expiresInSeconds),
    );
  }

  /// The production wrapper, exposed so tests can assert its fail-closed input
  /// validation. The real binding's happy path is FFI (proven by
  /// `flutter build web`), not exercised under `flutter test`.
  @visibleForTesting
  static CollabLinkSecretWrapper get realWrapper => _realWrap;

  /// Collapse whitespace + truncate a server response body so an error message
  /// never renders multi-line / attacker-influenced text at full length.
  static String _clip(String s, [int max = 200]) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= max ? one : '${one.substring(0, max)}…';
  }

  /// Web-safe issuer base (billing-server override, else cloud.fx.land) — mirrors
  /// `McpConnectionMinter` so the mint/authorize/refresh all target one origin.
  Future<String> _issuerBaseUrl() async {
    final stored = await SecureStorageService.instance
        .read(SecureStorageKeys.billingServerUrl);
    if (stored != null && stored.isNotEmpty) return stored;
    return 'https://cloud.fx.land';
  }

  /// Resolve the outgoing collaboration for [groupId] (must be owner-side — only
  /// the owner holds the link secret needed to wrap it for the AI).
  Future<OutgoingCollaboration> _requireOutgoing(String groupId) async {
    final collabs =
        await CollaborationService.instance.getOutgoingCollaborations();
    OutgoingCollaboration? match;
    for (final c in collabs) {
      if (c.id == groupId) {
        match = c;
        break;
      }
    }
    if (match == null) {
      throw CollabPairingException(
        'Only the group owner can share it with an AI agent.',
      );
    }
    if (match.linkSecretKey == null) {
      throw CollabPairingException('Group is missing its link secret.');
    }
    if (match.group.isExpired) {
      throw CollabPairingException('Collaboration has expired.');
    }
    if (match.group.isRevoked) {
      throw CollabPairingException('Collaboration has been revoked.');
    }
    return match;
  }

  /// Authorize [groupIds] for [connectionId] and mint a group-scoped
  /// `collab_write` token (server PR #69:
  /// `POST {issuerBase}/api/mcp/connections/:id/collab-groups`, session-JWT auth).
  ///
  /// [httpClient] is injected for tests. Throws [CollabPairingException] on a
  /// missing session JWT or a non-2xx / malformed response.
  Future<CollabAuthorizeResult> authorizeCollabGroups({
    required String connectionId,
    required List<String> groupIds,
    http.Client? httpClient,
  }) async {
    final sessionJwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    if (sessionJwt == null || sessionJwt.isEmpty) {
      throw CollabPairingException(
        'Not signed in. Please sign in before sharing with an AI agent.',
      );
    }
    final base = await _issuerBaseUrl();
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .post(
            Uri.parse(
              '$base/api/mcp/connections/${Uri.encodeComponent(connectionId)}/collab-groups',
            ),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': 'Bearer $sessionJwt',
            },
            body: jsonEncode({'groupIds': groupIds}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CollabPairingException(
          'Failed to authorize group for the AI agent: '
          '${response.statusCode} - ${_clip(response.body)}',
        );
      }
      final Map<String, dynamic> decoded;
      try {
        decoded = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        throw CollabPairingException(
          'Authorization response was not valid JSON.',
        );
      }
      final collabToken = decoded['collabToken'];
      if (collabToken is! String || collabToken.isEmpty) {
        throw CollabPairingException(
          'Authorization response missing "collabToken".',
        );
      }
      final rawGroups = decoded['groupIds'];
      return (
        collabToken: collabToken,
        jti: decoded['jti'] is String ? decoded['jti'] as String : null,
        expiresAt: decoded['expiresAt'] is int ? decoded['expiresAt'] as int : null,
        groupIds: rawGroups is List
            ? rawGroups.map((e) => e.toString()).toList()
            : groupIds,
      );
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Build the MCP **collaboration** capability JSON. PURE (no I/O) — every value
  /// is passed in, so it is fully unit-testable.
  ///
  /// The shape MUST match `fula-api/crates/fula-mcp/src/capability.rs`'s
  /// `CapabilityBundleJson` (snake_case field names are load-bearing — Rust
  /// `#[derive(Deserialize)]`). This is the collaboration-specific capability
  /// shape — keep it matched to capability.rs's `CapabilityBundleJson`; it is
  /// DISTINCT from the per-connection bundle shape and must not be conflated.
  ///
  /// Required: `webui_base, group_id, manifest_bucket, manifest_key,
  /// wrapped_link_secret`. Optional (emitted only when non-empty):
  /// `collab_write_token` (absent ⇒ the AI is read-only for the group),
  /// `refresh_token` + `refresh_url` (re-mint the write token), `storage_api_url`
  /// (quota pre-check host), `user_id` (informational).
  static String buildCollabCapabilityJson({
    required String webuiBase,
    required String groupId,
    required String manifestBucket,
    required String manifestKey,
    required String wrappedLinkSecret,
    String? collabWriteToken,
    String? refreshToken,
    String? refreshUrl,
    String? storageApiUrl,
    String? userId,
  }) {
    bool ne(String? s) => s != null && s.isNotEmpty;
    final capability = <String, dynamic>{
      'webui_base': webuiBase,
      'group_id': groupId,
      'manifest_bucket': manifestBucket,
      'manifest_key': manifestKey,
      'wrapped_link_secret': wrappedLinkSecret,
      if (ne(collabWriteToken)) 'collab_write_token': collabWriteToken,
      if (ne(refreshToken)) 'refresh_token': refreshToken,
      if (ne(refreshToken) && ne(refreshUrl)) 'refresh_url': refreshUrl,
      if (ne(storageApiUrl)) 'storage_api_url': storageApiUrl,
      if (ne(userId)) 'user_id': userId,
    };
    return jsonEncode(capability);
  }

  /// Desktop/Windows **local-stdio** MCP client config. PURE.
  ///
  /// Launches the npm package via `npx` and injects the capability as the
  /// `FULA_MCP_CAPABILITY` env var — the capability JSON is carried as a STRING
  /// (one level of nesting), so `jsonEncode` here escapes it correctly.
  static String buildLocalStdioMcpConfig(String capabilityJson) {
    return jsonEncode({
      'mcpServers': {
        'fula': {
          'command': 'npx',
          'args': ['-y', kFulaMcpNpmPackage],
          'env': {'FULA_MCP_CAPABILITY': capabilityJson},
        },
      },
    });
  }

  /// Mobile/web **hosted-Worker** MCP client config. PURE.
  ///
  /// Points the AI client at the official hosted MCP Worker
  /// ([kHostedMcpBaseUrl]) and carries the SAME capability. NOTE: the precise
  /// hosted client-config wire shape is owned by the hosted Worker / MCP client;
  /// this mirrors the local config (same creds, hosted URL) and is the
  /// lower-confidence of the two — verify against the deployed Worker. The hosted
  /// transport is blocked by the SAME missing wrap binding as local-stdio.
  static String buildHostedMcpConfig(String capabilityJson) {
    return jsonEncode({
      'mcpServers': {
        'fula': {
          'url': kHostedMcpBaseUrl,
          'env': {'FULA_MCP_CAPABILITY': capabilityJson},
        },
      },
    });
  }

  /// End-to-end: share [groupId] with the AI agent identified by [fulaId].
  ///
  /// Steps: resolve the owner group + link secret → decode the `FULA-…` id to the
  /// AI's X25519 pubkey → wrap the link secret for it ([wrapLinkSecret] seam) →
  /// register/refresh the AI connection ([McpConnectionMinter.mintConnectionToken],
  /// binding the AI pubkey) → authorize the group ([authorizeCollabGroups]) →
  /// build the capability + both platform configs.
  ///
  /// [wrapLinkSecret] defaults to the real wrapper ([realWrapper], which calls the
  /// `fula_client` 0.6.18 binding); inject a fake to exercise the flow under test.
  /// [httpClient] is injected for tests.
  ///
  /// Throws [CollabPairingException] on any failure (and would surface
  /// [CollabPairingUnsupported] only if an injected wrapper threw it).
  Future<CollabAiPairing> pairGroupWithAi({
    required String groupId,
    required String fulaId,
    CollabLinkSecretWrapper? wrapLinkSecret,
    http.Client? httpClient,
  }) async {
    final wrap = wrapLinkSecret ?? _realWrap;

    final outgoing = await _requireOutgoing(groupId);
    final group = outgoing.group;
    final linkSecret = outgoing.linkSecretKey!;

    // Decode the AI's FULA share id → raw 32-byte X25519 public key.
    final Uint8List recipientPublicKey;
    try {
      recipientPublicKey = decodeFulaShareId(fulaId);
    } catch (_) {
      throw CollabPairingException(
        'That does not look like a valid AI agent id (expected "FULA-…").',
      );
    }
    if (recipientPublicKey.length != 32) {
      throw CollabPairingException(
        'AI agent id decodes to ${recipientPublicKey.length} bytes (need 32).',
      );
    }

    // The group expiry is ABSOLUTE; the wrap wants a TTL (seconds-from-now), so
    // convert here. _requireOutgoing already rejected an expired group, so a
    // non-null expiry is in the future — a degenerate non-positive TTL (clock
    // skew) fails closed rather than minting a token that outlives the group.
    int? expiresInSeconds;
    if (group.expiresAt != null) {
      final secs = group.expiresAt!.difference(DateTime.now()).inSeconds;
      if (secs <= 0) {
        throw CollabPairingException('Collaboration has expired.');
      }
      expiresInSeconds = secs;
    }

    // Wrap the link secret for the AI pubkey (see [CollabLinkSecretWrapper]).
    final wrappedLinkSecret = await wrap(
      linkSecret: linkSecret,
      recipientPublicKey: recipientPublicKey,
      pathScope: '/collab/$groupId',
      expiresInSeconds: expiresInSeconds,
    );
    // Defensive: a wrapper must never yield an empty token — that would emit a
    // capability the MCP can't recover a link secret from. Fail BEFORE any
    // server mutation (mint / authorize).
    if (wrappedLinkSecret.trim().isEmpty) {
      throw CollabPairingException(
        'Internal error: the link-secret wrap produced an empty token.',
      );
    }

    // Register (or refresh) the AI connection bound to its pubkey → connectionId
    // + the separate refresh credential. Reuses the existing L1d mint.
    final minted = await McpConnectionMinter.instance.mintConnectionToken(
      mcpPublicKeyB64: base64Encode(recipientPublicKey),
      httpClient: httpClient,
    );
    final connectionId = minted.connectionId;
    if (connectionId == null || connectionId.isEmpty) {
      throw CollabPairingException(
        'The server did not register an AI connection (is the issuer up to '
        'date?). Cannot authorize the group.',
      );
    }

    // Authorize the group for this connection → group-scoped collab_write token.
    final authorized = await authorizeCollabGroups(
      connectionId: connectionId,
      groupIds: [groupId],
      httpClient: httpClient,
    );

    final issuerBase = await _issuerBaseUrl();
    String? userId;
    try {
      userId = await deriveUserId();
    } catch (_) {
      userId = null;
    }

    final capabilityJson = buildCollabCapabilityJson(
      webuiBase: kCollabGatewayBaseUrl,
      groupId: groupId,
      manifestBucket: group.manifestBucket,
      manifestKey: group.manifestKey,
      wrappedLinkSecret: wrappedLinkSecret,
      collabWriteToken: authorized.collabToken,
      refreshToken: minted.refreshToken,
      refreshUrl: '$issuerBase/api/mcp/tokens/refresh-connection',
      storageApiUrl: issuerBase,
      userId: userId,
    );

    final fallbackUrl = CollaborationService.instance
        .generateCollaborationLink(outgoing);

    return CollabAiPairing(
      capabilityJson: capabilityJson,
      localStdioConfig: buildLocalStdioMcpConfig(capabilityJson),
      hostedConfig: buildHostedMcpConfig(capabilityJson),
      fallbackCollabUrl: fallbackUrl,
    );
  }

  /// The Method-1 collaboration LINK for [groupId], or null if this user is not
  /// the group owner / the link cannot be built. The link already carries the
  /// link secret in its `sk` fragment, so it is the working fallback when the
  /// wrapped-secret binding is unavailable.
  Future<String?> fallbackCollabUrl(String groupId) async {
    try {
      final outgoing = await _requireOutgoing(groupId);
      return CollaborationService.instance.generateCollaborationLink(outgoing);
    } catch (_) {
      return null;
    }
  }

  /// Best-effort log-safe summary (NEVER logs secrets).
  @visibleForTesting
  static String describeForLog(CollabAiPairing p) =>
      'CollabAiPairing(capabilityBytes=${p.capabilityJson.length}, '
      'hasFallback=${p.fallbackCollabUrl.isNotEmpty})';
}
