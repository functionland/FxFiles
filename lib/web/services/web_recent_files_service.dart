import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/web/services/web_cache_hkdf.dart';
import 'package:fula_files/web/services/web_device_class.dart';
import 'package:fula_files/web/services/web_recent_entry.dart';

export 'package:fula_files/web/services/web_recent_entry.dart';

/// Device-local, per-user, encrypted "recently opened" store behind the
/// web home Recent strip (issue #17). Same encryption rationale as
/// [WebListingCache] — filenames and image thumbnails are user content and
/// IndexedDB is plaintext on disk — but a SEPARATE Hive box so the
/// thumbnail blobs never pressure the listing cache's eviction (advisor
/// guidance: Codex).
///
/// Layout (values are `nonce(12) || AES-GCM(ciphertext+tag)` under an
/// HKDF-derived AES-GCM key from the session KEK; AAD = the entry key):
///   `<ownerHash>|ridx`                   → JSON index (<=30 entries)
///   `<ownerHash>|rthumb|<bucket>|<key>`  → PNG thumbnail (images only)
///
/// The pure data model + merge logic live in `web_recent_entry.dart`
/// (VM-unit-tested); this file is the browser-only crypto/IndexedDB half.
class WebRecentFilesService extends ChangeNotifier {
  WebRecentFilesService._();
  static final WebRecentFilesService instance = WebRecentFilesService._();

  static const String boxName = 'web_recent_files_v1';

  /// Don't decode a huge source just to thumbnail it (transient memory
  /// spike), and discard a thumbnail that didn't compress small enough.
  static const int _maxSourceBytes = 10 * 1024 * 1024;
  static const int _maxThumbBytes = 200 * 1024;
  static const int _thumbTargetWidth = 160;

  Box<Uint8List>? _box;
  web.CryptoKey? _aesKey;
  String? _aesKeyOwner;

  /// Fail-closed CSPRNG for AES-GCM nonces (throws if no secure source —
  /// never a weak fallback; same as web_listing_cache).
  final Random _rng = Random.secure();

  // ----------------------------------------------------------- identity

  Future<String?> _ownerHash() async {
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

  Future<web.CryptoKey?> _cacheKey(String owner) async {
    if (_aesKey != null && _aesKeyOwner == owner) return _aesKey;
    final kekB64 = await SecureStorageService.instance
        .read(SecureStorageKeys.encryptionKey);
    if (kekB64 == null || kekB64.isEmpty) return null;
    final raw = hkdfSha256(
      base64Decode(kekB64),
      salt: utf8.encode('fxfiles-web-recents-salt-v1'),
      info: utf8.encode('web-recents-v1'),
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
      return null; // wrong key / AAD / corrupt → miss, never an error
    }
  }

  // -------------------------------------------------------------- keys

  String _indexKey(String owner) => '$owner|ridx';
  String _thumbKey(String owner, String bucket, String key) =>
      '$owner|rthumb|$bucket|$key';

  // --------------------------------------------------------- public API

  Future<void> _recordChain = Future.value();

  /// Record a successful open. Call ONCE after decrypted bytes arrive (so
  /// failed opens aren't recorded). [imageBytes] is the decrypted image —
  /// supply it only for images to get a thumbnail. Serialized so
  /// near-simultaneous opens can't lose an index update (the index is a
  /// read-modify-write — Codex review).
  Future<void> recordOpened({
    required String bucket,
    required String base,
    required String key,
    required String name,
    required String mime,
    required int size,
    Uint8List? imageBytes,
  }) {
    final op = _recordChain.then((_) => _doRecord(
          bucket: bucket,
          base: base,
          key: key,
          name: name,
          mime: mime,
          size: size,
          imageBytes: imageBytes,
        ));
    _recordChain = op.catchError((_) {});
    return op;
  }

  Future<void> _doRecord({
    required String bucket,
    required String base,
    required String key,
    required String name,
    required String mime,
    required int size,
    Uint8List? imageBytes,
  }) async {
    try {
      final owner = await _ownerHash();
      if (owner == null) return;
      final aes = await _cacheKey(owner);
      if (aes == null) return;
      final box = await _openBox();

      Uint8List? thumb;
      if (mime.startsWith('image/') && imageBytes != null) {
        thumb = await _makeThumbnail(imageBytes);
      }

      final entry = WebRecentEntry(
        bucket: bucket,
        base: base,
        key: key,
        name: name,
        mime: mime,
        size: size,
        accessedAtMs: DateTime.now().millisecondsSinceEpoch,
        hasThumb: thumb != null,
      );

      // Write/replace the thumbnail blob first so the index never points
      // at a missing one.
      final tKey = _thumbKey(owner, bucket, key);
      if (thumb != null) {
        await box.put(tKey, await _encrypt(aes, tKey, thumb));
      } else {
        await box.delete(tKey); // stale thumb from a prior open
      }

      final (kept, dropped) =
          mergeRecentEntries(await _readIndex(box, aes, owner), entry);
      for (final d in dropped) {
        await box.delete(_thumbKey(owner, d.bucket, d.key));
      }
      await _writeIndex(box, aes, owner, kept);
      notifyListeners();
    } catch (e) {
      debugPrint('WebRecentFilesService.recordOpened: $e');
    }
  }

  /// The recent list (newest first); empty on any failure.
  Future<List<WebRecentEntry>> list() async {
    try {
      final owner = await _ownerHash();
      if (owner == null) return const [];
      final aes = await _cacheKey(owner);
      if (aes == null) return const [];
      return _readIndex(await _openBox(), aes, owner);
    } catch (e) {
      debugPrint('WebRecentFilesService.list: $e');
      return const [];
    }
  }

  /// Decrypted PNG thumbnail bytes for [entry], or null (icon fallback).
  Future<Uint8List?> loadThumbnail(WebRecentEntry entry) async {
    if (!entry.hasThumb) return null;
    try {
      final owner = await _ownerHash();
      if (owner == null) return null;
      final aes = await _cacheKey(owner);
      if (aes == null) return null;
      final tKey = _thumbKey(owner, entry.bucket, entry.key);
      final raw = (await _openBox()).get(tKey);
      if (raw == null) return null;
      return _decrypt(aes, tKey, raw);
    } catch (e) {
      debugPrint('WebRecentFilesService.loadThumbnail: $e');
      return null;
    }
  }

  Future<List<WebRecentEntry>> _readIndex(
      Box<Uint8List> box, web.CryptoKey aes, String owner) async {
    final raw = box.get(_indexKey(owner));
    if (raw == null) return [];
    final plain = await _decrypt(aes, _indexKey(owner), raw);
    if (plain == null) return [];
    try {
      final json = jsonDecode(utf8.decode(plain));
      final list = (json is Map ? json['entries'] : null);
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((m) => WebRecentEntry.fromJson(Map<String, dynamic>.from(m)))
          .whereType<WebRecentEntry>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeIndex(Box<Uint8List> box, web.CryptoKey aes,
      String owner, List<WebRecentEntry> entries) async {
    final plain = utf8.encode(jsonEncode({
      'v': 1,
      'entries': entries.map((e) => e.toJson()).toList(),
    }));
    final value =
        await _encrypt(aes, _indexKey(owner), Uint8List.fromList(plain));
    await box.put(_indexKey(owner), value);
  }

  /// Downscale [bytes] to a small PNG, or null to fall back to an icon.
  /// Icon-only on low-end devices; bounded so a huge source can't OOM.
  Future<Uint8List?> _makeThumbnail(Uint8List bytes) async {
    if (WebDeviceClass.lowEnd) return null;
    if (bytes.length > _maxSourceBytes) return null;
    ui.Image? image;
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes,
          targetWidth: _thumbTargetWidth);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      final out = data.buffer.asUint8List();
      if (out.length > _maxThumbBytes) return null;
      // Copy off the shared codec buffer before it's disposed.
      return Uint8List.fromList(out);
    } catch (e) {
      debugPrint('WebRecentFilesService._makeThumbnail: $e');
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  // -------------------------------------------------------- lifecycle

  /// Sign-out / user-switch: forget the in-memory derived key + L1 so the
  /// next user can't read this user's recents, and delete the box.
  Future<void> clearAll() async {
    _aesKey = null;
    _aesKeyOwner = null;
    final box = _box;
    _box = null;
    try {
      if (box != null && box.isOpen) await box.close();
    } catch (e) {
      debugPrint('WebRecentFilesService.clearAll close: $e');
    }
    try {
      await Hive.deleteBoxFromDisk(boxName);
    } catch (e) {
      debugPrint('WebRecentFilesService.clearAll delete: $e');
    }
    notifyListeners();
  }

  /// Remote-sign-out receiver: drop the derived key + close the box (so
  /// the originating tab's delete isn't blocked) without deleting.
  Future<void> deactivate() async {
    _aesKey = null;
    _aesKeyOwner = null;
    final box = _box;
    _box = null;
    try {
      if (box != null && box.isOpen) await box.close();
    } catch (e) {
      debugPrint('WebRecentFilesService.deactivate: $e');
    }
    notifyListeners();
  }
}
