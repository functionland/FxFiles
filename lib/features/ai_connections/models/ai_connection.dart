import 'dart:convert';

/// How a connection delivers its capability to the AI client.
///
///  - [local]: the legacy/local-pairing flow (P13) — FxFiles shows the bundle
///    JSON ONCE and the user pastes it into a LOCAL MCP client (Claude Desktop,
///    a CLI). FxFiles never talks to any AI server; it just hands over secrets.
///  - [hosted]: the hosted-connect flow (H5) — FxFiles delivers the SAME
///    capability to a user-run Cloudflare **Worker** (an OAuth 2.1 AS) over
///    `POST {workerUrl}/capability`, so a WEB AI (Claude.ai/ChatGPT) reaches the
///    workspace through the Worker. The Worker custodies the capability
///    (OpenBao-sealed); FxFiles still persists no secrets.
enum AiConnectionKind {
  local,
  hosted;

  /// Wire value persisted in the record JSON. Kept stable + explicit so a future
  /// kind can be added without reordering breaking older stored records.
  String get wire => name; // 'local' | 'hosted'

  /// Parse a persisted wire value, defaulting to [local] for anything
  /// unknown/absent (backward-compat: records written before H5 have no `kind`).
  static AiConnectionKind fromWire(Object? raw) {
    if (raw == 'hosted') return AiConnectionKind.hosted;
    return AiConnectionKind.local;
  }
}

/// A saved "AI Connection" — the RECORD FxFiles persists after pairing an MCP
/// (Model Context Protocol) client.
///
/// SECURITY MODEL (see P13 / capability.rs): FxFiles persists **only the
/// non-secret record** — the MCP X25519 *public* key, a user label, and the
/// creation time. It NEVER persists the connection bundle's secrets
/// (`mcp_secret_b64`, `workspace_secret_b64`, the scoped `jwt`). The bundle is
/// shown to the user exactly ONCE so they can paste it into their AI client;
/// losing it means re-pairing (mint a fresh connection).
///
/// HOSTED variant (H5): a [kind] == [AiConnectionKind.hosted] record additionally
/// remembers the [workerUrl] it delegated the capability to. That is still only
/// non-secret identification — the workspace secret, the connection's mcp secret,
/// the Worker OAuth access token and the Layer-1 refresh token are all transient
/// and NEVER persisted (the same secrets-never-stored invariant as the local
/// flow; the hosted persistence test asserts it).
class AiConnection {
  /// Stable local id (uuid v4).
  final String id;

  /// Human label the user gave this connection (e.g. "Claude Desktop").
  final String label;

  /// Base64 of the 32-byte MCP X25519 **public** key. This is the only key
  /// material we keep — it is public by definition, safe to persist, and lets
  /// the user recognise which key a paired client holds. The matching secret
  /// lived only in the one-time bundle and is never stored.
  final String mcpPublicKeyB64;

  /// When this connection was created (the moment the bundle was minted).
  final DateTime createdAt;

  /// The server's connection id (uuid), returned by the connection mint (L1d).
  /// NON-SECRET — it is only an identifier — and used by disconnect to revoke
  /// the connection server-side (`POST /api/mcp/connections/:id/revoke`).
  ///
  /// NULLABLE for backward-compat: records created before L1d (or against an
  /// issuer that didn't register a connection) have none, and disconnect then
  /// falls back to local-only deletion (expiry-bound). The refresh token and
  /// the scoped jwt are NEVER persisted (secrets) — only this id.
  final String? connectionId;

  /// Whether this is a [AiConnectionKind.local] (paste-bundle) or
  /// [AiConnectionKind.hosted] (delegated-to-a-Worker, H5) connection.
  ///
  /// Defaults to [AiConnectionKind.local] and is OMITTED from the JSON when
  /// local, so records written before H5 (which have no `kind` key) round-trip
  /// byte-identically and the existing "exact key set" test stays green.
  final AiConnectionKind kind;

  /// For a [AiConnectionKind.hosted] connection: the user's Cloudflare Worker
  /// base URL the capability was delivered to (e.g.
  /// `https://fula-mcp.<user>.workers.dev`). NON-SECRET. Null for local
  /// connections (and omitted from the JSON when null).
  final String? workerUrl;

  const AiConnection({
    required this.id,
    required this.label,
    required this.mcpPublicKeyB64,
    required this.createdAt,
    this.connectionId,
    this.kind = AiConnectionKind.local,
    this.workerUrl,
  });

  /// JSON for the persisted record. Intentionally contains NO secret material —
  /// only the public key, label, id, timestamp and (optionally) the non-secret
  /// server connectionId, the connection kind, and the hosted Worker URL.
  /// (Tests assert no secrets are present.)
  ///
  /// `connectionId`/`workerUrl` are omitted when null, and `kind` is omitted when
  /// `local`, so legacy / local records round-trip byte-identically and the key
  /// set stays minimal.
  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'mcpPublicKeyB64': mcpPublicKeyB64,
        'createdAt': createdAt.toIso8601String(),
        if (connectionId != null) 'connectionId': connectionId,
        if (kind != AiConnectionKind.local) 'kind': kind.wire,
        if (workerUrl != null && workerUrl!.isNotEmpty) 'workerUrl': workerUrl,
      };

  factory AiConnection.fromJson(Map<String, dynamic> json) => AiConnection(
        id: json['id'] as String,
        label: json['label'] as String,
        mcpPublicKeyB64: json['mcpPublicKeyB64'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        connectionId: json['connectionId'] as String?,
        kind: AiConnectionKind.fromWire(json['kind']),
        workerUrl: json['workerUrl'] as String?,
      );

  /// Encode a list of connections to a JSON string for SecureStorage.
  static String encodeList(List<AiConnection> connections) =>
      jsonEncode(connections.map((c) => c.toJson()).toList());

  /// Decode a list of connections from a SecureStorage JSON string. Tolerant of
  /// null / empty / malformed input (returns an empty list).
  static List<AiConnection> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(AiConnection.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
