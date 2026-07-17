import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/web/services/web_cache_hkdf.dart';
import 'package:fula_files/web/utils/web_thumbnail_gen.dart';

/// The sibling bucket that holds thumbnails for source bucket [bucket].
String thumbsBucketFor(String bucket) => '$bucket-thumbs';

/// True if [bucket] is a thumbnails sidecar bucket (hidden from the UI).
bool isThumbsBucket(String bucket) => bucket.endsWith('-thumbs');

/// Lazy, concurrency-capped, cached fetcher for grid image thumbnails.
///
/// A thumbnail lives at the SAME key in a sibling `<bucket>-thumbs` bucket (a
/// tiny ~10 KB encrypted JPEG). [get] returns it from an in-memory LRU → an
/// AES-GCM-encrypted IndexedDB cache → a network fetch of the sidecar, gating
/// network fetches through a small concurrency queue and de-duping in-flight
/// requests. A missing sidecar is remembered (negative cache) so fast
/// re-scrolls don't re-fetch. The grid NEVER downloads the full file — a miss
/// just shows an icon. Crypto mirrors [WebRecentFilesService] (separate box +
/// salt) — TODO: factor a shared encrypted-blob box.
class WebThumbnailService {
  WebThumbnailService._();
  static final WebThumbnailService instance = WebThumbnailService._();

  static const String boxName = 'web_thumb_cache_v1';
  static const int _memCap = 500;
  static const int _maxConcurrent = 5;

  final LinkedHashMap<String, Uint8List> _mem = LinkedHashMap();
  final Set<String> _missing = <String>{};
  // Buckets with no `-thumbs` sibling yet → skip ALL their keys, so a
  // pre-feature bucket doesn't fire one doomed fetch per visible image.
  final Set<String> _missingBuckets = <String>{};
  final Map<String, Future<Uint8List?>> _inflight = {};

  int _active = 0;
  final ListQueue<Completer<void>> _waiters = ListQueue();

  Box<Uint8List>? _box;
  web.CryptoKey? _aesKey;
  String? _aesKeyOwner;
  final Random _rng = Random.secure();

  String _ck(String bucket, String key) => '$bucket|$key';

  /// Synchronous in-memory peek — for a widget's initState (instant hit).
  Uint8List? peek(String bucket, String key) => _mem[_ck(bucket, key)];

  /// Thumbnail for ([bucket],[key]) or null (→ caller shows an icon).
  Future<Uint8List?> get(String bucket, String key) {
    final ck = _ck(bucket, key);
    final mem = _mem.remove(ck);
    if (mem != null) {
      _mem[ck] = mem; // LRU touch
      return Future.value(mem);
    }
    if (_missingBuckets.contains(bucket) || _missing.contains(ck)) {
      return Future.value(null);
    }
    final existing = _inflight[ck];
    if (existing != null) return existing;
    final fut = _resolve(bucket, key, ck);
    _inflight[ck] = fut;
    fut.whenComplete(() => _inflight.remove(ck));
    return fut;
  }

  Future<Uint8List?> _resolve(String bucket, String key, String ck) async {
    final cached = await _diskGet(bucket, key);
    if (cached != null) {
      _memPut(ck, cached);
      return cached;
    }
    await _acquire();
    try {
      // Bounded so a slow/missing thumb can't wedge a concurrency slot (and
      // contend with the real downloadObject path). The listing cache uses 10s.
      final bytes = await FulaApiService.instance
          .downloadObject(thumbsBucketFor(bucket), key)
          .timeout(const Duration(seconds: 10));
      _memPut(ck, bytes);
      unawaited(_diskPut(bucket, key, bytes));
      return bytes;
    } catch (e) {
      // No `-thumbs` bucket yet → mark the WHOLE bucket absent (kills the
      // per-image doomed-fetch burst on first view of a pre-feature bucket).
      // Any other error / timeout → just this key. Either way → icon.
      final msg = '$e';
      if (msg.contains('NoSuchBucket') || msg.contains('bucket not found')) {
        _missingBuckets.add(bucket);
      } else {
        _missing.add(ck);
      }
      return null;
    } finally {
      _release();
    }
  }

  /// Seed the cache from already-decoded bytes (upload / on-view backfill).
  void put(String bucket, String key, Uint8List thumb) {
    final ck = _ck(bucket, key);
    _missing.remove(ck);
    _missingBuckets.remove(bucket); // a thumb now exists → re-probe this bucket
    _memPut(ck, thumb);
    unawaited(_diskPut(bucket, key, thumb));
  }

  /// Drop a cached thumbnail (file deleted / moved). Best-effort, local only.
  void evict(String bucket, String key) {
    final ck = _ck(bucket, key);
    _mem.remove(ck);
    _missing.remove(ck);
    unawaited(_diskDelete(bucket, key));
  }

  /// Delete the cloud thumbnail sidecar + local caches. Best-effort.
  Future<void> deleteCloudThumb(String bucket, String key) async {
    evict(bucket, key);
    try {
      await FulaApiService.instance.deleteObject(thumbsBucketFor(bucket), key);
    } catch (_) {/* no thumb / bucket not writable — fine */}
  }

  /// Move the cloud thumbnail to follow a renamed/moved file. Best-effort:
  /// copy the small thumb to the dest `-thumbs` bucket, then remove the src.
  /// If anything fails the dest simply regenerates its thumbnail on next view.
  Future<void> moveCloudThumb(
      String srcBucket, String srcKey, String dstBucket, String dstKey) async {
    try {
      final bytes = await FulaApiService.instance
          .downloadObject(thumbsBucketFor(srcBucket), srcKey);
      final dstThumbsBucket = thumbsBucketFor(dstBucket);
      try {
        await FulaApiService.instance.uploadObject(dstThumbsBucket, dstKey, bytes);
      } catch (e) {
        if (e.toString().contains('NoSuchBucket')) {
          await FulaApiService.instance.createBucket(dstThumbsBucket);
          await FulaApiService.instance.uploadObject(dstThumbsBucket, dstKey, bytes);
        } else {
          rethrow;
        }
      }
      put(dstBucket, dstKey, bytes);
    } catch (_) {/* no src thumb / dest not writable */}
    await deleteCloudThumb(srcBucket, srcKey);
  }

  /// On-view backfill: a file's full bytes are already decoded (it was opened),
  /// so generate + cache its thumbnail, and — only for the user's own writable
  /// bucket — upload the sidecar so the grid shows it next time. Best-effort;
  /// never writes to a read-only/legacy bucket.
  Future<void> backfillFromBytes(
      String bucket, String key, String name, Uint8List fullBytes) async {
    try {
      if (isThumbsBucket(bucket) ||
          !isThumbnailableImage(name) ||
          fullBytes.length > kThumbMaxSourceBytes) {
        return;
      }
      final thumb = await generateImageThumbnail(fullBytes);
      if (thumb == null) return;
      put(bucket, key, thumb); // local cache → shows on next view
      if (!BucketVersionResolver.isForbiddenWriteTarget(bucket)) {
        final tb = thumbsBucketFor(bucket);
        try {
          await FulaApiService.instance.uploadObject(tb, key, thumb);
        } catch (e) {
          if (e.toString().contains('NoSuchBucket')) {
            await FulaApiService.instance.createBucket(tb);
            await FulaApiService.instance.uploadObject(tb, key, thumb);
          } else {
            rethrow;
          }
        }
      }
    } catch (e) {
      debugPrint('WebThumbnailService.backfillFromBytes: $e');
    }
  }

  void _memPut(String ck, Uint8List bytes) {
    _mem.remove(ck);
    _mem[ck] = bytes;
    while (_mem.length > _memCap) {
      _mem.remove(_mem.keys.first);
    }
  }

  // ---- concurrency gate (counting semaphore, slot handed off on release) ----
  Future<void> _acquire() async {
    if (_active < _maxConcurrent) {
      _active++;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    await c.future; // a released slot was handed to us; _active already counts it
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(); // transfer the slot (active unchanged)
    } else {
      _active--;
    }
  }

  // ---- encrypted IndexedDB (same scheme as WebRecentFilesService) ----
  Future<String?> _ownerHash() async {
    final email = await SecureStorageService.instance
        .read(SecureStorageKeys.derivationEmail);
    if (email == null || email.isEmpty) return null;
    final digest = sha256.convert(utf8.encode(email)).bytes;
    return base64UrlEncode(digest).substring(0, 16);
  }

  Future<Box<Uint8List>?> _openBox() async {
    final existing = _box;
    if (existing != null && existing.isOpen) return existing;
    try {
      final box = await Hive.openBox<Uint8List>(boxName);
      _box = box;
      return box;
    } catch (e) {
      debugPrint('WebThumbnailService._openBox: $e');
      return null;
    }
  }

  Future<web.CryptoKey?> _cacheKey(String owner) async {
    if (_aesKey != null && _aesKeyOwner == owner) return _aesKey;
    final kekB64 = await SecureStorageService.instance
        .read(SecureStorageKeys.encryptionKey);
    if (kekB64 == null || kekB64.isEmpty) return null;
    final raw = hkdfSha256(
      base64Decode(kekB64),
      salt: utf8.encode('fxfiles-web-thumbs-salt-v1'),
      info: utf8.encode('web-thumbs-v1'),
    );
    final key = await web.window.crypto.subtle
        .importKey('raw', raw.toJS, 'AES-GCM'.toJS, false,
            ['encrypt'.toJS, 'decrypt'.toJS].toJS)
        .toDart;
    _aesKey = key;
    _aesKeyOwner = owner;
    return key;
  }

  JSObject _gcmParams(Uint8List nonce, String aad) {
    final alg = JSObject();
    alg.setProperty('name'.toJS, 'AES-GCM'.toJS);
    alg.setProperty('iv'.toJS, nonce.toJS);
    alg.setProperty(
        'additionalData'.toJS, Uint8List.fromList(utf8.encode(aad)).toJS);
    return alg;
  }

  Future<Uint8List> _encrypt(
      web.CryptoKey key, String entryKey, Uint8List plain) async {
    final nonce =
        Uint8List.fromList(List<int>.generate(12, (_) => _rng.nextInt(256)));
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
      return null; // wrong key / AAD / corrupt → miss
    }
  }

  String _entryKey(String owner, String bucket, String key) =>
      '$owner|t|$bucket|$key';

  Future<Uint8List?> _diskGet(String bucket, String key) async {
    try {
      final owner = await _ownerHash();
      if (owner == null) return null;
      final aes = await _cacheKey(owner);
      if (aes == null) return null;
      final box = await _openBox();
      if (box == null) return null;
      final ek = _entryKey(owner, bucket, key);
      final v = box.get(ek);
      if (v == null) return null;
      return _decrypt(aes, ek, v);
    } catch (e) {
      debugPrint('WebThumbnailService._diskGet: $e');
      return null;
    }
  }

  Future<void> _diskPut(String bucket, String key, Uint8List thumb) async {
    try {
      final owner = await _ownerHash();
      if (owner == null) return;
      final aes = await _cacheKey(owner);
      if (aes == null) return;
      final box = await _openBox();
      if (box == null) return;
      final ek = _entryKey(owner, bucket, key);
      await box.put(ek, await _encrypt(aes, ek, thumb));
    } catch (e) {
      debugPrint('WebThumbnailService._diskPut: $e');
    }
  }

  Future<void> _diskDelete(String bucket, String key) async {
    try {
      final owner = await _ownerHash();
      if (owner == null) return;
      final box = await _openBox();
      if (box == null) return;
      await box.delete(_entryKey(owner, bucket, key));
    } catch (e) {
      debugPrint('WebThumbnailService._diskDelete: $e');
    }
  }

  /// Sign-out / user-switch: forget the in-memory key + caches, delete the box.
  Future<void> clearAll() async {
    _aesKey = null;
    _aesKeyOwner = null;
    _mem.clear();
    _missing.clear();
    _missingBuckets.clear();
    final box = _box;
    _box = null;
    try {
      if (box != null && box.isOpen) await box.close();
    } catch (e) {
      debugPrint('WebThumbnailService.clearAll close: $e');
    }
    try {
      await Hive.deleteBoxFromDisk(boxName);
    } catch (e) {
      debugPrint('WebThumbnailService.clearAll delete: $e');
    }
  }

  /// Remote-sign-out receiver: drop the key + caches + close the box (so the
  /// originating tab's delete isn't blocked) without deleting it here.
  Future<void> deactivate() async {
    _aesKey = null;
    _aesKeyOwner = null;
    _mem.clear();
    _missing.clear();
    _missingBuckets.clear();
    final box = _box;
    _box = null;
    try {
      if (box != null && box.isOpen) await box.close();
    } catch (e) {
      debugPrint('WebThumbnailService.deactivate: $e');
    }
  }
}
