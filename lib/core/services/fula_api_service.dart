import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:fula_client/fula_client.dart' as fula;
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/models/share_token.dart' as local;
import 'package:fula_files/core/services/bucket_cache_service.dart';
import 'package:fula_files/core/services/object_cache_service.dart';
import 'package:fula_files/core/services/fula_api.dart';
import 'package:fula_files/core/services/fula_api_types.dart';

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
// it and the SDK falls back to warm-cache only — that is the current state.
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
// can still set one via Settings → Fula API Config; the Settings screen
// keeps that override path.
//
// Prior contents (kept commented for archaeology):
//   'https://{name}.ipns.dget.top/'      — small fleet, less reliable
//                                          uptime than the Protocol Labs
//                                          / Filebase tier.
//   'https://ipfs.filebase.io/ipns/{name}/' — path-style; same staleness
//                                          class as dweb.link path-style
//                                          when behind Cloudflare.
//
// Neither of those was `ipfs.io` — the gateway that survived the audit.
const List<String> kUsersIndexIpnsGatewayUrls = <String>[];
// 128 MiB cap — half the SDK default. Mobile devices have tighter storage
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

  // Saved credentials for endpoint switching
  Uint8List? _currentSecretKey;
  String? _cloudEndpoint;
  String? _cloudAccessToken;
  bool _isLocalEndpoint = false;

  // Local blox client for download-only (LAN-first reads)
  fula.EncryptedClientHandle? _localClient;
  String? _localEndpoint;
  final Set<String> _localLoadedForests = {};

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
    /// E2E plan Phase 5 — 32-byte AEAD key for encrypting the
    /// per-user bucketsIndex envelope (`K_index`). Pass `null` (or
    /// an empty list) for Mode A users; the SDK keeps using today's
    /// plaintext path.
    Uint8List? bucketsIndexKey,
    /// E2E plan Phase 5 — 32-byte Ed25519 seed for signing the
    /// per-user entry (`K_entry_seed`). Pass `null` for Mode A users.
    Uint8List? userEntrySigningSeed,
  }) async {
    try {
      // Derive the per-user cold-start key. Try the JWT-sub-based
      // derivation FIRST — it matches master's `state.rs::hash_user_id`
      // byte-for-byte and works correctly for BOTH pre-migration-011
      // users (whose JWT sub is plaintext email) and modern users
      // (whose JWT sub is `sha256(email).hex()`). The legacy
      // `deriveUserKeyFromEmail` always pre-hashes with sha256, which
      // matches master only for modern users — for pre-migration users
      // it produces the wrong userKey and cold-start lookup misses
      // ("user has not written yet" error even when they have).
      //
      // Wrap in try/catch — a derivation failure must NOT prevent
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
        // legacy v7 pointers — making them offline-unreachable on
        // fresh devices. Cloud client = always on.
        walkableV8WriterEnabled: true,
        // E2E plan Phase 5 — per-user encrypted bucketsIndex keys.
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
  /// by integration tests** to simulate online ↔ offline transitions
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
        'initialized — sign in on the device before running '
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
  /// offline-propagation regression — narrowed `Err(_)` to
  /// `Err(e) if e.is_not_found()`), the catch branch fires only for
  /// real errors:
  ///
  ///   - **Master unreachable / cold-start failed / 5xx / network** —
  ///     offline or transient outage. Don't mark as loaded; rethrow so
  ///     the caller surfaces "offline; try later" instead of an empty
  ///     list (the prior `_loadedForests.add` on every catch silently
  ///     painted offline outages as empty buckets — exactly the bug
  ///     this pairs with).
  ///   - **Auth / decrypt / sequence-regression** — real errors that
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
      await fula.loadForest(client: _client!, bucket: bucket);
      _loadedForests.add(bucket);
      debugPrint('Forest loaded for bucket: $bucket');
    } catch (e) {
      // Don't mark `_loadedForests.add(bucket)` here — the next call
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
  /// cannot enumerate buckets offline (privacy invariant — see
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
        // No cache to serve — surface the original error, not the retry one,
        // since the first failure is the more representative diagnostic.
        throw firstErr;
      }
    }
  }

  Future<void> createBucket(String bucket) async {
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
  /// doc). Do **not** swap this for `fula.listDecrypted` — that is a
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
        // No cache to serve — surface the original error.
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

      final files = await fula.listFromForest(
        client: _client!,
        bucket: bucket,
      );

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
            ? DateTime.fromMillisecondsSinceEpoch(meta.modifiedAt! * 1000)
            : null,
        isDirectory: false,
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
            ? DateTime.fromMillisecondsSinceEpoch(file.modifiedAt! * 1000)
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
  /// Used exclusively for reads — uploads always go through the cloud [_client].
  Future<void> initializeLocalClient({
    required String endpoint,
    required String accessToken,
  }) async {
    if (_currentSecretKey == null) {
      debugPrint('FulaApiService: Cannot init local client — not logged in');
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
        // Gateway fallback stays OFF — when the LAN endpoint fails, the
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
        // Cold-start does not apply to the LAN client — it is configured
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
        // with cloud-uploaded ones — a single content-addressed
        // forest works regardless of which client wrote it.
        walkableV8WriterEnabled: true,
        // E2E plan Phase 5 — encrypted bucketsIndex keys are scoped
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

    // Fast path: no local client → straight to cloud
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

  /// Dispose the local blox client (e.g. on unpair or blox goes offline).
  void disposeLocalClient() {
    _localClient = null;
    _localEndpoint = null;
    _localLoadedForests.clear();
    debugPrint('FulaApiService: local blox client disposed');
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

  Future<String> uploadLargeFile(
    String bucket,
    String key,
    Uint8List data, {
    int chunkSize = 5 * 1024 * 1024,
    void Function(UploadProgress)? onProgress,
    Map<String, String>? metadata,
  }) async {
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);

      // fula_client handles large files automatically
      // Progress callback not yet supported in fula_client - upload directly
      final result = await fula.putFlat(
        client: _client!,
        bucket: bucket,
        path: key,
        data: data.toList(),
        contentType: null,
      );

      // Report completion
      if (onProgress != null) {
        onProgress(UploadProgress(
          bytesUploaded: data.length,
          totalBytes: data.length,
        ));
      }

      return result.etag;
    } catch (e) {
      throw FulaApiException('Failed to upload large file: $e');
    }
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
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);

      // Get file size without reading the file
      final fileSize = await File(filePath).length();

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
    _ensureConfigured();
    try {
      await _ensureForestLoaded(bucket);

      final fileSize = await File(filePath).length();

      final result = cancelHandle != null
          ? await fula.putFlatResumableFromPathCancellable(
              client: _client!,
              bucket: bucket,
              path: key,
              filePath: filePath,
              manifestPath: manifestPath,
              contentType: null,
              cancel: cancelHandle,
            )
          : await fula.putFlatResumableFromPath(
              client: _client!,
              bucket: bucket,
              path: key,
              filePath: filePath,
              manifestPath: manifestPath,
              contentType: null,
            );

      if (onProgress != null) {
        onProgress(UploadProgress(
          bytesUploaded: fileSize,
          totalBytes: fileSize,
        ));
      }

      return result.etag;
    } catch (e) {
      throw FulaApiException('Failed to upload (resumable): $e');
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
    try {
      final fileSize = await File(filePath).length();

      final result = cancelHandle != null
          ? await fula.resumeFlatUploadFromPathCancellable(
              client: _client!,
              manifestPath: manifestPath,
              filePath: filePath,
              cancel: cancelHandle,
            )
          : await fula.resumeFlatUploadFromPath(
              client: _client!,
              manifestPath: manifestPath,
              filePath: filePath,
            );

      if (onProgress != null) {
        onProgress(UploadProgress(
          bytesUploaded: fileSize,
          totalBytes: fileSize,
        ));
      }

      return result.etag;
    } catch (e) {
      throw FulaApiException('Failed to resume upload: $e');
    }
  }

  /// Create a fresh cancel handle for a resumable upload (Phase C).
  ///
  /// Pass to [uploadLargeFileResumable] / [resumeLargeFileUpload]; call
  /// [triggerCancel] to abort cooperatively.
  fula.CancelHandle createCancelHandle() {
    return fula.createCancelHandle();
  }

  /// Trigger cancellation on a previously-created handle.
  void triggerCancel(fula.CancelHandle handle) {
    fula.cancelHandleTrigger(handle: handle);
  }

  /// Check whether a handle has been triggered.
  bool isCancelTriggered(fula.CancelHandle handle) {
    return fula.cancelHandleIsCancelled(handle: handle);
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
      expiresAt: expiresAt,
    );
  }

  /// Accept a share token
  Future<fula.AcceptedShareHandle> acceptShareToken(String tokenJson) async {
    _ensureConfigured();
    return await fula.acceptShare(client: _client!, tokenJson: tokenJson);
  }

  /// Download a shared file
  ///
  /// [originalKey] is the plaintext file path — used by fula_client to validate
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
  }

  /// Decode the `sub` claim from a JWT WITHOUT verifying the signature.
  ///
  /// Used at SDK init to compute the cold-start userKey directly from
  /// the JWT sub (matches master's hashing exactly). Signature
  /// verification is master's job — this client-side decode is purely
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
