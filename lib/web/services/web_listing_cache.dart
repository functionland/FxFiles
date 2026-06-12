import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/web/services/web_cache_hkdf.dart';

/// L1/L2 cache behind the web SWR read path
/// (docs/web-listing-prefetch-cache-plan.md §5).
///
/// L2 = Hive box `web_listing_cache_v1` (IndexedDB). Every value is
/// `nonce(12) || AES-GCM(ciphertext+tag)` under a key derived from the
/// session KEK via HKDF — filenames are user content in an E2E product
/// and IndexedDB is plaintext on disk. Encryption runs through
/// `crypto.subtle` (system crypto; the wasm/Dart paths are 2-4× slower
/// on low-end phones). The KEK itself never crosses into WebCrypto:
/// only the HKDF-derived cache key is imported, non-extractable.
///
/// L1 = session maps above L2, so back-navigation and widget rebuilds
/// never re-read + re-decrypt IndexedDB.
///
/// Keys are `<ownerHash>|cat|<bucket>` / `<ownerHash>|man|<bucket>|<objectKey>`
/// — owner-scoped like BucketCacheService; a different signer's entries
/// also fail AES-GCM authentication (wrong KEK) and read as misses.
/// Reads NEVER throw: any miss / mismatch / undecryptable / evicted
/// entry is just `null` (browsers may clear IndexedDB under pressure).
class WebListingCache {
  WebListingCache._();
  static final WebListingCache instance = WebListingCache._();

  static const String boxName = 'web_listing_cache_v1';
  static const int schemaVersion = 1;

  Box<Uint8List>? _box;
  web.CryptoKey? _aesKey;
  String? _aesKeyOwner;

  final Map<String, ({List<FulaObject> objects, DateTime fetchedAt})>
      _l1Listings = {};

  /// `blob == null` means "cached absence" (the manifest is known not
  /// to exist) — distinct from an outer `null` return (cache miss).
  final Map<String, ({Uint8List? blob, DateTime fetchedAt})> _l1Manifests =
      {};

  final Random _rng = Random.secure();

  // ------------------------------------------------------------ keys

  static String listingKey(String owner, String bucket) =>
      '$owner|cat|$bucket';
  static String manifestKey(String owner, String bucket, String objectKey) =>
      '$owner|man|$bucket|$objectKey';

  /// Same identity rule as BucketCacheService/ObjectCacheService.
  Future<String?> ownerHash() async {
    final email = await SecureStorageService.instance
        .read(SecureStorageKeys.derivationEmail);
    if (email == null || email.isEmpty) return null;
    final digest = sha256.convert(utf8.encode(email)).bytes;
    return base64UrlEncode(digest).substring(0, 16);
  }

  Future<Box<Uint8List>> _openBox() async {
    final existing = _box;
    if (existing != null && existing.isOpen) return existing;
    final box = await Hive.openBox<Uint8List>(boxName);
    _box = box;
    return box;
  }

  /// HKDF(KEK) → non-extractable AES-GCM-256 CryptoKey, cached per
  /// owner so a user switch in the same tab re-derives.
  Future<web.CryptoKey?> _cacheKey(String owner) async {
    if (_aesKey != null && _aesKeyOwner == owner) return _aesKey;
    final kekB64 = await SecureStorageService.instance
        .read(SecureStorageKeys.encryptionKey);
    if (kekB64 == null || kekB64.isEmpty) return null;
    final raw = hkdfSha256(
      base64Decode(kekB64),
      salt: utf8.encode('fxfiles-web-listing-cache-salt-v1'),
      info: utf8.encode('web-listing-cache-v1'),
    );
    final key = await web.window.crypto.subtle
        .importKey(
          'raw',
          raw.toJS,
          'AES-GCM'.toJS,
          false,
          ['encrypt'.toJS, 'decrypt'.toJS].toJS,
        )
        .toDart;
    _aesKey = key;
    _aesKeyOwner = owner;
    return key;
  }

  /// [aad] binds the ciphertext to its cache slot (the entry key):
  /// an entry copied/swapped to a different key fails authentication
  /// instead of decrypting as the wrong bucket's listing.
  JSObject _gcmParams(Uint8List nonce, String aad) {
    final alg = JSObject();
    alg.setProperty('name'.toJS, 'AES-GCM'.toJS);
    alg.setProperty('iv'.toJS, nonce.toJS);
    alg.setProperty('additionalData'.toJS,
        Uint8List.fromList(utf8.encode(aad)).toJS);
    return alg;
  }

  Future<Uint8List> _encrypt(
      web.CryptoKey key, String entryKey, Uint8List plain) async {
    final nonce = Uint8List.fromList(
        List<int>.generate(12, (_) => _rng.nextInt(256)));
    final buf = await web.window.crypto.subtle
        .encrypt(_gcmParams(nonce, entryKey), key, plain.toJS)
        .toDart;
    final ct = (buf as JSArrayBuffer).toDart.asUint8List();
    final out = Uint8List(nonce.length + ct.length);
    out.setAll(0, nonce);
    out.setAll(nonce.length, ct);
    return out;
  }

  Future<Uint8List?> _decrypt(
      web.CryptoKey key, String entryKey, Uint8List value) async {
    if (value.length < 13) return null;
    try {
      final nonce = Uint8List.sublistView(value, 0, 12);
      final ct = Uint8List.sublistView(value, 12);
      final buf = await web.window.crypto.subtle
          .decrypt(_gcmParams(nonce, entryKey), key, ct.toJS)
          .toDart;
      return (buf as JSArrayBuffer).toDart.asUint8List();
    } catch (_) {
      // Wrong key (other user), wrong slot (AAD), or corrupted entry —
      // a miss, never an error.
      return null;
    }
  }

  // ------------------------------------------------------- listings

  Future<({List<FulaObject> objects, DateTime fetchedAt})?> readListing(
      String bucket) async {
    try {
      final owner = await ownerHash();
      if (owner == null) return null;
      final k = listingKey(owner, bucket);
      final l1 = _l1Listings[k];
      if (l1 != null) return l1;

      final key = await _cacheKey(owner);
      if (key == null) return null;
      final raw = (await _openBox()).get(k);
      if (raw == null) return null;
      final plain = await _decrypt(key, k, raw);
      if (plain == null) return null;
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      if (json['v'] != schemaVersion || json['kind'] != 'listing') {
        return null;
      }
      final fetchedAt = DateTime.tryParse(json['fetchedAt'] as String? ?? '');
      final rawObjects = json['objects'];
      if (fetchedAt == null || rawObjects is! List) return null;
      final objects = rawObjects
          .whereType<Map>()
          .map((m) => _objectFromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false);
      final entry = (objects: objects, fetchedAt: fetchedAt);
      _l1Listings[k] = entry;
      return entry;
    } catch (e) {
      debugPrint('WebListingCache.readListing($bucket) miss: $e');
      return null;
    }
  }

  /// [fetchedAt] should be stamped at FETCH START by callers whose data
  /// comes from the network — the monotonic guard below compares it, so
  /// a slow revalidation that finishes AFTER a forced mutation write
  /// can't regress the cache to pre-mutation data (Gemini-flagged
  /// last-writer-wins race). [allowOlder] is a harness-only override
  /// for tests that need to plant an aged entry.
  Future<void> writeListing(String bucket, List<FulaObject> objects,
      {DateTime? fetchedAt, bool allowOlder = false}) async {
    try {
      final owner = await ownerHash();
      if (owner == null) return;
      final key = await _cacheKey(owner);
      if (key == null) return;
      final at = fetchedAt ?? DateTime.now();
      if (!allowOlder) {
        final existing = await readListing(bucket);
        if (existing != null && existing.fetchedAt.isAfter(at)) {
          debugPrint('WebListingCache.writeListing($bucket): kept newer '
              'entry (${existing.fetchedAt} > $at)');
          return;
        }
      }
      final k = listingKey(owner, bucket);
      final plain = utf8.encode(jsonEncode({
        'v': schemaVersion,
        'kind': 'listing',
        'fetchedAt': at.toIso8601String(),
        'objects': objects.map(objectToJson).toList(),
      }));
      final value = await _encrypt(key, k, Uint8List.fromList(plain));
      await (await _openBox()).put(k, value);
      _l1Listings[k] = (objects: List.unmodifiable(objects), fetchedAt: at);
    } catch (e) {
      debugPrint('WebListingCache.writeListing($bucket) skipped: $e');
    }
  }

  // ------------------------------------------------------ manifests

  Future<({Uint8List? blob, DateTime fetchedAt})?> readManifest(
      String bucket, String objectKey) async {
    try {
      final owner = await ownerHash();
      if (owner == null) return null;
      final k = manifestKey(owner, bucket, objectKey);
      final l1 = _l1Manifests[k];
      if (l1 != null) return l1;

      final key = await _cacheKey(owner);
      if (key == null) return null;
      final raw = (await _openBox()).get(k);
      if (raw == null) return null;
      final plain = await _decrypt(key, k, raw);
      if (plain == null) return null;
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      if (json['v'] != schemaVersion || json['kind'] != 'manifest') {
        return null;
      }
      final fetchedAt = DateTime.tryParse(json['fetchedAt'] as String? ?? '');
      if (fetchedAt == null) return null;
      final present = json['present'] == true;
      final blob =
          present ? base64Decode(json['blob'] as String? ?? '') : null;
      final entry = (blob: blob, fetchedAt: fetchedAt);
      _l1Manifests[k] = entry;
      return entry;
    } catch (e) {
      debugPrint('WebListingCache.readManifest($bucket/$objectKey) miss: $e');
      return null;
    }
  }

  /// [blob] null records a confirmed absence (negative cache). Same
  /// monotonic [fetchedAt] guard as [writeListing] — write-through
  /// callers (manifest uploads) default to now, which always wins.
  Future<void> writeManifest(
      String bucket, String objectKey, Uint8List? blob,
      {DateTime? fetchedAt}) async {
    try {
      final owner = await ownerHash();
      if (owner == null) return;
      final key = await _cacheKey(owner);
      if (key == null) return;
      final at = fetchedAt ?? DateTime.now();
      final existing = await readManifest(bucket, objectKey);
      if (existing != null && existing.fetchedAt.isAfter(at)) {
        debugPrint(
            'WebListingCache.writeManifest($bucket/$objectKey): kept '
            'newer entry');
        return;
      }
      final k = manifestKey(owner, bucket, objectKey);
      final plain = utf8.encode(jsonEncode({
        'v': schemaVersion,
        'kind': 'manifest',
        'fetchedAt': at.toIso8601String(),
        'present': blob != null,
        if (blob != null) 'blob': base64Encode(blob),
      }));
      final value = await _encrypt(key, k, Uint8List.fromList(plain));
      await (await _openBox()).put(k, value);
      _l1Manifests[k] = (blob: blob, fetchedAt: at);
    } catch (e) {
      debugPrint(
          'WebListingCache.writeManifest($bucket/$objectKey) skipped: $e');
    }
  }

  // ------------------------------------------------------ usage log

  /// Plaintext frecency sidecar for the prefetch queue (plan §6.1):
  /// `<owner>|usage` → {screenKey: {n, last}}. Contains only fixed
  /// screen identifiers (cat|images-v8, man|tag-metadata…) — no user
  /// content — so it deliberately skips the crypto path.
  static const int _usageMaxEntries = 40;

  Future<void> recordUsage(String screenKey) async {
    try {
      final owner = await ownerHash();
      if (owner == null) return;
      final box = await _openBox();
      final k = '$owner|usage';
      Map<String, dynamic> usage = {};
      final raw = box.get(k);
      if (raw != null) {
        try {
          usage = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
        } catch (_) {}
      }
      final prev = usage[screenKey];
      final n = (prev is Map ? (prev['n'] as num?)?.toInt() : null) ?? 0;
      usage[screenKey] = {
        'n': n + 1,
        'last': DateTime.now().toIso8601String(),
      };
      if (usage.length > _usageMaxEntries) {
        final entries = usage.entries.toList()
          ..sort((a, b) {
            final la = DateTime.tryParse(
                    (a.value as Map)['last'] as String? ?? '') ??
                DateTime(2000);
            final lb = DateTime.tryParse(
                    (b.value as Map)['last'] as String? ?? '') ??
                DateTime(2000);
            return lb.compareTo(la);
          });
        usage = Map.fromEntries(entries.take(_usageMaxEntries));
      }
      await box.put(
          k, Uint8List.fromList(utf8.encode(jsonEncode(usage))));
    } catch (e) {
      debugPrint('WebListingCache.recordUsage skipped: $e');
    }
  }

  /// screenKey → (count, lastAt); empty on any failure.
  Future<Map<String, ({int n, DateTime lastAt})>> readUsage() async {
    try {
      final owner = await ownerHash();
      if (owner == null) return const {};
      final raw = (await _openBox()).get('$owner|usage');
      if (raw == null) return const {};
      final json = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      final out = <String, ({int n, DateTime lastAt})>{};
      for (final e in json.entries) {
        final v = e.value;
        if (v is! Map) continue;
        final lastAt = DateTime.tryParse(v['last'] as String? ?? '');
        if (lastAt == null) continue;
        out[e.key] = (n: (v['n'] as num?)?.toInt() ?? 0, lastAt: lastAt);
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  // ------------------------------------------------------- lifecycle

  /// Drop everything (sign-out wiring lands in P3; provided now so the
  /// e2e harness and early callers have it).
  Future<void> clearAll() async {
    _l1Listings.clear();
    _l1Manifests.clear();
    _aesKey = null;
    _aesKeyOwner = null;
    try {
      final box = _box;
      if (box != null && box.isOpen) {
        await box.deleteFromDisk();
      } else {
        await Hive.deleteBoxFromDisk(boxName);
      }
    } catch (e) {
      debugPrint('WebListingCache.clearAll: $e');
    }
    _box = null;
  }

  /// Harness hook (unit tests + the e2e=swr gate runs): force the next
  /// read to hit L2 (the decrypt path). Production code has no reason
  /// to call this — L1 is invalidated through writes.
  void clearL1() {
    _l1Listings.clear();
    _l1Manifests.clear();
  }

  // ------------------------------------------------------------ json

  /// Same shape as ObjectCacheService's serializer plus sourceBucket
  /// (the SWR path serves listings that screens use without a re-tag).
  static Map<String, dynamic> objectToJson(FulaObject obj) => {
        'key': obj.key,
        'size': obj.size,
        'lastModified': obj.lastModified?.toIso8601String(),
        'etag': obj.etag,
        'isDirectory': obj.isDirectory,
        'metadata': obj.metadata,
        'sourceBucket': obj.sourceBucket,
      };

  static FulaObject _objectFromJson(Map<String, dynamic> json) => FulaObject(
        key: json['key'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        lastModified: json['lastModified'] is String
            ? DateTime.tryParse(json['lastModified'] as String)
            : null,
        etag: json['etag'] as String?,
        isDirectory: json['isDirectory'] as bool? ?? false,
        sourceBucket: json['sourceBucket'] as String?,
        metadata: json['metadata'] is Map
            ? Map<String, String>.from(
                (json['metadata'] as Map).map(
                  (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
                ),
              )
            : null,
      );
}
