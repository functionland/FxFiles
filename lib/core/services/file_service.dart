import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/services/local_storage_service.dart';

class FileService {
  FileService._();
  static final FileService instance = FileService._();

  static const _storageChannel = MethodChannel('land.fx.files/storage');

  /// Request storage permission appropriate for a file manager app
  ///
  /// For Android 11+ (API 30+), this requests MANAGE_EXTERNAL_STORAGE permission
  /// which is required for file manager apps per Google Play policy.
  /// This will direct users to Settings → Special App Access → All Files Access
  Future<bool> requestStoragePermission() async {
    if (Platform.isAndroid) {
      // Check Android version for appropriate permission strategy
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final sdkInt = androidInfo.version.sdkInt;

      if (sdkInt >= 30) {
        // Android 11+ (API 30+): File managers should use MANAGE_EXTERNAL_STORAGE
        // This is the correct permission for file manager apps per Google policy

        // First check if already granted using native method
        try {
          final hasPermission = await _storageChannel.invokeMethod<bool>('hasManageStoragePermission');
          if (hasPermission == true) return true;
        } catch (e) {
          debugPrint('Error checking storage permission: $e');
        }

        // Try standard permission request first
        final status = await Permission.manageExternalStorage.status;
        if (!status.isGranted) {
          final result = await Permission.manageExternalStorage.request();
          if (result.isGranted) return true;
        }

        // If still not granted, use native method to open specific settings page
        // This opens Settings → Special App Access → All Files Access for this app
        try {
          await _storageChannel.invokeMethod('openManageStorageSettings');
          // Return false as user needs to manually enable in settings
          return false;
        } catch (e) {
          debugPrint('Error opening storage settings: $e');
          // Fallback to general app settings
          await openAppSettings();
          return false;
        }
      } else {
        // Android 10 and below - use legacy storage permission
        final status = await Permission.storage.request();
        return status.isGranted;
      }
    } else if (Platform.isIOS) {
      // iOS: Request photo library permission via PhotoManager
      final permission = await PhotoManager.requestPermissionExtend();
      // Accept both authorized and limited access
      return permission.isAuth || permission == PermissionState.limited;
    } else {
      return true;
    }
  }

  /// Check if storage permission is currently granted
  /// For Android 11+, this checks MANAGE_EXTERNAL_STORAGE permission
  Future<bool> hasStoragePermission() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final sdkInt = androidInfo.version.sdkInt;

      if (sdkInt >= 30) {
        // Use native method to check MANAGE_EXTERNAL_STORAGE
        try {
          final hasPermission = await _storageChannel.invokeMethod<bool>('hasManageStoragePermission');
          return hasPermission ?? false;
        } catch (e) {
          debugPrint('Error checking storage permission: $e');
          // Fallback to permission_handler
          final status = await Permission.manageExternalStorage.status;
          return status.isGranted;
        }
      } else {
        final status = await Permission.storage.status;
        return status.isGranted;
      }
    } else if (Platform.isIOS) {
      final state = await PhotoManager.getPermissionState(
        requestOption: PermissionRequestOption(),
      );
      return state.isAuth || state == PermissionState.limited;
    } else {
      return true;
    }
  }
  
  /// Check if iOS photo library access is limited (user selected specific photos only)
  Future<bool> isIOSLimitedAccess() async {
    if (!Platform.isIOS) return false;
    final state = await PhotoManager.getPermissionState(
      requestOption: PermissionRequestOption(),
    );
    return state == PermissionState.limited;
  }
  
  /// Open iOS limited photos picker to let user select more photos
  Future<void> openIOSLimitedPhotosPicker() async {
    if (Platform.isIOS) {
      await PhotoManager.presentLimited();
    }
  }

  Future<List<Directory>> getStorageRoots() async {
    final roots = <Directory>[];

    if (Platform.isAndroid) {
      final externalDirs = await getExternalStorageDirectories();
      if (externalDirs != null) {
        for (final dir in externalDirs) {
          final pathParts = dir.path.split('/');
          final androidIndex = pathParts.indexOf('Android');
          if (androidIndex > 0) {
            final rootPath = pathParts.sublist(0, androidIndex).join('/');
            final root = Directory(rootPath);
            if (await root.exists() && !roots.any((r) => r.path == rootPath)) {
              roots.add(root);
            }
          }
        }
      }

      final internalRoot = Directory('/storage/emulated/0');
      if (await internalRoot.exists() && !roots.any((r) => r.path == internalRoot.path)) {
        roots.insert(0, internalRoot);
      }
    } else if (Platform.isIOS) {
      final appDir = await getApplicationDocumentsDirectory();
      roots.add(appDir);
    } else if (Platform.isWindows) {
      for (var i = 67; i <= 90; i++) {
        final driveLetter = String.fromCharCode(i);
        final drive = Directory('$driveLetter:\\');
        if (await drive.exists()) {
          roots.add(drive);
        }
      }
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null) {
        roots.add(Directory(home));
      }
      roots.add(Directory('/'));
    } else if (Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home != null) {
        roots.add(Directory(home));
      }
      roots.add(Directory('/'));
    }

    return roots;
  }

  Future<List<LocalFile>> listDirectory(
    String path, {
    bool showHidden = false,
    String? sortBy,
    bool ascending = true,
  }) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      throw FileServiceException('Directory does not exist: $path');
    }

    final files = <LocalFile>[];
    
    try {
      await for (final entity in dir.list()) {
        final name = p.basename(entity.path);
        
        if (!showHidden && name.startsWith('.')) continue;

        if (entity is File) {
          final stat = await entity.stat();
          files.add(LocalFile(
            path: entity.path,
            name: name,
            size: stat.size,
            modifiedAt: stat.modified,
            isDirectory: false,
            mimeType: lookupMimeType(entity.path),
          ));
        } else if (entity is Directory) {
          final stat = await entity.stat();
          files.add(LocalFile(
            path: entity.path,
            name: name,
            size: 0,
            modifiedAt: stat.modified,
            isDirectory: true,
          ));
        }
      }
    } catch (e) {
      throw FileServiceException('Failed to list directory: $e');
    }

    files.sort((a, b) {
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;

      int comparison;
      switch (sortBy) {
        case 'name':
          comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case 'size':
          comparison = a.size.compareTo(b.size);
          break;
        case 'date':
          comparison = a.modifiedAt.compareTo(b.modifiedAt);
          break;
        default:
          comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }

      return ascending ? comparison : -comparison;
    });

    return files;
  }

  Future<Uint8List> readFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileServiceException('File does not exist: $path');
    }
    return await file.readAsBytes();
  }

  Future<void> writeFile(String path, Uint8List data) async {
    final file = File(path);
    await file.writeAsBytes(data);
  }

  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> deleteDirectory(String path, {bool recursive = true}) async {
    final dir = Directory(path);
    if (await dir.exists()) {
      await dir.delete(recursive: recursive);
    }
  }

  Future<void> createDirectory(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  Future<void> moveFile(String sourcePath, String destPath) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw FileServiceException('Source file does not exist: $sourcePath');
    }

    await sourceFile.rename(destPath);
  }

  Future<void> copyFile(String sourcePath, String destPath) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw FileServiceException('Source file does not exist: $sourcePath');
    }

    await sourceFile.copy(destPath);
  }

  Future<void> renameFile(String path, String newName) async {
    final newPath = p.join(p.dirname(path), newName);
    
    // Check if target already exists
    if (await File(newPath).exists() || await Directory(newPath).exists()) {
      throw FileServiceException('A file or folder with that name already exists');
    }
    
    final entityType = FileSystemEntity.typeSync(path);
    
    if (entityType == FileSystemEntityType.file) {
      final file = File(path);
      if (!await file.exists()) {
        throw FileServiceException('File no longer exists');
      }
      try {
        await file.rename(newPath);
      } catch (e) {
        // On Android, rename may fail across filesystems or due to permissions
        // Try copy + delete as fallback
        try {
          await file.copy(newPath);
          await file.delete();
        } catch (e2) {
          throw FileServiceException('Cannot rename: Permission denied or file in use');
        }
      }
    } else if (entityType == FileSystemEntityType.directory) {
      final dir = Directory(path);
      if (!await dir.exists()) {
        throw FileServiceException('Folder no longer exists');
      }
      try {
        await dir.rename(newPath);
      } catch (e) {
        throw FileServiceException('Cannot rename folder: Permission denied');
      }
    } else {
      throw FileServiceException('Path does not exist: $path');
    }
  }

  Future<int> getDirectorySize(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return 0;

    var size = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        size += await entity.length();
      }
    }
    return size;
  }

  Future<Directory> getTrashDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final trashDir = Directory(p.join(appDir.path, '.trash'));
    if (!await trashDir.exists()) {
      await trashDir.create(recursive: true);
    }
    return trashDir;
  }

  Future<void> moveToTrash(String path) async {
    final trashDir = await getTrashDirectory();
    final name = p.basename(path);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final trashPath = p.join(trashDir.path, '${timestamp}_$name');

    final file = File(path);
    final dir = Directory(path);
    final isFile = await file.exists();
    final isDir = !isFile && await dir.exists();
    
    if (!isFile && !isDir) {
      throw FileServiceException('File no longer exists');
    }
    
    if (isFile) {
      try {
        await file.rename(trashPath);
      } catch (e) {
        // Cross-device: copy then delete
        if (!await file.exists()) {
          throw FileServiceException('File no longer exists');
        }
        await file.copy(trashPath);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } else {
      try {
        await dir.rename(trashPath);
      } catch (e) {
        // Cross-device: copy recursively then delete
        if (!await dir.exists()) {
          throw FileServiceException('Folder no longer exists');
        }
        await _copyDirectory(dir, Directory(trashPath));
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final newPath = p.join(destination.path, p.basename(entity.path));
      if (entity is File) {
        await entity.copy(newPath);
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      }
    }
  }

  Future<List<LocalFile>> getTrashContents() async {
    final trashDir = await getTrashDirectory();
    return await listDirectory(trashDir.path, showHidden: true);
  }

  Future<void> restoreFromTrash(String trashPath, String originalPath) async {
    final entity = FileSystemEntity.typeSync(trashPath);
    if (entity == FileSystemEntityType.file) {
      await File(trashPath).rename(originalPath);
    } else if (entity == FileSystemEntityType.directory) {
      await Directory(trashPath).rename(originalPath);
    }
  }

  Future<void> emptyTrash() async {
    final trashDir = await getTrashDirectory();
    await for (final entity in trashDir.list()) {
      await entity.delete(recursive: true);
    }
  }

  Future<Directory> getDownloadsDirectory() async {
    if (Platform.isAndroid) {
      return Directory('/storage/emulated/0/Download');
    } else if (Platform.isIOS) {
      return await getApplicationDocumentsDirectory();
    } else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final downloads = await getDownloadsDirectory();
      return downloads;
    }
    return await getApplicationDocumentsDirectory();
  }

  Future<List<LocalFile>> searchFiles(String query, {String? rootPath}) async {
    final results = <LocalFile>[];
    final roots = rootPath != null ? [Directory(rootPath)] : await getStorageRoots();
    final queryLower = query.toLowerCase();
    
    for (final root in roots) {
      await _searchDirectory(root, queryLower, results);
      if (results.length >= 100) break;
    }
    
    return results;
  }
  
  Future<void> _searchDirectory(Directory dir, String query, List<LocalFile> results) async {
    if (results.length >= 100) return;
    if (_shouldSkipDirectory(dir.path)) return;
    
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (results.length >= 100) return;
        
        final name = p.basename(entity.path);
        
        if (entity is Directory) {
          // Search subdirectory
          await _searchDirectory(entity, query, results);
        } else if (name.toLowerCase().contains(query)) {
          try {
            final stat = await entity.stat();
            results.add(LocalFile.fromFileSystemEntity(entity, stat));
          } catch (_) {}
        }
      }
    } catch (e) {
      // Skip directories we can't access
    }
  }

  Future<Directory> getCategoryDirectory(FileCategory category) async {
    if (Platform.isAndroid) {
      switch (category) {
        case FileCategory.images:
          return Directory('/storage/emulated/0/DCIM');
        case FileCategory.videos:
          return Directory('/storage/emulated/0/Movies');
        case FileCategory.audio:
          return Directory('/storage/emulated/0/Music');
        case FileCategory.documents:
          return Directory('/storage/emulated/0/Documents');
        case FileCategory.downloads:
          return Directory('/storage/emulated/0/Download');
        default:
          return Directory('/storage/emulated/0');
      }
    }
    return await getApplicationDocumentsDirectory();
  }

  // Directories to skip during recursive scanning
  static const _restrictedDirs = {
    'Android/data',
    'Android/obb', 
    'Android/media',
    '.thumbnails',
    '.cache',
    '.trash',
  };

  bool _shouldSkipDirectory(String path) {
    final lowerPath = path.toLowerCase();
    for (final restricted in _restrictedDirs) {
      if (lowerPath.contains(restricted.toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  /// Get files matching a category with pagination support
  /// Returns files sorted by [sortBy] ('date' or 'name'), with [limit] items starting at [offset]
  Future<CategoryResult> getFilesByCategory(
    FileCategory category, {
    int offset = 0,
    int limit = 250,
    String sortBy = 'date',
    bool ascending = false,
  }) async {
    final allFiles = await _scanForCategoryFiles(category);
    
    // Sort
    allFiles.sort((a, b) {
      int comparison;
      if (sortBy == 'name') {
        comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      } else {
        comparison = a.modifiedAt.compareTo(b.modifiedAt);
      }
      return ascending ? comparison : -comparison;
    });
    
    // Paginate
    final totalCount = allFiles.length;
    final endIndex = (offset + limit).clamp(0, totalCount);
    final paginatedFiles = offset < totalCount 
        ? allFiles.sublist(offset, endIndex) 
        : <LocalFile>[];
    
    return CategoryResult(
      files: paginatedFiles,
      totalCount: totalCount,
      hasMore: endIndex < totalCount,
    );
  }

  Future<List<LocalFile>> _scanForCategoryFiles(FileCategory category) async {
    final results = <LocalFile>[];
    final roots = await getStorageRoots();
    final extensions = _getCategoryExtensions(category);
    
    for (final root in roots) {
      await _scanDirectoryForFiles(root, extensions, results);
    }
    
    return results;
  }

  Future<void> _scanDirectoryForFiles(
    Directory dir,
    Set<String> extensions,
    List<LocalFile> results,
  ) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          // Skip restricted directories
          if (!_shouldSkipDirectory(entity.path)) {
            await _scanDirectoryForFiles(entity, extensions, results);
          }
        } else if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
          if (extensions.contains(ext)) {
            try {
              final stat = await entity.stat();
              results.add(LocalFile(
                path: entity.path,
                name: p.basename(entity.path),
                size: stat.size,
                modifiedAt: stat.modified,
                isDirectory: false,
                mimeType: lookupMimeType(entity.path),
              ));
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      // Skip directories we can't access
      debugPrint('Skipping inaccessible directory: ${dir.path}');
    }
  }

  Set<String> _getCategoryExtensions(FileCategory category) {
    switch (category) {
      case FileCategory.images:
        return {'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif', 'svg', 'raw', 'cr2', 'nef', 'arw'};
      case FileCategory.videos:
        return {'mp4', 'mov', 'avi', 'mkv', 'wmv', 'flv', 'webm', '3gp', 'm4v', 'mpeg', 'mpg'};
      case FileCategory.audio:
        return {'mp3', 'wav', 'aac', 'flac', 'ogg', 'wma', 'm4a', 'opus', 'aiff'};
      case FileCategory.documents:
        return {'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf', 'odt', 'ods', 'odp', 'csv', 'md', 'json', 'xml', 'html', 'log', 'ini', 'cfg', 'conf'};
      case FileCategory.archives:
        return {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'iso'};
      case FileCategory.downloads:
        return {}; // Downloads uses directory, not extensions
      case FileCategory.starred:
        return {}; // Starred uses local storage, not extensions
      case FileCategory.other:
        return {};
    }
  }

  /// Get starred files from local storage
  Future<List<LocalFile>> getStarredFiles() async {
    final starredPaths = LocalStorageService.instance.getStarredFiles();
    final results = <LocalFile>[];

    for (final path in starredPaths) {
      try {
        // Check what type of entity this is (file, directory, or non-existent)
        final entityType = await FileSystemEntity.type(path);

        if (entityType == FileSystemEntityType.file) {
          final file = File(path);
          final stat = await file.stat();
          results.add(LocalFile(
            path: path,
            name: p.basename(path),
            size: stat.size,
            modifiedAt: stat.modified,
            isDirectory: false,
            mimeType: lookupMimeType(path),
          ));
        } else if (entityType == FileSystemEntityType.directory) {
          final dir = Directory(path);
          final stat = await dir.stat();
          results.add(LocalFile(
            path: path,
            name: p.basename(path),
            size: stat.size,
            modifiedAt: stat.modified,
            isDirectory: true,
          ));
        }
        // If entityType is notFound or link, skip this entry
      } catch (_) {}
    }

    return results;
  }
}

enum FileCategory {
  images,
  videos,
  audio,
  documents,
  downloads,
  archives,
  starred,
  other;
  
  /// Get bucket name for this category (lowercase)
  String get bucketName => name.toLowerCase();
  
  /// Get category from file extension
  static FileCategory fromExtension(String extension) {
    final ext = extension.toLowerCase();
    if ({'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif', 'svg', 'raw', 'cr2', 'nef', 'arw'}.contains(ext)) {
      return FileCategory.images;
    }
    if ({'mp4', 'mov', 'avi', 'mkv', 'wmv', 'flv', 'webm', '3gp', 'm4v', 'mpeg', 'mpg'}.contains(ext)) {
      return FileCategory.videos;
    }
    if ({'mp3', 'wav', 'aac', 'flac', 'ogg', 'wma', 'm4a', 'opus', 'aiff'}.contains(ext)) {
      return FileCategory.audio;
    }
    if ({'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf', 'odt', 'ods', 'odp', 'csv', 'md', 'json', 'xml', 'html', 'log', 'ini', 'cfg', 'conf'}.contains(ext)) {
      return FileCategory.documents;
    }
    if ({'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'iso'}.contains(ext)) {
      return FileCategory.archives;
    }
    return FileCategory.other;
  }
  
  /// Get category from file path
  static FileCategory fromPath(String path) {
    final ext = path.split('.').last;
    return fromExtension(ext);
  }
}

class FileServiceException implements Exception {
  final String message;
  FileServiceException(this.message);

  @override
  String toString() => 'FileServiceException: $message';
}

class CategoryResult {
  final List<LocalFile> files;
  final int totalCount;
  final bool hasMore;

  CategoryResult({
    required this.files,
    required this.totalCount,
    required this.hasMore,
  });
}
