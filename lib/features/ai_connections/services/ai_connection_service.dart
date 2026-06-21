import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:fula_client/fula_client.dart' as fula;

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
