import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:crypto/crypto.dart' show md5;
import 'dart:convert' show utf8;

class VideoThumbnailService {
  VideoThumbnailService._();
  static final VideoThumbnailService instance = VideoThumbnailService._();

  String? _cacheDir;
  bool _isInitialized = false;

  // In-memory cache for quick access (limited size)
  final Map<String, Uint8List> _memoryCache = {};
  static const int _maxMemoryCacheSize = 50;

  // Track pending requests to avoid duplicate generation
  final Map<String, Completer<Uint8List?>> _pendingRequests = {};

  Future<void> init() async {
    if (_isInitialized) return;

    try {
      final dir = await getTemporaryDirectory();
      _cacheDir = p.join(dir.path, 'video_thumbnails');
      final cacheDirectory = Directory(_cacheDir!);
      if (!await cacheDirectory.exists()) {
        await cacheDirectory.create(recursive: true);
      }
      _isInitialized = true;
      debugPrint('VideoThumbnailService initialized at $_cacheDir');
    } catch (e) {
      debugPrint('Error initializing VideoThumbnailService: $e');
    }
  }

  /// Generate a cache key from the video path
  String _getCacheKey(String videoPath) {
    final bytes = utf8.encode(videoPath);
    final digest = md5.convert(bytes);
    return digest.toString();
  }

  /// Get cached thumbnail path
  String _getCachePath(String cacheKey) {
    return p.join(_cacheDir!, '$cacheKey.jpg');
  }

  /// Get thumbnail for a video file
  /// Returns cached thumbnail if available, otherwise generates a new one
  /// [quality] - Thumbnail quality (0-100), default 50 for good balance
  /// [maxWidth] - Maximum width of thumbnail, default 200
  /// [maxHeight] - Maximum height of thumbnail, default 200
  Future<Uint8List?> getThumbnail(
    String videoPath, {
    int quality = 50,
    int maxWidth = 200,
    int maxHeight = 200,
  }) async {
    await init();
    if (_cacheDir == null) return null;

    final cacheKey = _getCacheKey(videoPath);

    // Check memory cache first
    if (_memoryCache.containsKey(cacheKey)) {
      return _memoryCache[cacheKey];
    }

    // Check if there's already a pending request for this video
    if (_pendingRequests.containsKey(cacheKey)) {
      return _pendingRequests[cacheKey]!.future;
    }

    // Create a completer for this request
    final completer = Completer<Uint8List?>();
    _pendingRequests[cacheKey] = completer;

    try {
      // Check disk cache
      final cachePath = _getCachePath(cacheKey);
      final cacheFile = File(cachePath);
      if (await cacheFile.exists()) {
        final bytes = await cacheFile.readAsBytes();
        _addToMemoryCache(cacheKey, bytes);
        completer.complete(bytes);
        return bytes;
      }

      // Generate thumbnail in isolate to avoid blocking UI
      final bytes = await _generateThumbnail(
        videoPath,
        cachePath,
        quality: quality,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      );

      if (bytes != null) {
        _addToMemoryCache(cacheKey, bytes);
      }

      completer.complete(bytes);
      return bytes;
    } catch (e) {
      debugPrint('Error getting thumbnail for $videoPath: $e');
      completer.complete(null);
      return null;
    } finally {
      _pendingRequests.remove(cacheKey);
    }
  }

  /// Generate thumbnail using video_thumbnail package
  Future<Uint8List?> _generateThumbnail(
    String videoPath,
    String outputPath, {
    required int quality,
    required int maxWidth,
    required int maxHeight,
  }) async {
    try {
      // Check if video file exists
      final videoFile = File(videoPath);
      if (!await videoFile.exists()) {
        return null;
      }

      // Generate thumbnail
      final bytes = await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        quality: quality,
      );

      if (bytes != null) {
        // Save to disk cache
        try {
          await File(outputPath).writeAsBytes(bytes);
        } catch (e) {
          // Ignore cache write errors
          debugPrint('Failed to cache thumbnail: $e');
        }
      }

      return bytes;
    } catch (e) {
      debugPrint('Error generating thumbnail: $e');
      return null;
    }
  }

  /// Add thumbnail to memory cache with LRU eviction
  void _addToMemoryCache(String key, Uint8List bytes) {
    if (_memoryCache.length >= _maxMemoryCacheSize) {
      // Remove oldest entry
      _memoryCache.remove(_memoryCache.keys.first);
    }
    _memoryCache[key] = bytes;
  }

  /// Clear all cached thumbnails
  Future<void> clearCache() async {
    _memoryCache.clear();

    if (_cacheDir != null) {
      try {
        final cacheDirectory = Directory(_cacheDir!);
        if (await cacheDirectory.exists()) {
          await cacheDirectory.delete(recursive: true);
          await cacheDirectory.create(recursive: true);
        }
      } catch (e) {
        debugPrint('Error clearing thumbnail cache: $e');
      }
    }
  }

  /// Get cache size in bytes
  Future<int> getCacheSize() async {
    if (_cacheDir == null) return 0;

    try {
      final cacheDirectory = Directory(_cacheDir!);
      if (!await cacheDirectory.exists()) return 0;

      int totalSize = 0;
      await for (final entity in cacheDirectory.list()) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
      return totalSize;
    } catch (e) {
      return 0;
    }
  }

  /// Preload thumbnails for a list of video paths
  /// Useful for preloading when browsing a folder
  Future<void> preloadThumbnails(List<String> videoPaths) async {
    // Limit concurrent generation to avoid overwhelming the system
    const batchSize = 3;

    for (var i = 0; i < videoPaths.length; i += batchSize) {
      final batch = videoPaths.skip(i).take(batchSize);
      await Future.wait(
        batch.map((path) => getThumbnail(path)),
        eagerError: false,
      );
    }
  }
}
