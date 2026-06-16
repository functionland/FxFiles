import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/web/services/web_cache_sync.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';
import 'package:fula_files/web/services/web_shelf_write_logic.dart';

/// Thrown when a shelf add is REFUSED because the current cloud manifest
/// could not be read safely. The shelf is a full-snapshot manifest we
/// overwrite on every add, so writing on top of an unreadable current
/// copy could lose existing items — we abort instead.
class ShelfWriteAbort implements Exception {
  final String message;
  const ShelfWriteAbort(this.message);
  @override
  String toString() => message;
}

/// Web counterpart of the native ShelfService's *write* path. The native
/// shelf ingests files from the OS share sheet; the web has no share
/// sheet (Phase 1), so this exposes the in-app add flows instead:
/// [addLink], [addNote] (manifest-only) and [addBytes] (file / photo /
/// recording — uploads an encrypted body blob, then a manifest entry).
///
/// Convergence model (like [WebTagService]): no local Hive box, so every
/// mutation re-reads the merged [v8, legacy] shelf manifest, applies the
/// change, and re-uploads the FULL snapshot to the v8 bucket.
///
/// DATA-LOSS GUARD: unlike the read-only screen (which tolerates a lossy
/// empty list), the WRITE path must read the v8 manifest — the bucket it
/// overwrites — AUTHORITATIVELY. It bypasses the SWR read (which swallows
/// transient/decrypt failures into an empty/partial list) and reads v8
/// directly: a transport/decrypt/parse failure THROWS [ShelfWriteAbort]
/// and nothing is overwritten; only a structural `NoSuchKey` counts as a
/// genuinely empty/new shelf. Legacy is best-effort — it is never
/// written, so a failed legacy read just skips one-time consolidation.
///
/// Pure transforms (item construction, manifest shape/merge, key
/// derivation) live in `web_shelf_write_logic.dart`; this class is the IO
/// glue (read + upload + bucket ensure + cache write-through).
class WebShelfService {
  WebShelfService._();
  static final WebShelfService instance = WebShelfService._();

  /// Manifest (index) bucket — mirrors ShelfStorageService._metadataBucket.
  static const String _metaBucket = 'dump-metadata';

  /// Body (blob) bucket — mirrors ShelfService.kShelfBucket.
  static const String _bodyBucket = 'dump';

  final _uuid = const Uuid();

  String get _metaWriteBucket => BucketVersionResolver.writeBucket(_metaBucket);
  String get _bodyWriteBucket => BucketVersionResolver.writeBucket(_bodyBucket);

  static Future<Uint8List> _kek() async {
    final b64 = await SecureStorageService.instance
        .read(SecureStorageKeys.encryptionKey);
    if (b64 == null || b64.isEmpty) {
      throw StateError('No session encryption key');
    }
    return Uint8List.fromList(base64Decode(b64));
  }

  /// Same per-user manifest scoping as every native metadata service and
  /// [WebFeatures]: sha256 over the utf8 bytes of the BASE64 STRING of
  /// the public key (NOT the raw key bytes), hex, first 16 chars.
  static Future<String> _userId() async {
    final pub = await FulaApiService.instance.getPublicKey();
    final b64 = base64Encode(pub);
    return sha256.convert(utf8.encode(b64)).toString().substring(0, 16);
  }

  // --------------------------------------------------------------- add flows

  /// Capture a URL as a Link item. Manifest-only — no blob.
  Future<ShelfItem> addLink(String url) async {
    final item = buildLinkItem(id: _uuid.v4(), url: url, now: DateTime.now());
    await _appendAndSync(item);
    return item;
  }

  /// Capture free text as a Note item. Manifest-only — no blob.
  Future<ShelfItem> addNote(String text) async {
    final item = buildNoteItem(id: _uuid.v4(), text: text, now: DateTime.now());
    await _appendAndSync(item);
    return item;
  }

  /// Capture raw bytes (a picked file, a camera photo, or an audio
  /// recording): encrypt+upload the blob to the `dump` bucket, then write
  /// the manifest entry.
  Future<ShelfItem> addBytes({
    required Uint8List bytes,
    required String name,
    String? mime,
  }) async {
    final now = DateTime.now();
    final id = _uuid.v4();
    final remoteKey = shelfBodyKey(id, now, name);
    final bodyBucket = _bodyWriteBucket;
    final effMime = effectiveShelfMime(mime, name);

    // The body bucket may not exist yet on a fresh account — create it
    // (idempotent; tolerate already-exists) before the first PUT.
    try {
      await FulaApiService.instance.createBucket(bodyBucket);
    } catch (_) {/* already exists / transient — PUT surfaces real errors */}

    // uploadObject fula-envelope-encrypts internally (the explicit-key
    // `encryptAndUpload` ignores its key arg on this backend), so this is
    // the same at-rest encryption the native body upload produces.
    await FulaApiService.instance.uploadObject(
      bodyBucket,
      remoteKey,
      bytes,
      contentType: effMime,
    );

    final item = buildBytesItem(
      id: id,
      name: name,
      mime: mime,
      sizeBytes: bytes.length,
      contentSha: shelfContentSha(bytes),
      remoteKey: remoteKey,
      sourceBucket: bodyBucket,
      now: now,
    );
    await _appendAndSync(item);
    return item;
  }

  // ------------------------------------------------------------- read/write

  /// Read the CURRENT shelf authoritatively, prepend [item], write the
  /// full snapshot. Throws [ShelfWriteAbort] (without writing) if the
  /// current v8 manifest can't be read safely.
  Future<void> _appendAndSync(ShelfItem item) async {
    final uid = await _userId();
    final key = shelfManifestKey(uid);
    final current = await _readCurrentForWrite(key);
    final next = prependShelfItem(current, item);
    await _uploadManifest(next.items, next.order, uid, key);
  }

  Future<List<ShelfItem>> _readCurrentForWrite(String key) async {
    final kek = await _kek();
    final v8 = _metaWriteBucket;
    final managed = v8 != _metaBucket;

    // v8 — authoritative (we are about to overwrite it).
    final v8Blob = await _readV8BlobOrThrow(v8, key, kek);

    // legacy — best-effort (never overwritten; failure just skips the
    // one-time consolidation of a legacy-only item into v8 this round).
    Uint8List? legacyBlob;
    if (managed) {
      try {
        final blob = await FulaApiService.instance
            .downloadAndDecrypt(_metaBucket, key, kek);
        legacyBlob = blob.isEmpty ? null : blob;
      } catch (_) {
        legacyBlob = null;
      }
    }

    return mergeShelfManifestBlobs(<Uint8List?>[v8Blob, legacyBlob]).items;
  }

  /// Current v8 manifest bytes, or null when v8 is confirmed absent
  /// (`NoSuchKey`/`NoSuchBucket`) or empty. THROWS [ShelfWriteAbort] on a
  /// transient transport/decrypt error or a present-but-corrupt manifest
  /// — overwriting in either case could destroy existing items.
  Future<Uint8List?> _readV8BlobOrThrow(
      String v8, String key, Uint8List kek) async {
    Uint8List blob;
    try {
      blob = await FulaApiService.instance.downloadAndDecrypt(v8, key, kek);
    } catch (e) {
      if (_isConfirmedAbsence(e)) return null;
      throw const ShelfWriteAbort(
          'Could not read your current shelf — not saving, to avoid '
          'overwriting it. Check your connection and try again.');
    }
    if (blob.isEmpty) return null;
    // Present but unparseable → overwriting would destroy it. Abort.
    try {
      final decoded = jsonDecode(utf8.decode(blob));
      if (decoded is! Map) throw const FormatException('not a JSON object');
    } catch (_) {
      throw const ShelfWriteAbort(
          'Your shelf index could not be read — not overwriting it. '
          'Reload and try again.');
    }
    return blob;
  }

  static bool _isConfirmedAbsence(Object e) {
    final s = '$e';
    return s.contains('NoSuchKey') || s.contains('NoSuchBucket');
  }

  Future<void> _uploadManifest(
      List<ShelfItem> items, List<String> order, String uid, String key) async {
    final data = shelfManifestBytes(buildShelfManifest(
      items: items,
      order: order,
      userId: uid,
      now: DateTime.now(),
    ));

    // Ensure the manifest bucket exists (idempotent — native
    // _ensureMetadataBucket pattern).
    try {
      await FulaApiService.instance.createBucket(_metaWriteBucket);
    } catch (_) {/* already exists / transient */}

    await FulaApiService.instance.uploadObject(
      _metaWriteBucket,
      key,
      data,
      contentType: 'application/json',
    );

    // Write-through: the SWR cache must reflect the manifest we just
    // uploaded or the next shelf open would re-serve the pre-add copy
    // (the exact "vanished after refresh" bug the playlist code
    // documents). Other tabs drop their copy and revalidate on view.
    await WebListingCache.instance.writeManifest(_metaWriteBucket, key, data);
    WebCacheSync.instance.sendInvalidateManifest(_metaWriteBucket, key);
    debugPrint('WebShelfService: synced ${items.length} shelf items');
  }
}
