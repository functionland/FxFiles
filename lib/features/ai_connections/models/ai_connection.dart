import 'dart:convert';

/// A saved "AI Connection" — the RECORD FxFiles persists after pairing an MCP
/// (Model Context Protocol) client.
///
/// SECURITY MODEL (see P13 / capability.rs): FxFiles persists **only the
/// non-secret record** — the MCP X25519 *public* key, a user label, and the
/// creation time. It NEVER persists the connection bundle's secrets
/// (`mcp_secret_b64`, `workspace_secret_b64`, the scoped `jwt`). The bundle is
/// shown to the user exactly ONCE so they can paste it into their AI client;
/// losing it means re-pairing (mint a fresh connection).
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

  const AiConnection({
    required this.id,
    required this.label,
    required this.mcpPublicKeyB64,
    required this.createdAt,
  });

  /// JSON for the persisted record. Intentionally contains NO secret material —
  /// only the public key, label, id and timestamp. (Tests assert this.)
  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'mcpPublicKeyB64': mcpPublicKeyB64,
        'createdAt': createdAt.toIso8601String(),
      };

  factory AiConnection.fromJson(Map<String, dynamic> json) => AiConnection(
        id: json['id'] as String,
        label: json['label'] as String,
        mcpPublicKeyB64: json['mcpPublicKeyB64'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
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
