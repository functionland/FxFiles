import 'dart:typed_data';

import 'package:http/http.dart' as http;

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

  /// List the persisted (non-secret) connection records.
  Future<List<AiConnection>> listConnections() async {
    throw UnimplementedError('listConnections: P13 step 5');
  }

  /// Orchestrate steps 2–5: generate the MCP keypair, derive the workspace
  /// secret + owner public key, mint the scoped JWT, build the bundle JSON,
  /// persist ONLY the record (public key + label + createdAt), and return the
  /// one-time bundle string.
  Future<String> createConnection({required String label}) async {
    throw UnimplementedError('createConnection: P13 step 5');
  }

  /// Delete a persisted connection record by id.
  Future<void> deleteConnection(String id) async {
    throw UnimplementedError('deleteConnection: P13 step 5');
  }
}
