import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:fula_client/fula_client.dart' as fula;

import 'package:fula_files/core/services/auth_service.dart';
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
