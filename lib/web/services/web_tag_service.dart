import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/web/services/web_cache_sync.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';
import 'package:fula_files/web/services/web_listing_swr.dart';

/// Web counterpart of the native TagStorageService. Same cloud manifest
/// (TagCloudMetadata at `tag-metadata(-v8)/.fula/tags/{userId}.json`,
/// fula-envelope encrypted via uploadObject), same JSON shapes, same
/// additive [v8, legacy] merge on read — so tags created on either
/// platform show up on the other.
///
/// The web has no Hive box: every mutation re-downloads the merged
/// manifest, applies the change, recomputes fileCounts and uploads the
/// full snapshot to the v8 bucket. That download-before-write is the
/// web's substitute for the native additive-restore-then-overwrite
/// lifecycle (same convergence model, same last-writer-wins races).
class WebTagService {
  WebTagService._();
  static final WebTagService instance = WebTagService._();

  static const String _bucket = 'tag-metadata';
  static const String _keyPrefix = '.fula/tags/';

  final _uuid = const Uuid();

  List<FileTag> _tags = const [];
  List<TaggedFile> _taggedFiles = const [];
  bool _loaded = false;

  /// Single-flight for non-force [load]s — the websites LIST and DETAIL
  /// screens both call load() on mount and used to race two identical
  /// network reads. Force callers NEVER join (see [load]).
  Future<void>? _loadFuture;

  List<FileTag> get tags => _tags;
  List<TaggedFile> get taggedFiles => _taggedFiles;
  bool get isLoaded => _loaded;

  String get _writeBucket => BucketVersionResolver.writeBucket(_bucket);

  static Future<Uint8List> _kek() async {
    final b64 = await SecureStorageService.instance
        .read(SecureStorageKeys.encryptionKey);
    if (b64 == null || b64.isEmpty) {
      throw StateError('No session encryption key');
    }
    return Uint8List.fromList(base64Decode(b64));
  }

  /// Same derivation as every native metadata service:
  /// sha256(utf8(base64(publicKey))) hex, first 16 chars.
  static Future<String> userId() async {
    final pub = await FulaApiService.instance.getPublicKey();
    final b64 = base64Encode(pub);
    return sha256.convert(utf8.encode(b64)).toString().substring(0, 16);
  }

  /// Download + additively merge the [v8, legacy] manifests (first/v8
  /// wins an id) into the in-memory snapshot.
  ///
  /// SWR (P1): without [force] the blobs come from the listing cache
  /// when present (background-refreshed past the fresh window) — screen
  /// opens render instantly. Mutations and Refresh buttons pass
  /// force=true for an awaited live read; ONLY explicit cross-device
  /// refreshes also pass [refetchForest] (a mutation's merge-read must
  /// keep the session forest — it already reflects our own writes,
  /// while the server may briefly lag them).
  Future<void> load({bool force = false, bool refetchForest = false}) {
    if (_loaded && !force) return Future.value();
    if (!force) {
      // Join an in-flight non-force load instead of starting a second
      // identical network read (list + detail screens race on mount).
      final inFlight = _loadFuture;
      if (inFlight != null) return inFlight;
      final f = _doLoad(refetchForest: refetchForest)
          .whenComplete(() => _loadFuture = null);
      _loadFuture = f;
      return f;
    }
    // Force NEVER joins: mutation callers (_mutateAndSync) do
    // read-modify-write and joining a stale non-force flight would let
    // the overwrite-upload silently drop a concurrent change.
    return _doLoad(force: true, refetchForest: refetchForest);
  }

  Future<void> _doLoad(
      {bool force = false, bool refetchForest = false}) async {
    final kek = await _kek();
    final uid = await userId();
    final tagsById = <String, FileTag>{};
    final filesById = <String, TaggedFile>{};
    // Yield cadence: rows are tiny (a few ms per ~200) — slicing keeps
    // the frame alive on big tag sets without measurable overhead.
    var sinceYield = 0;
    Future<void> maybeYield() async {
      if (++sinceYield >= 200) {
        sinceYield = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }

    for (final blob in await WebListingSwr.instance.downloadMetadataMergedSwr(
        _bucket, '$_keyPrefix$uid.json', kek,
        force: force, refetchForest: refetchForest)) {
      try {
        final meta = TagCloudMetadata.fromJson(
            jsonDecode(utf8.decode(blob)) as Map<String, dynamic>);
        for (final t in meta.tags) {
          tagsById.putIfAbsent(t.id, () => t);
          await maybeYield();
        }
        for (final f in meta.taggedFiles) {
          filesById.putIfAbsent(f.id, () => f);
          await maybeYield();
        }
      } catch (e) {
        debugPrint('WebTagService.load: manifest parse skipped: $e');
      }
    }
    _tags = tagsById.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _taggedFiles = filesById.values.toList();
    _recountLocally();
    _loaded = true;
  }

  /// Recompute every tag's fileCount from the association list (the
  /// native service maintains counts incrementally; recomputing keeps
  /// the web snapshot honest even after merges).
  void _recountLocally() {
    final counts = <String, int>{};
    for (final tf in _taggedFiles) {
      counts[tf.tagId] = (counts[tf.tagId] ?? 0) + 1;
    }
    _tags = _tags
        .map((t) => t.fileCount == (counts[t.id] ?? 0)
            ? t
            : t.copyWith(fileCount: counts[t.id] ?? 0))
        .toList();
  }

  /// Fresh-merge + mutate + upload. The mutation runs against the
  /// just-downloaded state so a concurrent change from the app isn't
  /// silently dropped by our overwrite-upload.
  Future<void> _mutateAndSync(void Function() mutate) async {
    await load(force: true);
    mutate();
    _recountLocally();
    await _upload();
  }

  Future<void> _upload() async {
    final uid = await userId();
    final meta = TagCloudMetadata(
      userId: uid,
      tags: _tags,
      taggedFiles: _taggedFiles,
      updatedAt: DateTime.now(),
    );
    final data = Uint8List.fromList(utf8.encode(jsonEncode(meta.toJson())));
    // Native _ensureBucketExists pattern: create, tolerate exists.
    try {
      await FulaApiService.instance.createBucket(_writeBucket);
    } catch (_) {}
    await FulaApiService.instance.uploadObject(
      _writeBucket,
      '$_keyPrefix$uid.json',
      data,
      contentType: 'application/json',
    );
    // Write-through: the SWR cache must reflect the manifest we just
    // uploaded, or the next open would serve the pre-mutation copy.
    // Other tabs drop their copy and revalidate on next view.
    await WebListingCache.instance
        .writeManifest(_writeBucket, '$_keyPrefix$uid.json', data);
    WebCacheSync.instance
        .sendInvalidateManifest(_writeBucket, '$_keyPrefix$uid.json');
    debugPrint('WebTagService: synced ${_tags.length} tags, '
        '${_taggedFiles.length} associations');
  }

  // ------------------------------------------------------------- mutations

  Future<FileTag> createTag({
    required String name,
    required int colorValue,
  }) async {
    final now = DateTime.now();
    final tag = FileTag(
      id: _uuid.v4(),
      name: name,
      colorValue: colorValue,
      createdAt: now,
      updatedAt: now,
    );
    await _mutateAndSync(() => _tags = [..._tags, tag]);
    return tag;
  }

  Future<void> updateTag(String tagId, {String? name, int? colorValue}) =>
      _mutateAndSync(() {
        _tags = _tags
            .map((t) => t.id == tagId
                ? t.copyWith(
                    name: name ?? t.name,
                    colorValue: colorValue ?? t.colorValue,
                    updatedAt: DateTime.now(),
                  )
                : t)
            .toList();
      });

  Future<void> deleteTag(String tagId) => _mutateAndSync(() {
        _tags = _tags.where((t) => t.id != tagId).toList();
        _taggedFiles =
            _taggedFiles.where((f) => f.tagId != tagId).toList();
      });

  /// Tag a cloud object. remoteKey uses the same form the native
  /// cloud-explorer looks up: '$bucket/${objectKey}'.
  Future<void> tagFile({
    required String tagId,
    required String remoteKey,
    required String fileName,
  }) =>
      _mutateAndSync(() {
        final already = _taggedFiles.any((tf) =>
            tf.tagId == tagId &&
            tf.remoteKey != null &&
            _sameRemote(tf.remoteKey!, remoteKey));
        if (already) return;
        _taggedFiles = [
          ..._taggedFiles,
          TaggedFile(
            id: _uuid.v4(),
            tagId: tagId,
            remoteKey: remoteKey,
            fileName: fileName,
            taggedAt: DateTime.now(),
          ),
        ];
      });

  Future<void> untagFile({
    required String tagId,
    required String remoteKey,
  }) =>
      _mutateAndSync(() {
        _taggedFiles = _taggedFiles
            .where((tf) => !(tf.tagId == tagId &&
                tf.remoteKey != null &&
                _sameRemote(tf.remoteKey!, remoteKey)))
            .toList();
      });

  /// Remove one association row by its id (tagged-files screen X).
  Future<void> removeTaggedFile(String taggedFileId) => _mutateAndSync(() {
        _taggedFiles =
            _taggedFiles.where((tf) => tf.id != taggedFileId).toList();
      });

  // --------------------------------------------------------------- lookups

  /// The native app stores remoteKey in two shapes depending on flow:
  /// bare object key ('/photo.jpg', from sync-state remotePath) or
  /// 'bucket/objectKey' (cloud-explorer lookups). Treat them as the
  /// same file when the trailing object key matches.
  bool _sameRemote(String a, String b) {
    if (a == b) return true;
    return _bareKey(a) == _bareKey(b);
  }

  /// Strip a leading `bucket/` segment (when present) and any leading '/'.
  String _bareKey(String remoteKey) {
    var k = remoteKey;
    final firstSlash = k.indexOf('/');
    if (firstSlash > 0) {
      // 'bucket//x.jpg' or 'bucket/x.jpg' → drop the bucket segment.
      final head = k.substring(0, firstSlash);
      if (RegExp(r'^[a-z0-9-]+$').hasMatch(head)) {
        k = k.substring(firstSlash + 1);
      }
    }
    while (k.startsWith('/')) {
      k = k.substring(1);
    }
    return k;
  }

  /// Tags per listed object of [bucket]: matches each association's
  /// remoteKey against both shapes (with and without the bucket).
  Map<String, List<FileTag>> tagsForObjects(
      String bucket, List<FulaObject> objects) {
    if (objects.isEmpty || _taggedFiles.isEmpty) return {};
    final tagById = {for (final t in _tags) t.id: t};

    // bare object key → display key
    final bareToKey = <String, String>{
      for (final o in objects) _bareKey(o.key): o.key,
    };

    final out = <String, List<FileTag>>{};
    for (final tf in _taggedFiles) {
      final rk = tf.remoteKey;
      if (rk == null) continue;
      final objectKey = bareToKey[_bareKey(rk)];
      if (objectKey == null) continue;
      final tag = tagById[tf.tagId];
      if (tag == null) continue;
      (out[objectKey] ??= <FileTag>[]).add(tag);
    }
    for (final list in out.values) {
      list.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return out;
  }

  /// Association rows for one tag (newest first — native tagged-files
  /// screen order).
  List<TaggedFile> filesWithTag(String tagId) {
    final files = _taggedFiles.where((tf) => tf.tagId == tagId).toList()
      ..sort((a, b) => b.taggedAt.compareTo(a.taggedAt));
    return files;
  }

  FileTag? tagById(String id) {
    for (final t in _tags) {
      if (t.id == id) return t;
    }
    return null;
  }

  // ------------------------------------------------- tag share resolution

  /// Web mirror of SharingService._resolveTagShareScope for cloud-only
  /// context: every tagged file with a remoteKey becomes a candidate in
  /// the bucket embedded in the key (web-tagged) or guessed from the
  /// file name (app-tagged bare keys — same fallback rule as native);
  /// majority bucket wins, then one listObjects pass resolves storage
  /// keys. Entries without a cloud object fall out as not-included.
  Future<
      ({
        FileTag tag,
        String? primaryBucket,
        List<({String displayName, String storageKey, int size})> items,
        int totalCount,
      })> resolveTagShareScope(String tagId) async {
    await load();
    final tag = tagById(tagId);
    if (tag == null) {
      throw StateError('Tag not found: $tagId');
    }
    final files = filesWithTag(tagId);

    final candidates = <({String bucket, String bareKey, String name})>[];
    for (final tf in files) {
      final rk = tf.remoteKey;
      if (rk == null) continue;
      String? bucket;
      final firstSlash = rk.indexOf('/');
      if (firstSlash > 0 &&
          RegExp(r'^[a-z0-9-]+$').hasMatch(rk.substring(0, firstSlash))) {
        bucket = rk.substring(0, firstSlash);
      }
      bucket ??= _guessBucketForFileName(tf.fileName);
      candidates.add((
        bucket: BucketVersionResolver.writeBucket(bucket),
        bareKey: _bareKey(rk),
        name: tf.fileName,
      ));
    }

    String? primaryBucket;
    if (candidates.isNotEmpty) {
      final counts = <String, int>{};
      for (final c in candidates) {
        counts[c.bucket] = (counts[c.bucket] ?? 0) + 1;
      }
      primaryBucket =
          counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    }

    final items =
        <({String displayName, String storageKey, int size})>[];
    if (primaryBucket != null) {
      final bareToObject = <String, FulaObject>{};
      try {
        for (final o
            in await FulaApiService.instance.listObjects(primaryBucket)) {
          bareToObject[_bareKey(o.key)] = o;
        }
      } catch (e) {
        debugPrint('WebTagService.resolveTagShareScope: list failed: $e');
      }
      for (final c in candidates.where((c) => c.bucket == primaryBucket)) {
        final obj = bareToObject[c.bareKey];
        if (obj == null) continue;
        items.add((
          displayName: c.name,
          storageKey: obj.storageKey ?? obj.key,
          size: obj.size,
        ));
      }
    }

    return (
      tag: tag,
      primaryBucket: primaryBucket,
      items: items,
      totalCount: files.length,
    );
  }

  /// Category guess for bare (app-tagged) keys — mirrors the native
  /// FileCategory.fromPath fallback in _resolveTagShareScope (that enum
  /// lives in the dart:io-tainted FileService, hence this small copy).
  String _guessBucketForFileName(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const images = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'};
    const videos = {'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v'};
    const audio = {'mp3', 'wav', 'm4a', 'ogg', 'flac', 'aac'};
    const archives = {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'iso'};
    if (images.contains(ext)) return 'images';
    if (videos.contains(ext)) return 'videos';
    if (audio.contains(ext)) return 'audio';
    if (archives.contains(ext)) return 'archives';
    return 'documents';
  }
}
