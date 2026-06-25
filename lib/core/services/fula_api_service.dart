import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/platform/file_length.dart';
import 'package:fula_files/core/platform/frb_u64.dart';
import 'package:fula_files/core/models/share_token.dart' as local;
import 'package:fula_files/core/perf/perf_probe.dart';
import 'package:fula_files/core/services/bucket_cache_service.dart';
import 'package:fula_files/core/services/object_cache_service.dart';
import 'package:fula_files/core/services/fula_api.dart';
import 'package:fula_files/core/services/fula_api_types.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/features/ai_connections/models/ai_connection.dart';
import 'package:fula_files/features/ai_connections/services/ai_connection_service.dart';
import 'package:fula_files/core/utils/cloud_folder_marker.dart';

// Re-export commonly used types for convenience (only non-conflicting ones)
export 'package:fula_client/fula_client.dart' show
    AcceptedShareHandle,
    RotationManagerHandle,
    RotationReport,
    DirectoryListing,
    DirectoryEntry,
    FileMetadata;
// Re-export the shared types from fula_api_types so existing callers
// that imported `fula_api_service.dart` still get them.
export 'package:fula_files/core/services/fula_api_types.dart';

// ============================================================================
// Server-down read config (fula-client v0.4 "offline-download" feature).
//
// Two modes coexist:
//   - Warm-cache: covers the "I used the app, master went down" case via the
//     local block cache + public-gateway fallback. Lights up as soon as the
//     user has read a file at least once with master up.
//   - Cold-start: covers the "fresh install while master is down" case via an
//     on-chain anchor + IPNS lookup that maps the user to their CID set.
//
// The four cold-start fields below act as a single switch: ALL FOUR must be
// non-empty for cold-start to engage. Leaving any one empty cleanly disables
// it and the SDK falls back to warm-cache only â€” that is the current state.
//
// To enable cold-start in production:
//   1. Run `setup-users-index-publisher.sh` on the master and copy the
//      `k51qzi5...` IPNS NAME it prints.
//   2. Paste it into `kUsersIndexIpnsName` below.
//   3. Cold-start activates on the next sign-in (the per-user key is derived
//      from the user's email by `initialize` below).
// ============================================================================
const String kUsersIndexChainRpcUrl = 'https://mainnet.base.org';
const String kUsersIndexAnchorAddress =
    '0x00fB6AD1B42Fb37a0Ac7C2977fC1fa4462C36Af9';
const String kUsersIndexIpnsName =
    'k51qzi5uqu5dkkd6tv8slgoouzzs505qdcr4cb5egc9rlx7qwq0e794yxj9cg4'; // TODO: paste k51qzi5... from setup-users-index-publisher.sh
// IPNS gateway list passed to the SDK at cold-start.
//
// **Empty by design (2026-05-11).** Empirical staleness audit against the
// real master that day showed Cloudflare-edge-cached gateways
// (`{name}.ipns.dweb.link`, `dweb.link/ipns/{name}`) returning records up
// to 70 minutes old (`Age: 4180`, `cf-cache-status: HIT`) while
// `ipfs.io/ipns/{name}` consistently returned the freshest record. The
// SDK's `registry_resolver::default_ipns_gateway_urls` was updated the
// same day to (a) lead with `ipfs.io`, (b) race every gateway in
// parallel, and (c) keep collecting responses for 10 s after the first
// to pick the highest-`sequence` record. That curated multi-gateway list
// is the canonical source of truth; FxFiles passes empty so the SDK
// owns the selection. Users who genuinely need a custom gateway list
// can still set one via Settings â†’ Fula API Config; the Settings screen
// keeps that override path.
//
// Prior contents (kept commented for archaeology):
//   'https://{name}.ipns.dget.top/'      â€” small fleet, less reliable
//                                          uptime than the Protocol Labs
//                                          / Filebase tier.
//   'https://ipfs.filebase.io/ipns/{name}/' â€” path-style; same staleness
//                                          class as dweb.link path-style
//                                          when behind Cloudflare.
//
// Neither of those was `ipfs.io` â€” the gateway that survived the audit.
const List<String> kUsersIndexIpnsGatewayUrls = <String>[];
// 128 MiB cap â€” half the SDK default. Mobile devices have tighter storage
// budgets; the cache is content-addressed so fills mostly stop on its own
// once the working set is covered.
const int kBlockCacheMaxBytes = 128 * 1024 * 1024;

class FulaApiService implements FulaApi {
  static final FulaApiService instance = FulaApiService._();
  FulaApiService._();

  fula.EncryptedClientHandle? _client;
  String? _defaultBucket;
  bool _isConfigured = false;

  // Track which buckets have had their forest loaded
  final Set<String> _loadedForests = {};

  /// The exact arguments of the last [initialize] call, retained verbatim so
  /// [rebuildEncryptedClient] can replay it to get a brand-new client with an
  /// EMPTY forest cache. This is the only recovery for a bucket whose forest
  /// is stuck DIRTY in the SDK's in-memory cache (see [rebuildEncryptedClient]).
  ({
    String endpoint,
    Uint8List secretKey,
    String? accessToken,
    String? defaultBucket,
    String? userEmail,
    String? chainRpcUrl,
    String? usersIndexAnchorAddress,
    String? usersIndexIpnsName,
    List<String>? usersIndexIpnsGatewayUrls,
    Uint8List? bucketsIndexKey,
    Uint8List? userEntrySigningSeed,
  })? _lastInitArgs;

  // Saved credentials for endpoint switching
  Uint8List? _currentSecretKey;
  String? _cloudEndpoint;
  String? _cloudAccessToken;
  bool _isLocalEndpoint = false;

  // Local blox client for download-only (LAN-first reads)
  fula.EncryptedClientHandle? _localClient;
  String? _localEndpoint;
  final Set<String> _localLoadedForests = {};

  // ── AI workspace client (P14) ──────────────────────────────────────────────
  // A SEPARATE encrypted client scoped to the AI's `fula-ai-workspace` bucket.
  // It is encrypted under the dedicated *workspace secret*
  // (blake3DeriveKey('fula:ai-workspace-secret:v1', KEK)) — NOT the user's own
  // file secret — so it can ONLY decode what the AI (MCP) wrote, and the AI in
  // turn can never decode the user's real files. Built LAZILY and only when an
  // AI connection exists, so non-AI users pay nothing.
  fula.EncryptedClientHandle? _workspaceClient;
  final Set<String> _workspaceLoadedForests = {};
  // Single-flight guard: cache the in-flight init Future so two concurrent
  // category loads (e.g. the Images + Videos tabs) can't double-build the
  // client or race a half-initialized handle. Reset to null on dispose so a
  // later sign-in rebuilds.
  Future<void>? _workspaceInitFuture;

  bool get isConfigured => _isConfigured;
  bool get isLocalEndpoint => _isLocalEndpoint;
  bool get hasLocalClient => _localClient != null;
  String? get defaultBucket => _defaultBucket;
  fula.EncryptedClientHandle? get client => _client;

  /// Initialize the fula_client with encryption enabled
  ///
  /// [endpoint] - The Fula gateway URL (e.g., "http://localhost:9000")
  /// [secretKey] - 32-byte encryption key (derived from user credentials)
  /// [accessToken] - Optional JWT token for authentication
  /// [defaultBucket] - Optional default bucket name
  /// [userEmail] - The pinned derivation email (see SecureStorageKeys.derivationEmail).
  ///   Required for cold-start: used to derive a per-user `usersIndexUserKey`
  ///   so the on-chain registry resolver can locate this user's anchor.
  ///   Pass `null` to skip derivation; cold-start then falls back to
  ///   warm-cache-only mode.
  /// [chainRpcUrl] / [usersIndexAnchorAddress] / [usersIndexIpnsName] -
  ///   Optional overrides for the cold-start resolver, typically sourced
  ///   from user-editable settings. Empty/null values fall back to the
  ///   built-in defaults ([kUsersIndexChainRpcUrl] / [kUsersIndexAnchorAddress]
  ///   / [kUsersIndexIpnsName]). Cold-start activates only when all four
  ///   resolver fields (these three plus the derived user key) are non-empty.
  Future<void> initialize({
    required String endpoint,
    required Uint8List secretKey,
    String? accessToken,
    String? defaultBucket,
    String? userEmail,
    String? chainRpcUrl,
    String? usersIndexAnchorAddress,
    String? usersIndexIpnsName,
    List<String>? usersIndexIpnsGatewayUrls,
    /// E2E plan Phase 5 â€” 32-byte AEAD key for encrypting the
    /// per-user bucketsIndex envelope (`K_index`). Pass `null` (or
    /// an empty list) for Mode A users; the SDK keeps using today's
    /// plaintext path.
    Uint8List? bucketsIndexKey,
    /// E2E plan Phase 5 â€” 32-byte Ed25519 seed for signing the
    /// per-user entry (`K_entry_seed`). Pass `null` for Mode A users.
    Uint8List? userEntrySigningSeed,
  }) async {
    // Retain verbatim so rebuildEncryptedClient() can replay this exact call.
    _lastInitArgs = (
      endpoint: endpoint,
      secretKey: secretKey,
      accessToken: accessToken,
      defaultBucket: defaultBucket,
      userEmail: userEmail,
      chainRpcUrl: chainRpcUrl,
      usersIndexAnchorAddress: usersIndexAnchorAddress,
      usersIndexIpnsName: usersIndexIpnsName,
      usersIndexIpnsGatewayUrls: usersIndexIpnsGatewayUrls,
      bucketsIndexKey: bucketsIndexKey,
      userEntrySigningSeed: userEntrySigningSeed,
    );
    try {
      // Derive the per-user cold-start key. Try the JWT-sub-based
      // derivation FIRST â€” it matches master's `state.rs::hash_user_id`
      // byte-for-byte and works correctly for BOTH pre-migration-011
      // users (whose JWT sub is plaintext email) and modern users
      // (whose JWT sub is `sha256(email).hex()`). The legacy
      // `deriveUserKeyFromEmail` always pre-hashes with sha256, which
      // matches master only for modern users â€” for pre-migration users
      // it produces the wrong userKey and cold-start lookup misses
      // ("user has not written yet" error even when they have).
      //
      // Wrap in try/catch â€” a derivation failure must NOT prevent
      // client init; fall back to warm-cache-only by passing an empty
      // userKey (any one of the four usersIndex* fields being empty
      // cleanly disables cold-start in the SDK).
      String usersIndexUserKey = '';
      final jwtSub = _extractJwtSub(accessToken);
      if (jwtSub != null && jwtSub.isNotEmpty) {
        try {
          usersIndexUserKey =
              await fula.deriveUserKeyFromJwtSub(jwtSub: jwtSub);
        } catch (e) {
          debugPrint(
              'FulaApiService: deriveUserKeyFromJwtSub failed: $e; '
              'falling back to email-based derivation');
        }
      }
      if (usersIndexUserKey.isEmpty &&
          userEmail != null &&
          userEmail.isNotEmpty) {
        // Fallback: legacy email-based derivation. Only correct for
        // post-migration-011 users; documented as such in the SDK.
        try {
          usersIndexUserKey =
              await fula.deriveUserKeyFromEmail(email: userEmail);
        } catch (e) {
          debugPrint(
              'FulaApiService: deriveUserKeyFromEmail failed, '
              'cold-start disabled: $e');
        }
      }

      // Resolve cold-start values: prefer the caller's override, fall back
      // to the build-in default. Empty strings (user cleared the setting)
      // also fall through to the default to avoid silently disabling
      // cold-start when the user never opened the settings screen.
      final resolvedChainRpc =
          (chainRpcUrl == null || chainRpcUrl.isEmpty)
              ? kUsersIndexChainRpcUrl
              : chainRpcUrl;
      final resolvedAnchor =
          (usersIndexAnchorAddress == null || usersIndexAnchorAddress.isEmpty)
              ? kUsersIndexAnchorAddress
              : usersIndexAnchorAddress;
      final resolvedIpnsName =
          (usersIndexIpnsName == null || usersIndexIpnsName.isEmpty)
              ? kUsersIndexIpnsName
              : usersIndexIpnsName;
      // null  -> setting never touched. Fall through to `kUsersIndexIpnsGatewayUrls`
      //          which is intentionally empty since 2026-05-11 (see its
      //          docstring), so the SDK's curated list (ipfs.io first +
      //          parallel race + 10s grace) is what gets used.
      // empty -> user explicitly cleared the setting; also delegates to the
      //          SDK's curated subset. Functionally equivalent to null now.
      // other -> use the caller-supplied list verbatim (already trimmed).
      //          Setting this overrides the SDK's freshness-aware ordering,
      //          so prefer null/empty unless you have a specific reason.
      final List<String> resolvedIpnsGatewayUrls = usersIndexIpnsGatewayUrls ??
          kUsersIndexIpnsGatewayUrls;

      final config = fula.FulaConfig(
        endpoint: endpoint,
        accessToken: accessToken,
        timeoutSeconds: BigInt.from(60),
        maxRetries: 3,
        perChunkDownloadTimeoutSeconds: BigInt.from(300),
        bufferedDownloadMaxBytes: BigInt.from(256 * 1024 * 1024),
        // Warm-cache: detect master-down once via a 30s-cached probe so
        // every read isn't paying the latency tax. Block cache populates
        // the (bucket,key)->cid map needed for offline reads later;
        // gateway fallback only kicks in when the health gate says
        // master is actually down.
        healthGateEnabled: true,
        healthGateTtlSeconds: BigInt.from(30),
        blockCacheEnabled: true,
        blockCachePath: '', // empty -> SDK platform default (app sandbox)
        blockCacheMaxBytes: BigInt.from(kBlockCacheMaxBytes),
        gatewayFallbackEnabled: true,
        gatewayFallbackUrls: const [], // empty -> SDK curated 6-gateway list
        gatewayRaceConcurrency: 3,
        // Cold-start: chain RPC + anchor are pre-populated; IPNS name is
        // the deploy-specific switch. Until it is set, these three values
        // sit ready and cold-start stays disabled.
        usersIndexChainRpcUrl: resolvedChainRpc,
        usersIndexAnchorAddress: resolvedAnchor,
        usersIndexIpnsName: resolvedIpnsName,
        usersIndexUserKey: usersIndexUserKey,
        usersIndexIpnsGatewayUrls: resolvedIpnsGatewayUrls,
        usersIndexIpfsGatewayUrls: const [], // empty -> SDK 6-gateway list
        // Walkable-v8 default-on globally (2026-05-09). Every Phase 2
        // root commit stamps a content-addressed CID alongside the
        // existing storage_key in PointerWire::LinkV2, so cold-cache
        // offline reads can walk the encrypted forest via the gateway
        // race instead of the (master-S3-only) storage_key path. The
        // SDK requires this field explicitly because flipping it to
        // false would silently downgrade newly-written buckets to
        // legacy v7 pointers â€” making them offline-unreachable on
        // fresh devices. Cloud client = always on.
        walkableV8WriterEnabled: true,
        // E2E plan Phase 5 â€” per-user encrypted bucketsIndex keys.
        // Empty list signals "Mode A behavior preserved"; the SDK
        // falls back to today's plaintext `users[]` path. Non-empty
        // (32 bytes) enables the new encrypted + signed-entry path.
        encryptedUserBucketsIndexKey: bucketsIndexKey ?? Uint8List(0),
        userEntrySigningSeed: userEntrySigningSeed ?? Uint8List(0),
      );

      final encConfig = fula.EncryptionConfig(
        secretKey: secretKey,
        enableMetadataPrivacy: true,
        obfuscationMode: fula.ObfuscationMode.flatNamespace, // Maximum privacy
      );

      _client = await fula.createEncryptedClient(config: config, encryption: encConfig);
      _defaultBucket = defaultBucket;
      _isConfigured = true;
      _loadedForests.clear();
      _currentSecretKey = secretKey;

      debugPrint('FulaApiService initialized with FlatNamespace encryption');
    } catch (e) {
      throw FulaApiException('Failed to initialize FulaApiService: $e');
    }
  }

  /// Switch to local blox S3 gateway when on LAN.
  /// Preserves cloud credentials for fallback.
  Future<void> switchToLocalGateway(String localUrl, String pairingSecret) async {
    if (_currentSecretKey == null) {
      debugPrint('Cannot switch to local gateway: not initialized');
      return;
    }
    // Save cloud credentials on first switch
    if (!_isLocalEndpoint && _cloudEndpoint == null) {
      // Read current endpoint from client config before switching
      _cloudEndpoint = null; // Will be set by caller or from current state
      _cloudAccessToken = null;
    }
    _isLocalEndpoint = true;
    _loadedForests.clear();
    await initialize(
      endpoint: localUrl,
      secretKey: _currentSecretKey!,
      accessToken: pairingSecret,
      defaultBucket: _defaultBucket,
    );
    debugPrint('Switched to local S3 gateway: $localUrl');
  }

  /// Re-initialize the cloud client with [newEndpoint], preserving
  /// the currently-configured secret key + access token. **Used only
  /// by integration tests** to simulate online â†” offline transitions
  /// (e.g. swap to `https://s33.cloud.fx.land` to make the master
  /// DNS-fail without going through the OAuth flow).
  ///
  /// The original cloud endpoint is stashed in [_cloudEndpoint] (the
  /// existing field used by `switchToCloudGateway` for symmetry) so
  /// the test can restore by calling this again with the saved value.
  ///
  /// `@visibleForTesting` flags the analyzer to warn if production
  /// code paths reach this. Failing closed when not initialized so
  /// a misuse is loud, not silent.
  @visibleForTesting
  Future<void> testOnlyReinitializeWithEndpoint(String newEndpoint) async {
    final secret = _currentSecretKey;
    if (secret == null) {
      throw FulaApiException(
        'testOnlyReinitializeWithEndpoint: FulaApiService is not '
        'initialized â€” sign in on the device before running '
        'integration tests',
      );
    }
    // Track the new endpoint so the harness can read it back and
    // confirm the mutation took.
    _cloudEndpoint = newEndpoint;
    _loadedForests.clear();
    await initialize(
      endpoint: newEndpoint,
      secretKey: secret,
      accessToken: _cloudAccessToken,
      defaultBucket: _defaultBucket,
    );
  }

  /// Switch back to cloud gateway
  Future<void> switchToCloudGateway({
    required String endpoint,
    String? accessToken,
  }) async {
    if (_currentSecretKey == null) {
      debugPrint('Cannot switch to cloud gateway: not initialized');
      return;
    }
    _isLocalEndpoint = false;
    _loadedForests.clear();
    await initialize(
      endpoint: endpoint,
      secretKey: _currentSecretKey!,
      accessToken: accessToken,
      defaultBucket: _defaultBucket,
    );
    debugPrint('Switched to cloud S3 gateway: $endpoint');
  }

  /// Legacy configure method - redirects to initialize
  /// Kept for backward compatibility during migration
  void configure({
    required String endpoint,
    required String accessKey,
    required String secretKey,
    String? defaultBucket,
    bool? useSSL,
    String? pinningService,
    String? pinningToken,
  }) {
    debugPrint('Warning: configure() is deprecated. Use initialize() instead.');
    // This method cannot be used directly with fula_client
    // The caller should use initialize() with the encryption key
    _defaultBucket = defaultBucket;
  }

  void _ensureConfigured() {
    if (!_isConfigured || _client == null) {
      throw FulaApiException('FulaApiService is not configured. Call initialize() first.');
    }
  }

  /// Ensure the forest (encrypted file index) is loaded for a bucket.
  ///
  /// After the fula-client fix at `encryption.rs:2569` (Phase 2.4
  /// offline-propagation regression â€” narrowed `Err(_)` to
  /// `Err(e) if e.is_not_found()`), the catch branch fires only for
  /// real errors:
  ///
  ///   - **Master unreachable / cold-start failed / 5xx / network** â€”
  ///     offline or transient outage. Don't mark as loaded; rethrow so
  ///     the caller surfaces "offline; try later" instead of an empty
  ///     list (the prior `_loadedForests.add` on every catch silently
  ///     painted offline outages as empty buckets â€” exactly the bug
  ///     this pairs with).
  ///   - **Auth / decrypt / sequence-regression** â€” real errors that
  ///     also rethrow.
  ///
  /// Genuine new-bucket cases (404 / NoSuchKey from master) NEVER
  /// throw on the Dart side: the SDK creates an empty v7 forest and
  /// returns the `"forest is sharded"` marker, which the fula-flutter
  /// binding (`crates/fula-flutter/src/api/forest.rs:30-34`) maps to
  /// `Ok(())` before Dart sees anything. So new-bucket flow takes the
  /// success branch above, not the catch.
  Future<void> _ensureForestLoaded(String bucket) async {
    if (_loadedForests.contains(bucket)) return;
    try {
      await perfSpan('forest-load $bucket',
          () => fula.loadForest(client: _client!, bucket: bucket));
      _loadedForests.add(bucket);
      debugPrint('Forest loaded for bucket: $bucket');
    } catch (e) {
      // Don't mark `_loadedForests.add(bucket)` here â€” the next call
      // should re-attempt the fetch (this is what the fula-client fix
      // achieves: cache stays empty so a transient outage recovers
      // automatically when master comes back). Rethrow so callers
      // (listObjects, downloadObject, etc.) can surface the actual
      // condition instead of returning an empty list.
      debugPrint('Forest load for $bucket failed: $e');
      rethrow;
    }
  }

  /// Clear loaded forest cache (call when switching users or on logout)
  void clearForestCache() {
    _loadedForests.clear();
  }

  /// Drop ONE bucket's forest so the next listing/download re-fetches
  /// it from the server. The forest is cached at BOTH layers — this
  /// Dart memo and inside the Rust client (its copy is what actually
  /// pins the data; fula_client 0.6.9 exposed the dirty-safe
  /// invalidation for it, issue #36). A refresh that's meant to pick
  /// up ANOTHER device's writes must call this first, or the session
  /// re-serves its stale in-memory forest as if it were live (found
  /// via a real two-client repro: a long-lived web tab kept re-caching
  /// a pre-upload listing). Dirty-safe: a forest with pending unsaved
  /// local changes is NOT evicted (core contract). Additive; no
  /// existing caller's behavior changes.
  Future<void> invalidateForestCache(String bucket) async {
    _loadedForests.remove(bucket);
    _localLoadedForests.remove(bucket);
    final client = _client;
    if (client == null) return;
    try {
      await fula.invalidateForestCache(client: client, bucket: bucket);
    } catch (e) {
      debugPrint('invalidateForestCache($bucket): $e');
    }
  }

  /// Rebuild the encrypted client by replaying the last [initialize] call,
  /// producing a fresh client whose per-bucket forest cache is EMPTY.
  ///
  /// This is the only recovery for a bucket whose forest is stuck DIRTY. The
  /// SDK serves a dirty forest straight from its in-memory cache regardless of
  /// the TTL (`encryption.rs` load_forest_internal: `if is_fresh ||
  /// entry.is_dirty()`), and [invalidateForestCache] is dirty-safe (it will
  /// NOT evict a dirty forest). A flaky-network upload whose forest flush
  /// failed leaves the forest dirty and un-reflushable (the server's sequence
  /// guard rejects the stale-seq rewrite), so a long-lived session then
  /// re-serves the stale index forever — Refresh's invalidate is a silent
  /// no-op and only a fresh browser context reads correctly. Rebuilding the
  /// client is exactly what that fresh context does.
  ///
  /// Safe by construction: it does NOT flush, so the discarded dirty forest is
  /// never persisted and cannot clobber another device's writes. Any unsaved
  /// local change is dropped, but it was never on the server (that is WHY the
  /// forest was dirty), so the session simply becomes consistent with storage.
  ///
  /// On the web the SDK block cache is compiled out (wasm32), so the in-memory
  /// forest cache is the ONLY stale state and a fresh client provably clears it
  /// (this is why incognito always shows the latest).
  ///
  /// Callers MUST ensure no upload is in flight — a rebuild swaps the client
  /// handle, and an in-flight write would land on the discarded old client. On
  /// the web that guard is `WebUploadManager.instance.isActive`. A failed
  /// replay leaves the previous client intact (initialize only assigns
  /// `_client` on success), so a transient failure is a safe no-op.
  Future<void> rebuildEncryptedClient() async {
    final a = _lastInitArgs;
    if (a == null) {
      throw FulaApiException(
          'rebuildEncryptedClient: no prior initialize() to replay');
    }
    // Diagnostic honesty (never discard dirty state silently): a rebuild drops
    // every in-memory forest. A DIRTY forest holds unsaved upserts — e.g. a
    // file whose content reached S3 but whose index flush failed. Discarding
    // it removes that entry from the listing; the content is orphaned on S3
    // and was never in the SERVER index (so other devices never saw it and the
    // upload had reported failure), so the user must re-upload it. Log which
    // buckets are dirty so this is observable, and so a live Refresh confirms
    // the dirty-forest root cause.
    final preClient = _client;
    if (preClient != null) {
      for (final bucket in _loadedForests.toList()) {
        try {
          if (await fula.hasPendingChanges(client: preClient, bucket: bucket)) {
            debugPrint('FulaApiService.rebuildEncryptedClient: DISCARDING dirty '
                'forest "$bucket" — unsaved local changes dropped (a failed '
                'upload to this bucket must be retried)');
          }
        } catch (_) {/* best-effort logging only */}
      }
    }
    debugPrint('FulaApiService: rebuilding encrypted client (dropping forests)');
    await initialize(
      endpoint: a.endpoint,
      secretKey: a.secretKey,
      accessToken: a.accessToken,
      defaultBucket: a.defaultBucket,
      userEmail: a.userEmail,
      chainRpcUrl: a.chainRpcUrl,
      usersIndexAnchorAddress: a.usersIndexAnchorAddress,
      usersIndexIpnsName: a.usersIndexIpnsName,
      usersIndexIpnsGatewayUrls: a.usersIndexIpnsGatewayUrls,
      bucketsIndexKey: a.bucketsIndexKey,
      userEntrySigningSeed: a.userEntrySigningSeed,
    );
  }

  // ============================================================================
  // KEY MANAGEMENT
  // ============================================================================

  /// Export the secret key for backup
  Future<Uint8List> exportSecretKey() async {
    _ensureConfigured();
    return await fula.exportSecretKey(client: _client!);
  }

  /// Get the public key for sharing
  Future<Uint8List> getPublicKey() async {
    _ensureConfigured();
    return await fula.getPublicKey(client: _client!);
  }

  // ============================================================================
  // BUCKET OPERATIONS
  // ============================================================================

  Future<List<String>> listBuckets() async {
    _ensureConfigured();
    try {
      final buckets = await fula.encListBuckets(client: _client!);
      return buckets.map((b) => b.name).toList();
    } catch (e) {
      debugPrint('listBuckets error: $e');
      throw FulaApiException('Failed to list buckets: $e');
    }
  }

  /// Same as [listBuckets] but falls back to the per-user
  /// [BucketCacheService] snapshot when the live call errors. The SDK
  /// cannot enumerate buckets offline (privacy invariant â€” see
  /// fula-client docs), so the snapshot is the only way the Cloud Files
  /// screen can render anything when the master gateway is unreachable.
  ///
  /// Retries the live call once after a 500 ms pause before falling
  /// back, so a single transient blip (DNS hiccup, brief 5xx) doesn't
  /// flip the UI into the "stale" state.
  Future<({List<String> buckets, bool stale, DateTime? fetchedAt})>
      listBucketsCached() async {
    try {
      final fresh = await listBuckets();
      await BucketCacheService.persist(fresh);
      return (buckets: fresh, stale: false, fetchedAt: DateTime.now());
    } catch (firstErr) {
      try {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final fresh = await listBuckets();
        await BucketCacheService.persist(fresh);
        return (buckets: fresh, stale: false, fetchedAt: DateTime.now());
      } catch (retryErr) {
        debugPrint(
          'listBucketsCached: live call failed twice, falling back to cache: $retryErr',
        );
        final cached = await BucketCacheService.readCache();
        if (cached != null) {
          return (
            buckets: cached.buckets,
            stale: true,
            fetchedAt: cached.fetchedAt,
          );
        }
        // No cache to serve â€” surface the original error, not the retry one,
        // since the first failure is the more representative diagnostic.
        throw firstErr;
      }
    }
  }

  /// Read-only-legacy guard (v8 migration): refuse to WRITE to a managed
  /// legacy content bucket â€” new data must go to its `-v8` sibling, never a
  /// gc-damaged bucket. Inert while v8 routing is disabled. Reads and deletes
  /// are intentionally NOT guarded (legacy content stays readable, and a user
  /// may still attempt to clean up legacy objects).
  void _guardLegacyWrite(String bucket) {
    if (BucketVersionResolver.isForbiddenWriteTarget(bucket)) {
      throw FulaApiException(
        'Refusing to write to legacy bucket "$bucket": it is gc-damaged and '
        'blocks writes. Route through BucketVersionResolver.writeBucket() so '
        'the write targets "$bucket-${BucketVersionResolver.versionSuffix}".',
      );
    }
  }

  /// Backstop for the P4 policy: a managed *legacy* content bucket does not
  /// support deletion (its objects are preserved so existing share links keep
  /// working). Only the `-v8` sibling can be deleted. The UI checks this first
  /// and shows a friendly message; this guards any path that doesn't.
  void _guardLegacyDelete(String bucket) {
    if (BucketVersionResolver.isForbiddenWriteTarget(bucket)) {
      throw FulaApiException(
        'Legacy bucket "$bucket" does not support deletion: its objects are '
        'preserved so existing share links keep working. Only files in '
        '"$bucket-${BucketVersionResolver.versionSuffix}" can be deleted.',
      );
    }
  }

  Future<void> createBucket(String bucket) async {
    _guardLegacyWrite(bucket);
    _ensureConfigured();
    try {
      await fula.encCreateBucket(client: _client!, name: bucket);
    } catch (e) {
      // Bucket may already exist
      if (!e.toString().contains('already exists')) {
        throw FulaApiException('Failed to create bucket: $e');
      }
    }
  }

  /// Materialize a folder by writing a hidden keep-marker under it. Folders are
  /// virtual key-prefixes in the encrypted forest (there is no `mkdir`), so an
  /// empty folder needs at least one object. The marker is hidden from every
  /// file view (see stripFolderMarkers). [folderPath] is the full path within
  /// [bucket] (e.g. 'photos/2024'); leading/trailing slashes are tolerated.
  /// Inherits uploadObject's legacy-write guard (refuses gc-damaged buckets).
  Future<void> createFolder(String bucket, String folderPath) async {
    final clean = folderPath.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (clean.isEmpty) {
      throw FulaApiException('Folder path cannot be empty');
    }
    await uploadObject(
      bucket,
      '/$clean/$kFolderMarkerName',
      Uint8List.fromList(folderMarkerBytes()),
    );
  }

  Future<bool> bucketExists(String bucket) async {
    _ensureConfigured();
    try {
      final buckets = await listBuckets();
      return buckets.contains(bucket);
    } catch (e) {
      throw FulaApiException('Failed to check bucket: $e');
    }
  }

  // ============================================================================
  // ENCRYPTED FILE OPERATIONS (using FlatNamespace)
  // ============================================================================

  /// List all files in a bucket from the encrypted forest index.
  ///
  /// Uses [fula.listFromForest] which reads from the SDK's in-memory
  /// forest state populated by [fula.loadForest]. For sharded forests
  /// the SDK swallows the marker error in `loadForest` and the I/O
  /// path handles sharding transparently (see forest.dart loadForest
  /// doc). Do **not** swap this for `fula.listDecrypted` â€” that is a
  /// raw S3 LIST that returns internal `__fula_forest_v7_nodes/...`
  /// entries alongside user files and is not offline-capable.
  /// Cached, timeout-bounded variant of [listObjects].
  ///
  /// Used by the file browser screens to keep the UI responsive when the
  /// underlying `fula.listFromForest` call is slow or blocked. Failure
  /// modes that surface a stale snapshot:
  ///
  ///   * The encrypted client's outer write lock is held by an in-flight
  ///     upload (fix in Phase B1 of the sync-cancel/large-upload work).
  ///   * IPNS chain RPC backing the forest's users-index resolution is
  ///     unreachable (see `mainnet.base.org` errors in the field reports).
  ///   * Any transient master-gateway 5xx.
  ///
  /// Behaviour:
  ///   1. Try the live call with a [timeout] (default 10 s). On success,
  ///      persist into [ObjectCacheService] and return `stale=false`.
  ///   2. If that times out or throws, retry once after a 500 ms pause.
  ///      Same caching on success.
  ///   3. On the second failure, return whatever the cache has with
  ///      `stale=true`. If the cache has nothing, rethrow the first
  ///      error so the UI can surface it.
  ///
  /// Mirrors [listBucketsCached] (`fula_api_service.dart:467`) so the
  /// cloud-files screens have a uniform contract for stale fallbacks.
  Future<({List<FulaObject> objects, bool stale, DateTime? fetchedAt})>
      listObjectsCached(
    String bucket, {
    String prefix = '',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    Future<List<FulaObject>> tryLive() =>
        listObjects(bucket, prefix: prefix).timeout(timeout);

    try {
      final fresh = await tryLive();
      // Persist the slice we actually fetched; the cache key includes
      // the prefix so different views don't clobber each other.
      await ObjectCacheService.persist(bucket, prefix, fresh);
      return (objects: fresh, stale: false, fetchedAt: DateTime.now());
    } catch (firstErr) {
      try {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final fresh = await tryLive();
        await ObjectCacheService.persist(bucket, prefix, fresh);
        return (objects: fresh, stale: false, fetchedAt: DateTime.now());
      } catch (retryErr) {
        debugPrint(
          'listObjectsCached($bucket, "$prefix"): live failed twice, '
          'falling back to cache: $retryErr',
        );
        final cached = await ObjectCacheService.readCache(bucket, prefix);
        if (cached != null) {
          return (
            objects: cached.objects,
            stale: true,
            fetchedAt: cached.fetchedAt,
          );
        }
        // No cache to serve â€” surface the original error.
        throw firstErr;
      }
    }
  }

  Future<List<FulaObject>> listObjects(
    String bucket, {
    String prefix = '',
    bool recursive = false,
  }) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);

      final files = await perfSpan(
          'list-from-forest $bucket',
          () => fula.listFromForest(
                client: _client!,
                bucket: bucket,
              ));

      // Filter by prefix if specified (listFromForest returns the whole
      // bucket; the prefix is a Dart-side narrowing).
      final filtered = prefix.isEmpty
          ? files
          : files.where((f) => f.originalKey.startsWith(prefix)).toList();

      debugPrint(
        'listObjects($bucket, prefix="$prefix"): ${filtered.length} files (raw forest=${files.length})',
      );

      return filtered.map((meta) => FulaObject(
        key: meta.originalKey,
        size: meta.size.toInt(),
        lastModified: meta.modifiedAt != null
            // u64 via FRB: int natively, BigInt on web — normalize.
            ? DateTime.fromMillisecondsSinceEpoch(
                frbU64ToInt(meta.modifiedAt)! * 1000)
            : null,
        isDirectory: false,
        sourceBucket: bucket,
        metadata: {
          'storageKey': meta.storageKey,
          'contentType': meta.contentType ?? '',
          'isEncrypted': meta.isEncrypted.toString(),
        },
      )).toList();
    } catch (e) {
      debugPrint('listObjects($bucket, prefix="$prefix") error: $e');
      throw FulaApiException('Failed to list objects: $e');
    }
  }

  /// List directory structure
  Future<fula.DirectoryListing> listDirectory(String bucket, {String? prefix}) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);
      return await fula.listDirectory(client: _client!, bucket: bucket, prefix: prefix);
    } catch (e) {
      throw FulaApiException('Failed to list directory: $e');
    }
  }

  /// Get file metadata without downloading content
  Future<FulaObjectMetadata> getObjectMetadata(String bucket, String key) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);

      // Find the file in the forest
      final files = await fula.listFromForest(client: _client!, bucket: bucket);
      final file = files.firstWhere(
        (f) => f.originalKey == key,
        orElse: () => throw FulaApiException('File not found: $key'),
      );

      return FulaObjectMetadata(
        size: file.size.toInt(),
        lastModified: file.modifiedAt != null
            // u64 via FRB: int natively, BigInt on web — normalize.
            ? DateTime.fromMillisecondsSinceEpoch(
                frbU64ToInt(file.modifiedAt)! * 1000)
            : null,
        contentType: file.contentType,
        isEncrypted: file.isEncrypted,
        originalFilename: file.originalKey.split('/').last,
      );
    } catch (e) {
      if (e is FulaApiException) rethrow;
      throw FulaApiException('Failed to get object metadata: $e');
    }
  }

  /// Download and decrypt a file by its path.
  /// The endpoint (local or cloud) is already set by the switching logic.
  Future<Uint8List> downloadObject(String bucket, String key, {String? contentCid}) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);
      final data = await fula.getFlat(client: _client!, bucket: bucket, path: key);
      return Uint8List.fromList(data);
    } catch (e) {
      throw FulaApiException('Failed to download object: $e');
    }
  }

  // ============================================================================
  // LOCAL BLOX CLIENT (download-only, LAN-first reads)
  // ============================================================================

  /// Initialize a second encrypted client pointed at the local blox S3.
  /// Used exclusively for reads â€” uploads always go through the cloud [_client].
  Future<void> initializeLocalClient({
    required String endpoint,
    required String accessToken,
  }) async {
    if (_currentSecretKey == null) {
      debugPrint('FulaApiService: Cannot init local client â€” not logged in');
      return;
    }
    // Skip if already pointing at the same endpoint
    if (_localClient != null && _localEndpoint == endpoint) return;

    try {
      final config = fula.FulaConfig(
        endpoint: endpoint,
        accessToken: accessToken,
        timeoutSeconds: BigInt.from(3),
        maxRetries: 1,
        perChunkDownloadTimeoutSeconds: BigInt.from(300),
        bufferedDownloadMaxBytes: BigInt.from(256 * 1024 * 1024),
        // Warm-cache: enable health gate + block cache so LAN reads also
        // populate the shared on-disk cache used by the cloud client.
        // Gateway fallback stays OFF â€” when the LAN endpoint fails, the
        // upstream `downloadWithLocalFallback` falls through to the cloud
        // client which has its own gateway fallback. Public gateways
        // can't reach the local blox by design.
        healthGateEnabled: true,
        healthGateTtlSeconds: BigInt.from(30),
        blockCacheEnabled: true,
        blockCachePath: '', // shared default path with the cloud client
        blockCacheMaxBytes: BigInt.from(kBlockCacheMaxBytes),
        gatewayFallbackEnabled: false,
        gatewayFallbackUrls: const [],
        gatewayRaceConcurrency: 3,
        // Cold-start does not apply to the LAN client â€” it is configured
        // via a pairing secret and reaches a known LAN endpoint, not a
        // user-scoped on-chain registry.
        usersIndexChainRpcUrl: '',
        usersIndexAnchorAddress: '',
        usersIndexIpnsName: '',
        usersIndexUserKey: '',
        usersIndexIpnsGatewayUrls: const [],
        usersIndexIpfsGatewayUrls: const [],
        // Walkable-v8 default-on (see cloud-client comment). Same flag
        // value here so LAN-uploaded manifests are byte-compatible
        // with cloud-uploaded ones â€” a single content-addressed
        // forest works regardless of which client wrote it.
        walkableV8WriterEnabled: true,
        // E2E plan Phase 5 â€” encrypted bucketsIndex keys are scoped
        // to the cloud client (master is the entries-store host).
        // LAN/blox client does not run the signed-entry writer.
        encryptedUserBucketsIndexKey: Uint8List(0),
        userEntrySigningSeed: Uint8List(0),
      );

      final encConfig = fula.EncryptionConfig(
        secretKey: _currentSecretKey!,
        enableMetadataPrivacy: true,
        obfuscationMode: fula.ObfuscationMode.flatNamespace,
      );

      _localClient = await fula.createEncryptedClient(config: config, encryption: encConfig);
      _localEndpoint = endpoint;
      _localLoadedForests.clear();
      debugPrint('FulaApiService: local blox client ready at $endpoint');
    } catch (e) {
      debugPrint('FulaApiService: local client init failed: $e');
      _localClient = null;
      _localEndpoint = null;
    }
  }

  /// Download from the local blox first; fall back to cloud on failure.
  /// Zero overhead when no local client is configured.
  Future<Uint8List> downloadWithLocalFallback(String bucket, String key) async {
    _ensureConfigured();

    // Fast path: no local client â†’ straight to cloud
    if (_localClient == null) {
      return downloadObject(bucket, key);
    }

    // Try local blox first
    try {
      // Lazy per-bucket forest load on the local client
      if (!_localLoadedForests.contains(bucket)) {
        await fula.loadForest(client: _localClient!, bucket: bucket);
        _localLoadedForests.add(bucket);
      }

      final data = await fula.getFlat(client: _localClient!, bucket: bucket, path: key);
      debugPrint('Downloaded from local blox: $key');
      return Uint8List.fromList(data);
    } catch (e) {
      // Clear bucket so forest reloads next attempt (may have been updated)
      _localLoadedForests.remove(bucket);
      debugPrint('Local download failed for $key, falling back to cloud: $e');
    }

    // Cloud fallback
    return downloadObject(bucket, key);
  }

  /// Route a download by the object's [sourceBucket] (P14.1). AI-workspace
  /// files decrypt only via the workspace client, so they go through
  /// [downloadWorkspaceObject] (which reads from [aiWorkspaceBucket]
  /// regardless of [bucket]); the user's own files route to [downloadObject].
  @override
  Future<Uint8List> downloadBySourceBucket(
          String bucket, String key, String? sourceBucket) =>
      sourceBucket == aiWorkspaceBucket
          ? downloadWorkspaceObject(aiWorkspaceBucket, key)
          : downloadObject(bucket, key);

  /// LAN-first sibling of [downloadBySourceBucket] (P14.1). The AI branch
  /// skips the LAN fallback — the AI workspace is cloud-only, so there is no
  /// local blox copy to try first.
  @override
  Future<Uint8List> downloadBySourceBucketWithLocalFallback(
          String bucket, String key, String? sourceBucket) =>
      sourceBucket == aiWorkspaceBucket
          ? downloadWorkspaceObject(aiWorkspaceBucket, key)
          : downloadWithLocalFallback(bucket, key);

  /// Dispose the local blox client (e.g. on unpair or blox goes offline).
  void disposeLocalClient() {
    _localClient = null;
    _localEndpoint = null;
    _localLoadedForests.clear();
    debugPrint('FulaApiService: local blox client disposed');
  }

  // ============================================================================
  // AI WORKSPACE CLIENT (P14 — read the AI/MCP's own encrypted forest)
  // ============================================================================

  /// The bucket the AI (MCP) writes its workspace files + tag doc into. Keys
  /// are `ai/<category>/...` (category ∈ images/videos/audio/documents) and
  /// `ai/tag-metadata/ai-workspace.json`. Mirrors the MCP's grant scope `ai/`.
  ///
  /// Aliases [FulaApi.aiWorkspaceBucket] (the single source of truth, on the
  /// shared surface) so existing `FulaApiService.aiWorkspaceBucket` call sites
  /// keep working without a second literal that could drift.
  static const String aiWorkspaceBucket = FulaApi.aiWorkspaceBucket;

  /// True if the user has at least one P13 AI-connection record. This is the
  /// gate: every AI-workspace read (category merge, tag adoption) is a no-op
  /// unless this returns true, so non-AI users never build the workspace client
  /// or issue a workspace list/download. Reads secure storage (cheap) and never
  /// throws — any failure is treated as "no AI connection".
  @override
  Future<bool> hasAiConnection() async {
    try {
      final raw = await SecureStorageService.instance
          .read(SecureStorageKeys.aiConnections);
      return AiConnection.decodeList(raw).isNotEmpty;
    } catch (e) {
      debugPrint('FulaApiService.hasAiConnection: treating as none: $e');
      return false;
    }
  }

  /// Lazily build the AI-workspace [EncryptedClient] under the supplied
  /// [workspaceSecret] (= blake3DeriveKey('fula:ai-workspace-secret:v1', KEK)).
  ///
  /// Mirrors [initialize]'s cloud client EXACTLY for the forest-decode-relevant
  /// settings so the forest the MCP wrote decodes byte-for-byte:
  ///   EncryptionConfig(enableMetadataPrivacy: true,
  ///                    obfuscationMode: ObfuscationMode.flatNamespace)
  /// — the precise mirror of the MCP's `EncryptionConfig::from_secret_key`
  /// (`metadata_privacy = true`, `obfuscation_mode = FlatNamespace`). The only
  /// difference vs the cloud client is the SECRET (workspace, not the user's
  /// own). Endpoint + access token are reused from the cloud client's last
  /// [initialize] call: the same gateway hosts `fula-ai-workspace` and the
  /// forest is content-addressed, so only the secret governs decode.
  ///
  /// SINGLE-FLIGHT: concurrent callers await the same in-flight Future, so the
  /// client is built once even if several category views trigger it together.
  Future<void> initializeWorkspaceClient(Uint8List workspaceSecret) async {
    if (_workspaceClient != null) return;
    // Coalesce concurrent inits onto one Future.
    final inFlight = _workspaceInitFuture;
    if (inFlight != null) return inFlight;

    final future = _buildWorkspaceClient(workspaceSecret);
    _workspaceInitFuture = future;
    try {
      await future;
    } finally {
      // Clear the latch whether we succeeded (so a future dispose+retry works)
      // or failed (so the next attempt can retry rather than re-await a
      // resolved-failed Future).
      _workspaceInitFuture = null;
    }
  }

  Future<void> _buildWorkspaceClient(Uint8List workspaceSecret) async {
    final args = _lastInitArgs;
    if (args == null) {
      debugPrint(
          'FulaApiService: cannot init workspace client — cloud client not '
          'initialized yet');
      return;
    }
    try {
      final config = fula.FulaConfig(
        endpoint: args.endpoint,
        accessToken: args.accessToken,
        timeoutSeconds: BigInt.from(60),
        maxRetries: 3,
        perChunkDownloadTimeoutSeconds: BigInt.from(300),
        bufferedDownloadMaxBytes: BigInt.from(256 * 1024 * 1024),
        // Read-only client — no health gate / block cache / gateway race
        // needed (the workspace is small and read on-demand). Keep them off
        // so the workspace client adds no background cost.
        healthGateEnabled: false,
        healthGateTtlSeconds: BigInt.from(30),
        blockCacheEnabled: false,
        blockCachePath: '',
        blockCacheMaxBytes: BigInt.from(kBlockCacheMaxBytes),
        gatewayFallbackEnabled: false,
        gatewayFallbackUrls: const [],
        gatewayRaceConcurrency: 3,
        // Cold-start does not apply to the workspace client — it reads a known
        // bucket on the configured gateway, not a user-scoped on-chain index.
        usersIndexChainRpcUrl: '',
        usersIndexAnchorAddress: '',
        usersIndexIpnsName: '',
        usersIndexUserKey: '',
        usersIndexIpnsGatewayUrls: const [],
        usersIndexIpfsGatewayUrls: const [],
        // Same walkable-v8 flag as the cloud/local clients so the workspace
        // forest the MCP wrote is read with byte-compatible pointer handling.
        walkableV8WriterEnabled: true,
        // The workspace client never runs the signed-entry writer.
        encryptedUserBucketsIndexKey: Uint8List(0),
        userEntrySigningSeed: Uint8List(0),
      );

      // EXACT mirror of the MCP's `EncryptionConfig::from_secret_key`:
      // metadata-privacy ON + FlatNamespace obfuscation, differing only in the
      // secret. (forest_cache_ttl_secs=60 on the Rust side is an internal cache
      // TTL, not part of the on-disk forest format → no Dart field, irrelevant
      // to decode. There is no chunk-threshold field on either side's
      // EncryptionConfig; chunking is write-side and self-describing in the
      // stored manifest, so nothing to match for a read.)
      final encConfig = fula.EncryptionConfig(
        secretKey: workspaceSecret,
        enableMetadataPrivacy: true,
        obfuscationMode: fula.ObfuscationMode.flatNamespace,
      );

      _workspaceClient =
          await fula.createEncryptedClient(config: config, encryption: encConfig);
      _workspaceLoadedForests.clear();
      debugPrint('FulaApiService: AI workspace client ready');
    } catch (e) {
      debugPrint('FulaApiService: workspace client init failed: $e');
      _workspaceClient = null;
    }
  }

  /// Lazily load a forest on the workspace client (mirrors [_ensureForestLoaded]
  /// but on `_workspaceClient`). Caller must have built the client first.
  Future<void> _ensureWorkspaceForestLoaded(String bucket) async {
    if (_workspaceLoadedForests.contains(bucket)) return;
    await fula.loadForest(client: _workspaceClient!, bucket: bucket);
    _workspaceLoadedForests.add(bucket);
  }

  /// List objects from the AI-workspace forest (mirrors [listObjects] but on
  /// the workspace client). Each returned [FulaObject] carries
  /// `sourceBucket = 'fula-ai-workspace'` so a merged native category view can
  /// badge it / route its later download to the workspace client.
  ///
  /// GATED + lazy: returns `[]` immediately when no AI connection exists. Builds
  /// the workspace client on first use. NEVER throws to the caller for an
  /// AI-side problem — a missing/erroring workspace forest yields `[]` so it can
  /// never hide the user's own content in a merged view.
  @override
  Future<List<FulaObject>> listWorkspaceObjects(
    String bucket, {
    String prefix = '',
  }) async {
    if (!await hasAiConnection()) return const <FulaObject>[];
    try {
      if (_workspaceClient == null) {
        final secret = await _deriveWorkspaceSecretForRead();
        if (secret == null) return const <FulaObject>[];
        await initializeWorkspaceClient(secret);
      }
      if (_workspaceClient == null) return const <FulaObject>[];

      await _ensureWorkspaceForestLoaded(bucket);
      final files =
          await fula.listFromForest(client: _workspaceClient!, bucket: bucket);
      final filtered = prefix.isEmpty
          ? files
          : files.where((f) => f.originalKey.startsWith(prefix)).toList();
      return filtered
          .map((meta) => FulaObject(
                key: meta.originalKey,
                size: meta.size.toInt(),
                lastModified: meta.modifiedAt != null
                    ? DateTime.fromMillisecondsSinceEpoch(
                        frbU64ToInt(meta.modifiedAt)! * 1000)
                    : null,
                isDirectory: false,
                sourceBucket: aiWorkspaceBucket,
                metadata: {
                  'storageKey': meta.storageKey,
                  'contentType': meta.contentType ?? '',
                  'isEncrypted': meta.isEncrypted.toString(),
                },
              ))
          .toList();
    } catch (e) {
      // Tolerate ANY AI-side failure (auth 403, missing bucket, decode error)
      // as empty — never let it surface into the user's category view.
      debugPrint('listWorkspaceObjects($bucket, "$prefix") → empty: $e');
      // Drop the forest memo so a transient error re-attempts next time.
      _workspaceLoadedForests.remove(bucket);
      return const <FulaObject>[];
    }
  }

  /// Download + decrypt a single object from the AI-workspace forest (mirrors
  /// [downloadObject] but on the workspace client). Used to read the AI tag doc
  /// (`ai/tag-metadata/ai-workspace.json`). GATED + lazy like
  /// [listWorkspaceObjects]; throws [FulaApiException] on a genuine read error
  /// (the tag-adoption caller catches it, so a failure never blocks restore).
  @override
  Future<Uint8List> downloadWorkspaceObject(String bucket, String key) async {
    if (!await hasAiConnection()) {
      throw FulaApiException('No AI connection — workspace download skipped');
    }
    if (_workspaceClient == null) {
      final secret = await _deriveWorkspaceSecretForRead();
      if (secret != null) await initializeWorkspaceClient(secret);
    }
    if (_workspaceClient == null) {
      throw FulaApiException('AI workspace client unavailable');
    }
    try {
      await _ensureWorkspaceForestLoaded(bucket);
      final data =
          await fula.getFlat(client: _workspaceClient!, bucket: bucket, path: key);
      return Uint8List.fromList(data);
    } catch (e) {
      _workspaceLoadedForests.remove(bucket);
      throw FulaApiException('Failed to download workspace object: $e');
    }
  }

  /// Upload + encrypt a file INTO the AI-workspace forest via the workspace
  /// client (mirrors [uploadObject] on `_workspaceClient`, forest-tracked so the
  /// object is enumerable). The GRANT primitive for moving a file INTO the AI
  /// bucket: written under the workspace secret + indexed, so the AI can list +
  /// read it. GATED + lazy like [downloadWorkspaceObject].
  @override
  Future<void> uploadWorkspaceObject(
    String bucket,
    String key,
    Uint8List bytes, {
    String? contentType,
  }) async {
    if (!await hasAiConnection()) {
      throw FulaApiException('No AI connection — workspace upload skipped');
    }
    if (_workspaceClient == null) {
      final secret = await _deriveWorkspaceSecretForRead();
      if (secret != null) await initializeWorkspaceClient(secret);
    }
    if (_workspaceClient == null) {
      throw FulaApiException('AI workspace client unavailable');
    }
    try {
      await _ensureWorkspaceForestLoaded(bucket);
      await fula.putFlat(
        client: _workspaceClient!,
        bucket: bucket,
        path: key,
        data: bytes.toList(),
        contentType: contentType,
      );
    } catch (e) {
      _workspaceLoadedForests.remove(bucket);
      throw FulaApiException('Failed to upload workspace object: $e');
    }
  }

  /// Delete an object from the AI-workspace forest via the workspace client
  /// (mirrors [deleteObject] on `_workspaceClient`). The REVOKE primitive for
  /// moving a file OUT of the AI bucket: `deleteFlat` removes BOTH the ciphertext
  /// AND the forest index entry, so a compromised MCP can no longer enumerate OR
  /// read the file.
  @override
  Future<void> deleteWorkspaceObject(String bucket, String key) async {
    if (!await hasAiConnection()) {
      throw FulaApiException('No AI connection — workspace delete skipped');
    }
    if (_workspaceClient == null) {
      final secret = await _deriveWorkspaceSecretForRead();
      if (secret != null) await initializeWorkspaceClient(secret);
    }
    if (_workspaceClient == null) {
      throw FulaApiException('AI workspace client unavailable');
    }
    try {
      await _ensureWorkspaceForestLoaded(bucket);
      await fula.deleteFlat(client: _workspaceClient!, bucket: bucket, path: key);
    } catch (e) {
      _workspaceLoadedForests.remove(bucket);
      throw FulaApiException('Failed to delete workspace object: $e');
    }
  }

  /// Re-derive the AI-workspace secret for a READ path (lazy client build).
  ///
  /// Reuses P13's [AiConnectionService.deriveWorkspaceSecret] verbatim — the
  /// SAME blake3DeriveKey-of-KEK under the load-bearing
  /// `fula:ai-workspace-secret:v1` label that produced the secret the MCP was
  /// handed at pairing. Calling it (rather than re-rolling the derivation here)
  /// guarantees the read secret matches the write secret byte-for-byte. Returns
  /// null (→ caller no-ops) if signed out / derivation fails.
  Future<Uint8List?> _deriveWorkspaceSecretForRead() async {
    try {
      return await AiConnectionService.instance.deriveWorkspaceSecret();
    } catch (e) {
      debugPrint('FulaApiService: workspace secret derivation failed: $e');
      return null;
    }
  }

  /// Dispose the AI-workspace client (call on logout / sign-out).
  void disposeWorkspaceClient() {
    _workspaceClient = null;
    _workspaceLoadedForests.clear();
    _workspaceInitFuture = null;
    debugPrint('FulaApiService: AI workspace client disposed');
  }

  /// Upload and encrypt a file.
  /// Returns an [UploadResult] with etag and optional content CID.
  Future<UploadResult> uploadObject(
    String bucket,
    String key,
    Uint8List data, {
    String? contentType,
    Map<String, String>? metadata,
  }) async {
    _guardLegacyWrite(bucket);
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);
      final result = await fula.putFlat(
        client: _client!,
        bucket: bucket,
        path: key,
        data: data.toList(),
        contentType: contentType,
      );
      return UploadResult(etag: result.etag);
    } catch (e) {
      throw FulaApiException('Failed to upload object: $e');
    }
  }

  /// Delete a file
  Future<void> deleteObject(String bucket, String key) async {
    _guardLegacyDelete(bucket);
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);
      await fula.deleteFlat(client: _client!, bucket: bucket, path: key);
    } catch (e) {
      throw FulaApiException('Failed to delete object: $e');
    }
  }

  // ============================================================================
  // ENCRYPTED OPERATIONS (Compatibility Layer)
  // These methods maintain backward compatibility with existing code
  // The encryption is now handled internally by fula_client
  // ============================================================================

  /// Download and decrypt - now just calls downloadObject
  /// The encryptionKey parameter is ignored as fula_client handles encryption internally
  Future<Uint8List> downloadAndDecrypt(
    String bucket,
    String key,
    Uint8List encryptionKey, // Ignored - kept for API compatibility
  ) async {
    return downloadObject(bucket, key);
  }

  /// P6 metadata MERGE-read: download a per-user manifest from BOTH the `-v8`
  /// sibling and the legacy bucket, returning the successfully-decrypted,
  /// non-empty blobs in priority order [v8, legacy]. The caller applies them
  /// ADDITIVELY (v8 wins a conflicting id; legacy fills gaps). When v8 routing
  /// is off / [base] is unmanaged this is just `[legacy]`. NEVER throws â€” a
  /// missing/erroring bucket is skipped, so a failed v8 read can't hide legacy.
  Future<List<Uint8List>> downloadMetadataMerged(
    String base,
    String key,
    Uint8List encryptionKey,
  ) async {
    final v8 = BucketVersionResolver.writeBucket(base);
    final buckets = v8 == base ? <String>[base] : <String>[v8, base];
    final blobs = <Uint8List>[];
    for (final bucket in buckets) {
      try {
        final d = await perfSpan('manifest-download $bucket $key',
            () => downloadAndDecrypt(bucket, key, encryptionKey));
        if (d.isNotEmpty) blobs.add(d);
      } catch (e) {
        debugPrint('downloadMetadataMerged: $bucket miss: $e');
      }
    }
    return blobs;
  }

  /// True if [e] looks like a "missing object/bucket" (404 / NoSuchKey /
  /// NoSuchBucket) rather than a hard transport/server error. The merge-read
  /// helpers use it to SKIP an absent bucket while PROPAGATING real failures.
  static bool _isNotFoundError(Object e) {
    final s = e.toString();
    return s.contains('NoSuchKey') ||
        s.contains('NoSuchBucket') ||
        s.contains('bucket not found') ||
        s.contains('404') ||
        s.contains('not found');
  }

  /// P6 metadata MERGE-read â€” the **unencrypted** sibling of
  /// [downloadMetadataMerged] (which decrypts). Downloads a per-user manifest
  /// from BOTH the `-v8` sibling and the legacy bucket via the plain
  /// [downloadObject], returning the non-empty blobs in priority order
  /// `[v8, legacy]`. Deduped to a SINGLE read when [base] is unmanaged
  /// (`writeBucket(base) == base`). The caller applies them ADDITIVELY (v8 wins
  /// a conflicting id; legacy fills gaps).
  ///
  /// A missing object/bucket (404 / NoSuchKey / NoSuchBucket) on either bucket
  /// is SKIPPED, but any HARD error is **rethrown** â€” callers that clear local
  /// state only AFTER a successful read (e.g. [CloudSyncMappingService], hazard
  /// H1) rely on this so a transient gateway error can't wipe a cache down to a
  /// partial (v8-only) set. (This is the one behavioural difference from the
  /// encrypted helper, which never throws.)
  Future<List<Uint8List>> downloadObjectMerged(String base, String key) async {
    final v8 = BucketVersionResolver.writeBucket(base);
    final buckets = v8 == base ? <String>[base] : <String>[v8, base];
    final blobs = <Uint8List>[];
    for (final bucket in buckets) {
      try {
        final d = await downloadObject(bucket, key);
        if (d.isNotEmpty) blobs.add(d);
      } catch (e) {
        if (_isNotFoundError(e)) {
          debugPrint('downloadObjectMerged: $bucket absent: $e');
          continue;
        }
        rethrow;
      }
    }
    return blobs;
  }

  /// Encrypt and upload - now just calls uploadObject with metadata
  /// The encryptionKey parameter is ignored as fula_client handles encryption internally
  Future<String> encryptAndUpload(
    String bucket,
    String key,
    Uint8List data,
    Uint8List encryptionKey, { // Ignored - kept for API compatibility
    String? originalFilename,
    String? contentType,
  }) async {
    // Use the originalFilename as the key if provided, otherwise use key
    final path = originalFilename ?? key;
    final result = await uploadObject(bucket, path, data, contentType: contentType);
    return result.etag;
  }

  // ============================================================================
  // LARGE FILE UPLOADS
  // fula_client handles chunking internally, so these are simplified
  // ============================================================================

  /// Polls the SDK's [fula.ProgressHandle] every 200ms and forwards REAL
  /// cumulative byte progress to [onProgress] while an upload future runs.
  /// Returns the timer — cancel it in a `finally`.
  ///
  /// Reported bytes are capped so the percentage never reads 100% before the
  /// upload future resolves: the SDK's cumulative bytes reach `total` at the
  /// last chunk's PUT, BEFORE the index PUT + forest-flush tail. The caller
  /// fires a final `onProgress(total, total)` only after a successful await.
  /// Unchanged ticks are skipped so the web tray doesn't repaint needlessly.
  /// Polling is best-effort — a transient FRB error never breaks the upload.
  Timer? _startProgressPoll(
    fula.ProgressHandle? handle,
    void Function(UploadProgress)? onProgress,
    int fallbackTotal,
  ) {
    if (handle == null || onProgress == null) return null;
    int lastReported = -1;
    return Timer.periodic(const Duration(milliseconds: 200), (_) async {
      try {
        final p = await fula.pollProgress(handle: handle);
        final total = frbU64ToInt(p.totalBytes) ?? 0;
        final uploaded = frbU64ToInt(p.bytesUploaded) ?? 0;
        final cap = total > 0 ? (total * 99) ~/ 100 : uploaded;
        final shown = uploaded > cap ? cap : uploaded;
        if (shown == lastReported) return;
        lastReported = shown;
        onProgress(UploadProgress(
          bytesUploaded: shown,
          totalBytes: total > 0 ? total : fallbackTotal,
        ));
      } catch (_) {
        // best-effort; the next tick retries
      }
    });
  }

  Future<String> uploadLargeFile(
    String bucket,
    String key,
    Uint8List data, {
    int chunkSize = 5 * 1024 * 1024,
    void Function(UploadProgress)? onProgress,
    Map<String, String>? metadata,
  }) async {
    _guardLegacyWrite(bucket);
    _ensureConfigured();
    Timer? poll;
    try {
      await _ensureForestLoaded(bucket);

      // Real per-chunk progress (fula-api 0.6.11): poll the handle while the
      // chunked upload runs. Small/non-chunked files emit no events — the bar
      // stays at 0% until the completion report below.
      final progressHandle =
          onProgress != null ? await fula.createProgressHandle() : null;
      poll = _startProgressPoll(progressHandle, onProgress, data.length);

      final result = progressHandle != null
          ? await fula.putFlatWithProgress(
              client: _client!,
              bucket: bucket,
              path: key,
              data: data.toList(),
              contentType: null,
              progress: progressHandle,
            )
          : await fula.putFlat(
              client: _client!,
              bucket: bucket,
              path: key,
              data: data.toList(),
              contentType: null,
            );

      // True completion (after the forest flush) -> 100%.
      if (onProgress != null) {
        onProgress(UploadProgress(
          bytesUploaded: data.length,
          totalBytes: data.length,
        ));
      }

      return result.etag;
    } catch (e) {
      throw FulaApiException('Failed to upload large file: $e');
    } finally {
      poll?.cancel();
    }
  }

  /// Like [uploadLargeFile] but cancellable mid-flight (web Sync Queue;
  /// fula-client 0.6.14 `putFlatWithProgressCancellable`). Trigger
  /// [cancelHandle] via [triggerCancel] to abort an in-progress large upload —
  /// the SDK stops between chunks, deletes the already-uploaded chunks, and
  /// throws. The error is intentionally NOT wrapped in [FulaApiException] so the
  /// caller can distinguish a cancel; callers should track their own cancel
  /// intent (a status flag) rather than string-matching the error.
  Future<String> uploadLargeFileCancellable(
    String bucket,
    String key,
    Uint8List data, {
    fula.CancelHandle? cancelHandle,
    void Function(UploadProgress)? onProgress,
  }) async {
    _guardLegacyWrite(bucket);
    _ensureConfigured();
    Timer? poll;
    try {
      await _ensureForestLoaded(bucket);
      // putFlatWithProgressCancellable requires a progress handle; always
      // create one and only poll it when the caller wants progress.
      final progressHandle = await fula.createProgressHandle();
      poll = _startProgressPoll(progressHandle, onProgress, data.length);
      final cancel = cancelHandle ?? await fula.createCancelHandle();
      final result = await fula.putFlatWithProgressCancellable(
        client: _client!,
        bucket: bucket,
        path: key,
        data: data.toList(),
        contentType: null,
        progress: progressHandle,
        cancel: cancel,
      );
      if (onProgress != null) {
        onProgress(UploadProgress(
          bytesUploaded: data.length,
          totalBytes: data.length,
        ));
      }
      return result.etag;
    } finally {
      poll?.cancel();
    }
  }

  // ── Streaming upload (fula_client 0.6.15) — memory-bounded large-file upload
  // for web. The caller (WebUploadManager) slices the file lazily from a Blob
  // and drives the two passes, so the whole file never lands in memory:
  //   begin -> planChunk x N (pass 1: commit nonces + integrity root) ->
  //   finalizePlan -> uploadChunk x N (pass 2: encrypt-from-stored-nonce + PUT)
  //   -> finish (index + forest register + flush).
  // Errors propagate raw (not wrapped in FulaApiException) so the caller can
  // distinguish a user cancel/abandon from a real failure.

  Future<fula.StreamingUploadHandle> streamingUploadBegin(
    String bucket,
    String key, {
    String? contentType,
  }) async {
    _guardLegacyWrite(bucket);
    _ensureConfigured();
    await _ensureForestLoaded(bucket);
    return fula.streamingUploadBegin(
      client: _client!,
      bucket: bucket,
      key: key,
      contentType: contentType,
    );
  }

  Future<void> streamingUploadPlanChunk(
          fula.StreamingUploadHandle handle, Uint8List bytes) =>
      fula.streamingUploadPlanChunk(handle: handle, bytes: bytes);

  Future<fula.StreamingPlanInfo> streamingUploadFinalizePlan(
          fula.StreamingUploadHandle handle) =>
      fula.streamingUploadFinalizePlan(handle: handle);

  Future<void> streamingUploadChunk(
          fula.StreamingUploadHandle handle, int chunkIndex, Uint8List bytes) =>
      fula.streamingUploadChunk(
          handle: handle, chunkIndex: chunkIndex, bytes: bytes);

  Future<void> streamingUploadFinish(fula.StreamingUploadHandle handle) async {
    await fula.streamingUploadFinish(handle: handle);
  }

  /// Upload a large file by path - avoids loading file into Dart memory
  ///
  /// The file is read on the Rust side, avoiding the FFI serialization
  /// overhead that causes OOM for very large files (1GB+).
  Future<String> uploadLargeFileFromPath(
    String bucket,
    String key,
    String filePath, {
    void Function(UploadProgress)? onProgress,
  }) async {
    _guardLegacyWrite(bucket);
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);

      // Get file size without reading the file
      final fileSize = await fileLength(filePath);

      final result = await fula.putFlatFromPath(
        client: _client!,
        bucket: bucket,
        path: key,
        filePath: filePath,
        contentType: null,
      );

      // Report completion
      if (onProgress != null) {
        onProgress(UploadProgress(
          bytesUploaded: fileSize,
          totalBytes: fileSize,
        ));
      }

      return result.etag;
    } catch (e) {
      throw FulaApiException('Failed to upload file from path: $e');
    }
  }

  /// Resumable variant of [uploadLargeFileFromPath] (Phase C, wraps
  /// `put_flat_resumable_from_path_cancellable` from fula-api#17 + #18).
  ///
  /// Writes a chunked-upload manifest at [manifestPath]. On clean
  /// completion the manifest is auto-deleted by the SDK. On failure the
  /// manifest stays on disk; call [resumeLargeFileUpload] with the same
  /// [manifestPath] and the same [filePath] to pick up where this
  /// attempt left off.
  ///
  /// When [cancelHandle] is supplied, calling
  /// `fula.cancelHandleTrigger(cancelHandle)` from another task aborts
  /// the upload cooperatively. Chunks already in flight (up to the
  /// SDK's `MAX_CONCURRENT_CHUNK_UPLOADS = 16` cap) finish; no new
  /// chunks start. The manifest survives the cancel so the user can
  /// resume later, or `abort_upload` (bridged in fula-api#20) cleans up.
  ///
  /// Bytes contract: the SDK's BAO root-hash check requires
  /// bit-identical bytes between attempts. If the user edits the file
  /// between this attempt and a subsequent [resumeLargeFileUpload], the
  /// resume fails fast with a content-hash-mismatch error.
  Future<String> uploadLargeFileResumable(
    String bucket,
    String key,
    String filePath,
    String manifestPath, {
    fula.CancelHandle? cancelHandle,
    void Function(UploadProgress)? onProgress,
  }) async {
    _guardLegacyWrite(bucket); // primary content-upload path (sync queue)
    _ensureConfigured();
    Timer? poll;
    try {
      await _ensureForestLoaded(bucket);

      final fileSize = await fileLength(filePath);

      // Real per-chunk progress (fula-api 0.6.11): poll the handle during the
      // resumable upload.
      final progressHandle =
          onProgress != null ? await fula.createProgressHandle() : null;
      poll = _startProgressPoll(progressHandle, onProgress, fileSize);

      final fula.PutResult result;
      if (progressHandle != null) {
        // The progress variant requires a CancelHandle; synthesize a
        // throwaway one (never triggered) when the caller passed none.
        final cancel = cancelHandle ?? await fula.createCancelHandle();
        result = await fula.putFlatResumableFromPathWithProgress(
          client: _client!,
          bucket: bucket,
          path: key,
          filePath: filePath,
          manifestPath: manifestPath,
          contentType: null,
          cancel: cancel,
          progress: progressHandle,
        );
      } else if (cancelHandle != null) {
        result = await fula.putFlatResumableFromPathCancellable(
          client: _client!,
          bucket: bucket,
          path: key,
          filePath: filePath,
          manifestPath: manifestPath,
          contentType: null,
          cancel: cancelHandle,
        );
      } else {
        result = await fula.putFlatResumableFromPath(
          client: _client!,
          bucket: bucket,
          path: key,
          filePath: filePath,
          manifestPath: manifestPath,
          contentType: null,
        );
      }

      if (onProgress != null) {
        onProgress(UploadProgress(
          bytesUploaded: fileSize,
          totalBytes: fileSize,
        ));
      }

      return result.etag;
    } catch (e) {
      throw FulaApiException('Failed to upload (resumable): $e');
    } finally {
      poll?.cancel();
    }
  }

  /// Resume a previously-failed resumable upload (Phase C, wraps
  /// `resume_flat_upload_from_path_cancellable` from fula-api#17 + #18).
  ///
  /// [filePath] MUST point at bytes identical to the original upload;
  /// the SDK's BAO check rejects modified content. On clean completion
  /// the manifest is auto-deleted.
  ///
  /// [cancelHandle] semantics match [uploadLargeFileResumable].
  Future<String> resumeLargeFileUpload(
    String manifestPath,
    String filePath, {
    fula.CancelHandle? cancelHandle,
    void Function(UploadProgress)? onProgress,
  }) async {
    _ensureConfigured();
    Timer? poll;
    try {
      final fileSize = await fileLength(filePath);

      // Real per-chunk progress (fula-api 0.6.11). Resume SEEDS the SDK
      // counter with already-uploaded chunks, so the bar continues mid-way.
      final progressHandle =
          onProgress != null ? await fula.createProgressHandle() : null;
      poll = _startProgressPoll(progressHandle, onProgress, fileSize);

      final fula.PutResult result;
      if (progressHandle != null) {
        // The progress variant requires a CancelHandle; synthesize a
        // throwaway one (never triggered) when the caller passed none.
        final cancel = cancelHandle ?? await fula.createCancelHandle();
        result = await fula.resumeFlatUploadFromPathWithProgress(
          client: _client!,
          manifestPath: manifestPath,
          filePath: filePath,
          cancel: cancel,
          progress: progressHandle,
        );
      } else if (cancelHandle != null) {
        result = await fula.resumeFlatUploadFromPathCancellable(
          client: _client!,
          manifestPath: manifestPath,
          filePath: filePath,
          cancel: cancelHandle,
        );
      } else {
        result = await fula.resumeFlatUploadFromPath(
          client: _client!,
          manifestPath: manifestPath,
          filePath: filePath,
        );
      }

      if (onProgress != null) {
        onProgress(UploadProgress(
          bytesUploaded: fileSize,
          totalBytes: fileSize,
        ));
      }

      return result.etag;
    } catch (e) {
      throw FulaApiException('Failed to resume upload: $e');
    } finally {
      poll?.cancel();
    }
  }

  /// Create a fresh cancel handle for a resumable upload (Phase C).
  ///
  /// Pass to [uploadLargeFileResumable] / [resumeLargeFileUpload]; call
  /// [triggerCancel] to abort cooperatively.
  @override
  Future<fula.CancelHandle> createCancelHandle() async {
    return await fula.createCancelHandle();
  }

  /// Trigger cancellation on a previously-created handle. Fire-and-
  /// forget per the interface contract â€” `cancelHandleTrigger` is
  /// async at the FRB layer but only flips an `Arc<AtomicBool>` in
  /// Rust, so the caller doesn't need to await it. `unawaited` keeps
  /// the analyzer's `discarded_futures` lint quiet.
  @override
  void triggerCancel(fula.CancelHandle handle) {
    unawaited(fula.cancelHandleTrigger(handle: handle));
  }

  /// Check whether a handle has been triggered.
  @override
  Future<bool> isCancelTriggered(fula.CancelHandle handle) async {
    return await fula.cancelHandleIsCancelled(handle: handle);
  }

  /// Discard a resumable upload's local state and best-effort delete its
  /// already-uploaded chunks on the storage backend (fula-api#20).
  ///
  /// Idempotent â€” calling on a missing manifest returns success (the
  /// "already cleaned up" case Phase C's `cancelTask` racing against
  /// the SDK's own clean-completion auto-delete may hit).
  ///
  /// Failures from the underlying `abort_upload` SDK call (malformed
  /// manifest, permission denied, etc.) are caught + logged here rather
  /// than propagated â€” the caller's intent ("ensure this upload's local
  /// state is gone, best-effort") is satisfied as long as the manifest
  /// is no longer present after this call returns. The SDK's bridge
  /// wrapper also catches the missing-manifest case as Ok, so the
  /// behavior is "idempotent best-effort cleanup."
  @override
  Future<void> abortResumableUpload(String manifestPath) async {
    if (manifestPath.isEmpty) return;
    _ensureConfigured();
    try {
      await fula.abortResumableUpload(
        client: _client!,
        manifestPath: manifestPath,
      );
    } catch (e) {
      // Log but don't propagate â€” abort is best-effort cleanup. The
      // alternative is propagating to the UI which has no reasonable
      // recovery (a stale manifest on disk is a disk-hygiene issue,
      // not a data-correctness one â€” orphan chunks are eventually
      // collected by the future GC sweep planned in fula-api Â§W.8.7).
      debugPrint('FulaApiService.abortResumableUpload: $e');
    }
  }

  /// Encrypt and upload large file - now uses fula_client's built-in encryption
  Future<String> encryptAndUploadLargeFile(
    String bucket,
    String key,
    Uint8List data,
    Uint8List encryptionKey, { // Ignored - kept for API compatibility
    String? originalFilename,
    String? contentType,
    void Function(UploadProgress)? onProgress,
  }) async {
    return uploadLargeFile(bucket, key, data, onProgress: onProgress);
  }

  // ============================================================================
  // BATCH OPERATIONS
  // ============================================================================

  /// Upload multiple files efficiently (deferred forest save)
  Future<void> uploadBatch(
    String bucket,
    List<BatchUploadItem> files,
  ) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);

      for (final file in files) {
        await fula.putFlatDeferred(
          client: _client!,
          bucket: bucket,
          path: file.path,
          data: file.data.toList(),
          contentType: file.contentType,
        );
      }

      // Save forest once after all uploads
      await fula.flushForest(client: _client!, bucket: bucket);
    } catch (e) {
      throw FulaApiException('Failed to batch upload: $e');
    }
  }

  // ============================================================================
  // SHARING
  // ============================================================================

  /// Convert local ShareMode to fula_client ShareMode
  fula.ShareMode _convertShareMode(local.ShareMode mode) {
    switch (mode) {
      case local.ShareMode.temporal:
        return fula.ShareMode.temporal;
      case local.ShareMode.snapshot:
        return fula.ShareMode.snapshot;
    }
  }

  /// Create a share token for a file
  /// Accepts local ShareMode from share_token.dart
  Future<String> createShareToken(
    String bucket,
    String storageKey,
    Uint8List recipientPublicKey,
    local.ShareMode mode,
    int? expiresAt,
  ) async {
    _ensureConfigured();
    return await fula.createShareTokenWithMode(
      client: _client!,
      bucket: bucket,
      storageKey: storageKey,
      recipientPublicKey: recipientPublicKey.toList(),
      mode: _convertShareMode(mode),
      // u64 via FRB: int natively, BigInt on web.
      expiresAt: intToFrbU64(expiresAt),
    );
  }

  /// Accept a share token
  Future<fula.AcceptedShareHandle> acceptShareToken(String tokenJson) async {
    _ensureConfigured();
    return await fula.acceptShare(client: _client!, tokenJson: tokenJson);
  }

  /// Download a shared file
  ///
  /// [originalKey] is the plaintext file path â€” used by fula_client to validate
  /// that the request is within the share's path scope.
  Future<Uint8List> downloadSharedFile(
    String bucket,
    String storageKey,
    String originalKey,
    fula.AcceptedShareHandle share,
  ) async {
    _ensureConfigured();
    final data = await fula.getWithShare(
      client: _client!,
      bucket: bucket,
      storageKey: storageKey,
      originalKey: originalKey,
      share: share,
    );
    return Uint8List.fromList(data);
  }

  /// Get share permissions (returns local SharePermissions enum)
  Future<local.SharePermissions> getSharePermissions(fula.AcceptedShareHandle share) async {
    final fulaPerms = await fula.getSharePermissions(share: share);
    // Convert fula_client SharePermissions class to local enum
    if (fulaPerms.canWrite) {
      return local.SharePermissions.full; // If can write, assume full access
    } else if (fulaPerms.canRead) {
      return local.SharePermissions.readOnly;
    }
    return local.SharePermissions.readOnly; // Default
  }

  /// Get raw share permissions from fula_client
  Future<fula.SharePermissions> getRawSharePermissions(fula.AcceptedShareHandle share) async {
    return await fula.getSharePermissions(share: share);
  }

  /// Check if share is expired
  Future<bool> isShareExpired(fula.AcceptedShareHandle share) async {
    return await fula.isShareExpired(share: share);
  }

  // ============================================================================
  // KEY ROTATION
  // ============================================================================

  /// Create a rotation manager for key rotation
  Future<fula.RotationManagerHandle> createRotationManager() async {
    _ensureConfigured();
    return await fula.createRotationManager(client: _client!);
  }

  /// Rotate all keys in a bucket
  Future<fula.RotationReport> rotateBucket(
    String bucket,
    fula.RotationManagerHandle manager,
  ) async {
    _ensureConfigured();
    return await fula.rotateBucket(client: _client!, bucket: bucket, manager: manager);
  }

  // ============================================================================
  // INCOMPLETE UPLOADS (Compatibility - may not be needed with fula_client)
  // ============================================================================

  Future<List<IncompleteUploadInfo>> listIncompleteUploads(
    String bucket,
    String prefix,
  ) async {
    // fula_client handles multipart internally
    // Return empty list for compatibility
    return [];
  }

  Future<void> removeIncompleteUpload(
    String bucket,
    String key,
    String uploadId,
  ) async {
    // No-op for fula_client
  }

  // ============================================================================
  // PRESIGNED URLs (Not supported with encrypted client)
  // ============================================================================

  Future<String> getPresignedDownloadUrl(
    String bucket,
    String key, {
    int expirySeconds = 3600,
  }) async {
    throw FulaApiException(
      'Presigned URLs are not supported with encrypted storage. '
      'Use sharing tokens instead.'
    );
  }

  // ============================================================================
  // CLEANUP
  // ============================================================================

  /// Reset the service (call on logout)
  void reset() {
    _client = null;
    _defaultBucket = null;
    _isConfigured = false;
    _loadedForests.clear();
    _currentSecretKey = null;
    _cloudEndpoint = null;
    _cloudAccessToken = null;
    _isLocalEndpoint = false;
    disposeLocalClient();
    disposeWorkspaceClient();
  }

  /// Decode the `sub` claim from a JWT WITHOUT verifying the signature.
  ///
  /// Used at SDK init to compute the cold-start userKey directly from
  /// the JWT sub (matches master's hashing exactly). Signature
  /// verification is master's job â€” this client-side decode is purely
  /// to read the sub value the master ALREADY validated when issuing
  /// the token. Returns null on any malformed input; the caller falls
  /// back to email-based derivation.
  ///
  /// JWT format: `header.payload.signature` where each part is
  /// base64url-encoded. Payload is JSON. We extract the `sub` field.
  static String? _extractJwtSub(String? jwt) {
    if (jwt == null || jwt.isEmpty) return null;
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return null;
      var payload = parts[1];
      // base64url decode requires `=` padding to a multiple of 4.
      // Add as many `=` as needed.
      final pad = (4 - payload.length % 4) % 4;
      payload = payload + ('=' * pad);
      final decoded = utf8.decode(base64Url.decode(payload));
      final json = jsonDecode(decoded);
      if (json is! Map) return null;
      final sub = json['sub'];
      if (sub is! String) return null;
      return sub.isEmpty ? null : sub;
    } catch (_) {
      return null;
    }
  }
}

// ============================================================================
// HELPER CLASSES
// ============================================================================

// Helper classes (UploadResult, UploadProgress, BatchUploadItem,
// IncompleteUploadInfo, FulaApiException) moved to fula_api_types.dart
// so the abstract FulaApi surface and concrete FulaApiService can share
// them without a cycle. The `export` declaration at the top of this
// file keeps backward-compat with callers that import them from here.
