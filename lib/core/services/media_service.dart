import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:path/path.dart' as p;
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/services/file_service.dart';

/// A service for accessing device media (photos, videos, audio) using platform-appropriate APIs.
/// On iOS, uses PhotoKit via photo_manager package.
/// On Android, delegates to FileService for direct file system access.
class MediaService {
  MediaService._();
  static final MediaService instance = MediaService._();

  /// Request permission to access media library
  /// Returns true if permission is granted (full or limited on iOS)
  Future<bool> requestMediaPermission() async {
    if (Platform.isIOS) {
      final permission = await PhotoManager.requestPermissionExtend();
      // Accept both authorized and limited access on iOS
      return permission.isAuth || permission == PermissionState.limited;
    } else {
      // On Android, use existing FileService permission handling
      return await FileService.instance.requestStoragePermission();
    }
  }

  /// Check current permission status
  Future<PermissionState> getPermissionStatus() async {
    return await PhotoManager.getPermissionState(requestOption: PermissionRequestOption());
  }

  /// Check if we have at least limited access
  Future<bool> hasMediaAccess() async {
    final state = await PhotoManager.getPermissionState(requestOption: PermissionRequestOption());
    return state.isAuth || state == PermissionState.limited;
  }

  /// Open iOS limited photo picker to let user select more photos
  Future<void> openLimitedPhotosPicker() async {
    if (Platform.isIOS) {
      await PhotoManager.presentLimited();
    }
  }

  /// Get media files by category using platform-appropriate method
  /// On iOS: uses PhotoKit via photo_manager
  /// On Android: delegates to FileService file system scanning
  Future<MediaResult> getMediaByCategory(
    FileCategory category, {
    int offset = 0,
    int limit = 250,
    String sortBy = 'date',
    bool ascending = false,
  }) async {
    if (Platform.isIOS) {
      return await _getIOSMediaByCategory(
        category,
        offset: offset,
        limit: limit,
        sortBy: sortBy,
        ascending: ascending,
      );
    } else {
      // Android: use existing FileService
      final result = await FileService.instance.getFilesByCategory(
        category,
        offset: offset,
        limit: limit,
        sortBy: sortBy,
        ascending: ascending,
      );
      return MediaResult(
        files: result.files,
        totalCount: result.totalCount,
        hasMore: result.hasMore,
      );
    }
  }

  /// iOS-specific implementation using PhotoKit
  Future<MediaResult> _getIOSMediaByCategory(
    FileCategory category, {
    int offset = 0,
    int limit = 250,
    String sortBy = 'date',
    bool ascending = false,
  }) async {
    // Determine asset type based on category
    final RequestType requestType;
    switch (category) {
      case FileCategory.images:
        requestType = RequestType.image;
        break;
      case FileCategory.videos:
        requestType = RequestType.video;
        break;
      case FileCategory.audio:
        requestType = RequestType.audio;
        break;
      default:
        // For non-media categories on iOS, return empty (handled by app sandbox)
        return MediaResult(files: [], totalCount: 0, hasMore: false);
    }

    // Get all albums of the specified type
    final albums = await PhotoManager.getAssetPathList(
      type: requestType,
      hasAll: true,
      onlyAll: true, // Get the "All" album which contains all assets
    );

    if (albums.isEmpty) {
      return MediaResult(files: [], totalCount: 0, hasMore: false);
    }

    // Get the "All" album (first one when onlyAll is true)
    final allAlbum = albums.first;
    final totalCount = await allAlbum.assetCountAsync;

    // Fetch assets with pagination
    final assets = await allAlbum.getAssetListPaged(
      page: offset ~/ limit,
      size: limit,
    );

    // Convert to LocalFile objects
    final files = <LocalFile>[];
    for (final asset in assets) {
      final file = await _assetToLocalFile(asset);
      if (file != null) {
        files.add(file);
      }
    }

    // Sort files
    files.sort((a, b) {
      int comparison;
      if (sortBy == 'name') {
        comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      } else {
        comparison = a.modifiedAt.compareTo(b.modifiedAt);
      }
      return ascending ? comparison : -comparison;
    });

    return MediaResult(
      files: files,
      totalCount: totalCount,
      hasMore: (offset + limit) < totalCount,
    );
  }

  /// Convert PhotoManager AssetEntity to LocalFile
  Future<LocalFile?> _assetToLocalFile(AssetEntity asset) async {
    try {
      final file = await asset.file;
      if (file == null) return null;

      String mimeType;
      switch (asset.type) {
        case AssetType.image:
          mimeType = 'image/${asset.mimeType?.split('/').last ?? 'jpeg'}';
          break;
        case AssetType.video:
          mimeType = 'video/${asset.mimeType?.split('/').last ?? 'mp4'}';
          break;
        case AssetType.audio:
          mimeType = 'audio/${asset.mimeType?.split('/').last ?? 'mp3'}';
          break;
        default:
          mimeType = asset.mimeType ?? 'application/octet-stream';
      }

      return LocalFile(
        path: file.path,
        name: asset.title ?? p.basename(file.path),
        size: asset.size.width > 0 ? (await file.length()) : 0,
        modifiedAt: asset.modifiedDateTime,
        isDirectory: false,
        mimeType: mimeType,
        iosAssetId: asset.id, // Store asset ID for iOS-specific operations
      );
    } catch (e) {
      debugPrint('Error converting asset to LocalFile: $e');
      return null;
    }
  }

  /// Get thumbnail data for an asset (iOS only, by asset ID)
  Future<Uint8List?> getThumbnail(String assetId, {int width = 200, int height = 200}) async {
    if (!Platform.isIOS) return null;
    
    try {
      final asset = await AssetEntity.fromId(assetId);
      if (asset == null) return null;
      
      return await asset.thumbnailDataWithSize(
        ThumbnailSize(width, height),
        quality: 80,
      );
    } catch (e) {
      debugPrint('Error getting thumbnail: $e');
      return null;
    }
  }

  /// Get the original file for an asset (iOS only, by asset ID)
  Future<File?> getOriginalFile(String assetId) async {
    if (!Platform.isIOS) return null;
    
    try {
      final asset = await AssetEntity.fromId(assetId);
      if (asset == null) return null;
      
      return await asset.originFile;
    } catch (e) {
      debugPrint('Error getting original file: $e');
      return null;
    }
  }

  /// Delete assets (iOS only)
  Future<List<String>> deleteAssets(List<String> assetIds) async {
    if (!Platform.isIOS) return [];
    
    try {
      final assets = <AssetEntity>[];
      for (final id in assetIds) {
        final asset = await AssetEntity.fromId(id);
        if (asset != null) {
          assets.add(asset);
        }
      }
      
      if (assets.isEmpty) return [];
      
      final result = await PhotoManager.editor.deleteWithIds(assetIds);
      return result;
    } catch (e) {
      debugPrint('Error deleting assets: $e');
      return [];
    }
  }

  /// Save image to photo library (iOS)
  Future<AssetEntity?> saveImageToLibrary(Uint8List imageData, {String? title}) async {
    try {
      return await PhotoManager.editor.saveImage(
        imageData,
        filename: title ?? 'FxFiles_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
    } catch (e) {
      debugPrint('Error saving image: $e');
      return null;
    }
  }

  /// Save video to photo library (iOS)
  Future<AssetEntity?> saveVideoToLibrary(File videoFile, {String? title}) async {
    try {
      return await PhotoManager.editor.saveVideo(
        videoFile,
        title: title ?? 'FxFiles_${DateTime.now().millisecondsSinceEpoch}',
      );
    } catch (e) {
      debugPrint('Error saving video: $e');
      return null;
    }
  }

  /// Get all albums/folders
  Future<List<MediaAlbum>> getAlbums({RequestType type = RequestType.common}) async {
    if (!Platform.isIOS) {
      return []; // Android uses file system folders
    }

    final albums = await PhotoManager.getAssetPathList(type: type);
    final result = <MediaAlbum>[];

    for (final album in albums) {
      final count = await album.assetCountAsync;
      result.add(MediaAlbum(
        id: album.id,
        name: album.name,
        assetCount: count,
        isAll: album.isAll,
      ));
    }

    return result;
  }

  /// Get assets from a specific album
  Future<MediaResult> getAlbumAssets(
    String albumId, {
    int offset = 0,
    int limit = 250,
  }) async {
    if (!Platform.isIOS) {
      return MediaResult(files: [], totalCount: 0, hasMore: false);
    }

    final albums = await PhotoManager.getAssetPathList(hasAll: true);
    final album = albums.firstWhere(
      (a) => a.id == albumId,
      orElse: () => albums.first,
    );

    final totalCount = await album.assetCountAsync;
    final assets = await album.getAssetListPaged(
      page: offset ~/ limit,
      size: limit,
    );

    final files = <LocalFile>[];
    for (final asset in assets) {
      final file = await _assetToLocalFile(asset);
      if (file != null) {
        files.add(file);
      }
    }

    return MediaResult(
      files: files,
      totalCount: totalCount,
      hasMore: (offset + limit) < totalCount,
    );
  }

  /// Search photo library by title/filename (iOS only)
  /// On Android, returns empty list (use FileService.searchFiles instead)
  Future<List<LocalFile>> searchPhotoLibrary(String query, {int limit = 100}) async {
    if (!Platform.isIOS || query.isEmpty) {
      return [];
    }

    final queryLower = query.toLowerCase();
    final results = <LocalFile>[];

    try {
      // Get all albums (images, videos, audio)
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        hasAll: true,
        onlyAll: true,
      );

      if (albums.isEmpty) return [];

      final allAlbum = albums.first;
      final totalCount = await allAlbum.assetCountAsync;

      // Search through all assets in batches
      const batchSize = 500;
      var offset = 0;

      while (offset < totalCount && results.length < limit) {
        final assets = await allAlbum.getAssetListPaged(
          page: offset ~/ batchSize,
          size: batchSize,
        );

        for (final asset in assets) {
          if (results.length >= limit) break;

          // Check if title matches query
          final title = asset.title ?? '';
          if (title.toLowerCase().contains(queryLower)) {
            final file = await _assetToLocalFile(asset);
            if (file != null) {
              results.add(file);
            }
          }
        }

        offset += batchSize;
      }
    } catch (e) {
      debugPrint('Error searching photo library: $e');
    }

    return results;
  }

  /// Search photo library by media type
  Future<List<LocalFile>> searchPhotoLibraryByType(
    String query,
    RequestType type, {
    int limit = 100,
  }) async {
    if (!Platform.isIOS || query.isEmpty) {
      return [];
    }

    final queryLower = query.toLowerCase();
    final results = <LocalFile>[];

    try {
      final albums = await PhotoManager.getAssetPathList(
        type: type,
        hasAll: true,
        onlyAll: true,
      );

      if (albums.isEmpty) return [];

      final allAlbum = albums.first;
      final totalCount = await allAlbum.assetCountAsync;

      const batchSize = 500;
      var offset = 0;

      while (offset < totalCount && results.length < limit) {
        final assets = await allAlbum.getAssetListPaged(
          page: offset ~/ batchSize,
          size: batchSize,
        );

        for (final asset in assets) {
          if (results.length >= limit) break;

          final title = asset.title ?? '';
          if (title.toLowerCase().contains(queryLower)) {
            final file = await _assetToLocalFile(asset);
            if (file != null) {
              results.add(file);
            }
          }
        }

        offset += batchSize;
      }
    } catch (e) {
      debugPrint('Error searching photo library by type: $e');
    }

    return results;
  }
}

/// Result class for media queries
class MediaResult {
  final List<LocalFile> files;
  final int totalCount;
  final bool hasMore;

  MediaResult({
    required this.files,
    required this.totalCount,
    required this.hasMore,
  });
}

/// Album/folder representation
class MediaAlbum {
  final String id;
  final String name;
  final int assetCount;
  final bool isAll;

  MediaAlbum({
    required this.id,
    required this.name,
    required this.assetCount,
    this.isAll = false,
  });
}
