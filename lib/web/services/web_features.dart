import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/playlist.dart';
import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/models/website_group_pointer.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';

/// Read-only cloud loaders for the four feature areas the web shell
/// mirrors from native (Shelf / Websites / Tags / Playlists). Each
/// reader follows the corresponding native service's restore path:
/// downloadMetadataMerged handles the [v8, legacy] manifest merge; the
/// playlists reader replicates playlist_service's LIST-merge +
/// tombstone subtraction (v8 wins by id).
class WebFeatures {
  WebFeatures._();

  static Future<Uint8List> _kek() async {
    final b64 = await SecureStorageService.instance
        .read(SecureStorageKeys.encryptionKey);
    if (b64 == null || b64.isEmpty) {
      throw StateError('No session encryption key');
    }
    return Uint8List.fromList(base64Decode(b64));
  }

  /// Same per-user manifest scoping as the native services
  /// (ShelfStorageService / TagStorageService / WebsiteService):
  /// sha256 over the utf8 bytes of the BASE64 STRING of the public key
  /// — NOT the raw key bytes — hex, first 16 chars. The base64-string
  /// input is the historical derivation every existing manifest key
  /// was written with.
  static Future<String> _userId() async {
    final pub = await FulaApiService.instance.getPublicKey();
    final b64 = base64Encode(pub);
    return sha256.convert(utf8.encode(b64)).toString().substring(0, 16);
  }

  // ------------------------------------------------------------------ shelf

  /// Shelf manifest (v2: items + order). Mirrors
  /// ShelfStorageService.restoreFromCloud: merged manifests, first
  /// (v8) wins per id, order applied from the first manifest carrying
  /// one.
  static Future<List<ShelfItem>> loadShelf() async {
    final kek = await _kek();
    final userId = await _userId();
    final key = '.fula/dumps/$userId.json';
    final blobs = await FulaApiService.instance
        .downloadMetadataMerged('dump-metadata', key, kek);

    final byId = <String, ShelfItem>{};
    List<String>? order;
    for (final blob in blobs) {
      try {
        final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
        for (final raw in (j['items'] as List<dynamic>? ?? const [])) {
          final item = ShelfItem.fromJson(raw as Map<String, dynamic>);
          byId.putIfAbsent(item.id, () => item);
        }
        order ??= (j['order'] as List<dynamic>?)?.cast<String>();
      } catch (e) {
        debugPrint('WebFeatures.loadShelf: manifest parse skipped: $e');
      }
    }

    final items = byId.values.toList();
    if (order != null && order.isNotEmpty) {
      final pos = <String, int>{
        for (var i = 0; i < order.length; i++) order[i]: i,
      };
      items.sort((a, b) =>
          (pos[a.id] ?? 1 << 30).compareTo(pos[b.id] ?? 1 << 30));
    } else {
      items.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    }
    return items;
  }

  /// Download a shelf item's body bytes (sourceBucket recorded at
  /// upload time; falls back to the current write bucket).
  static Future<Uint8List> downloadShelfItem(ShelfItem item) async {
    final kek = await _kek();
    final bucket = (item.sourceBucket?.isNotEmpty ?? false)
        ? item.sourceBucket!
        : BucketVersionResolver.writeBucket('dump');
    if (item.remoteKey == null || item.remoteKey!.isEmpty) {
      throw StateError('Item has no cloud copy');
    }
    return FulaApiService.instance
        .downloadAndDecrypt(bucket, item.remoteKey!, kek);
  }

  // --------------------------------------------------------------- websites

  /// Website generations + the stable-link pointers, keyed by tagId.
  /// Mirrors WebsiteService.restoreFromCloud (merged blobs, first id
  /// wins) + IpnsPointerService's pointers manifest.
  static Future<
      ({
        List<WebsiteGeneration> generations,
        Map<String, WebsiteGroupPointer> pointersByTag,
      })> loadWebsites() async {
    final kek = await _kek();
    final userId = await _userId();

    final byId = <String, WebsiteGeneration>{};
    for (final blob in await FulaApiService.instance.downloadMetadataMerged(
        'website-metadata', '.fula/websites/$userId.json', kek)) {
      try {
        final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
        for (final raw in (j['generations'] as List<dynamic>? ?? const [])) {
          final g = WebsiteGeneration.fromJson(raw as Map<String, dynamic>);
          byId.putIfAbsent(g.id, () => g);
        }
      } catch (e) {
        debugPrint('WebFeatures.loadWebsites: parse skipped: $e');
      }
    }

    final pointers = <String, WebsiteGroupPointer>{};
    try {
      for (final blob in await FulaApiService.instance.downloadMetadataMerged(
          'website-metadata', '.fula/website-pointers/$userId.json', kek)) {
        final j = jsonDecode(utf8.decode(blob)) as Map<String, dynamic>;
        for (final raw
            in (j['pointers'] as List<dynamic>? ?? j.values.toList())) {
          if (raw is Map<String, dynamic>) {
            try {
              final p = WebsiteGroupPointer.fromJson(raw);
              pointers.putIfAbsent(p.tagId, () => p);
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('WebFeatures.loadWebsites: pointers skipped: $e');
    }

    final generations = byId.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return (generations: generations, pointersByTag: pointers);
  }

  // ------------------------------------------------------------------- tags

  /// Tags + tagged-file associations. Mirrors
  /// TagStorageService.restoreFromCloud (additive, first/v8 wins).
  static Future<({List<FileTag> tags, List<TaggedFile> files})>
      loadTags() async {
    final kek = await _kek();
    final userId = await _userId();
    final tagsById = <String, FileTag>{};
    final filesById = <String, TaggedFile>{};
    for (final blob in await FulaApiService.instance.downloadMetadataMerged(
        'tag-metadata', '.fula/tags/$userId.json', kek)) {
      try {
        final meta = TagCloudMetadata.fromJson(
            jsonDecode(utf8.decode(blob)) as Map<String, dynamic>);
        for (final t in meta.tags) {
          tagsById.putIfAbsent(t.id, () => t);
        }
        for (final f in meta.taggedFiles) {
          filesById.putIfAbsent(f.id, () => f);
        }
      } catch (e) {
        debugPrint('WebFeatures.loadTags: parse skipped: $e');
      }
    }
    final tags = tagsById.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return (tags: tags, files: filesById.values.toList());
  }

  // -------------------------------------------------------------- playlists

  static const _playlistPrefix = 'user-playlists/';
  static const _tombstonePrefix = 'playlist-deleted/';

  /// Playlists via the native LIST-merge: list [legacy, v8] per-id
  /// objects, v8 wins duplicates, subtract v8 tombstones. Web policy:
  /// the legacy listing is tolerated as empty on failure.
  static Future<List<Playlist>> loadPlaylists() async {
    final kek = await _kek();
    const legacy = 'playlists';
    final v8 = BucketVersionResolver.writeBucket(legacy);

    Future<List<Playlist>> listIn(String bucket) async {
      final out = <Playlist>[];
      final objects = await FulaApiService.instance
          .listObjects(bucket, prefix: _playlistPrefix);
      for (final o in objects) {
        if (!o.key.endsWith('.json')) continue;
        try {
          final bytes = await FulaApiService.instance
              .downloadAndDecrypt(bucket, o.key, kek);
          out.add(Playlist.fromJson(
              jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>));
        } catch (e) {
          debugPrint('WebFeatures.loadPlaylists: ${o.key} skipped: $e');
        }
      }
      return out;
    }

    var v8Playlists = <Playlist>[];
    var legacyPlaylists = <Playlist>[];
    if (v8 != legacy) {
      try {
        v8Playlists = await listIn(v8);
      } catch (e) {
        debugPrint('WebFeatures.loadPlaylists: v8 list skipped: $e');
      }
    }
    try {
      legacyPlaylists = await listIn(legacy);
    } catch (e) {
      debugPrint('WebFeatures.loadPlaylists: legacy list skipped: $e');
    }

    // Tombstones live in the v8 bucket only.
    final tombstoned = <String>{};
    if (v8 != legacy) {
      try {
        final stones = await FulaApiService.instance
            .listObjects(v8, prefix: _tombstonePrefix);
        for (final s in stones) {
          final name = s.key.split('/').last;
          if (name.endsWith('.json')) {
            tombstoned.add(name.substring(0, name.length - 5));
          }
        }
      } catch (e) {
        debugPrint('WebFeatures.loadPlaylists: tombstones skipped: $e');
      }
    }

    final byId = <String, Playlist>{};
    for (final p in v8Playlists) {
      byId[p.id] = p;
    }
    for (final p in legacyPlaylists) {
      byId.putIfAbsent(p.id, () => p);
    }
    tombstoned.forEach(byId.remove);

    final merged = byId.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return merged;
  }

  /// Resolve a track's audio bytes: the recorded path doubles as the
  /// cloud key for synced tracks; try the audio buckets v8-first.
  static Future<Uint8List> downloadTrack(AudioTrack track) async {
    final key = track.path.startsWith('/') ? track.path : '/${track.path}';
    Object? lastError;
    for (final bucket in <String>{
      BucketVersionResolver.writeBucket('audio'),
      'audio',
    }) {
      try {
        return await FulaApiService.instance.downloadObject(bucket, key);
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError(
        'Track is not available in cloud audio storage: $lastError');
  }
}
