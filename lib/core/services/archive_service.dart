import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Result of an archive operation
class ArchiveResult {
  final bool success;
  final String? outputPath;
  final String? error;
  final int fileCount;

  ArchiveResult({
    required this.success,
    this.outputPath,
    this.error,
    this.fileCount = 0,
  });
}

/// Information about an archive
class ArchiveInfo {
  final String path;
  final int fileCount;
  final int totalSize;
  final int compressedSize;
  final List<ArchiveEntry> entries;

  ArchiveInfo({
    required this.path,
    required this.fileCount,
    required this.totalSize,
    required this.compressedSize,
    required this.entries,
  });
}

/// Entry in an archive
class ArchiveEntry {
  final String name;
  final bool isDirectory;
  final int size;
  final int compressedSize;
  final DateTime? modified;

  ArchiveEntry({
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.compressedSize,
    this.modified,
  });
}

/// Service for handling archive operations (zip/unzip)
class ArchiveService {
  ArchiveService._();
  static final ArchiveService instance = ArchiveService._();

  /// Supported archive extensions
  static const supportedExtensions = ['zip', 'tar', 'gz', 'tgz', 'tar.gz', 'bz2', 'tbz', 'tar.bz2'];

  /// Check if a file is a supported archive
  bool isArchive(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    return supportedExtensions.contains(ext) || path.toLowerCase().endsWith('.tar.gz');
  }

  /// Get information about an archive without extracting
  Future<ArchiveInfo?> getArchiveInfo(String archivePath) async {
    try {
      final file = File(archivePath);
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      int totalSize = 0;
      final entries = <ArchiveEntry>[];

      for (final entry in archive) {
        totalSize += entry.size;
        entries.add(ArchiveEntry(
          name: entry.name,
          isDirectory: entry.isFile == false,
          size: entry.size,
          compressedSize: entry.size, // Archive package doesn't expose compressed size
          modified: entry.lastModTime != null
              ? DateTime.fromMillisecondsSinceEpoch(entry.lastModTime! * 1000)
              : null,
        ));
      }

      // Use actual file size as compressed size
      final fileStat = await file.stat();

      return ArchiveInfo(
        path: archivePath,
        fileCount: archive.length,
        totalSize: totalSize,
        compressedSize: fileStat.size,
        entries: entries,
      );
    } catch (e) {
      debugPrint('Error reading archive info: $e');
      return null;
    }
  }

  /// Extract a zip archive to a specified directory
  /// If [outputDir] is null, extracts to a folder with the archive name
  Future<ArchiveResult> extractZip(
    String archivePath, {
    String? outputDir,
    void Function(int current, int total)? onProgress,
  }) async {
    try {
      final file = File(archivePath);
      if (!await file.exists()) {
        return ArchiveResult(success: false, error: 'Archive file not found');
      }

      // Determine output directory
      final archiveName = p.basenameWithoutExtension(archivePath);
      final parentDir = p.dirname(archivePath);
      final extractDir = outputDir ?? p.join(parentDir, archiveName);

      // Create output directory
      final outDir = Directory(extractDir);
      if (!await outDir.exists()) {
        await outDir.create(recursive: true);
      }

      // Extract in isolate to avoid blocking UI
      final result = await compute(_extractZipIsolate, {
        'archivePath': archivePath,
        'outputDir': extractDir,
      });

      if (result['success'] == true) {
        return ArchiveResult(
          success: true,
          outputPath: extractDir,
          fileCount: result['fileCount'] as int,
        );
      } else {
        return ArchiveResult(
          success: false,
          error: result['error'] as String?,
        );
      }
    } catch (e) {
      return ArchiveResult(success: false, error: e.toString());
    }
  }

  /// Compress files/folders into a zip archive
  /// [paths] - List of file/folder paths to compress
  /// [outputPath] - Path for the output zip file (optional, will auto-generate if not provided)
  Future<ArchiveResult> compressToZip(
    List<String> paths, {
    String? outputPath,
    void Function(int current, int total)? onProgress,
  }) async {
    try {
      if (paths.isEmpty) {
        return ArchiveResult(success: false, error: 'No files to compress');
      }

      // Filter to only include valid file paths (not content:// URIs)
      final validPaths = paths.where((path) {
        if (path.startsWith('content://')) return false;
        return File(path).existsSync() || Directory(path).existsSync();
      }).toList();

      if (validPaths.isEmpty) {
        return ArchiveResult(success: false, error: 'No valid files to compress');
      }

      // Determine output path
      String zipPath;
      if (outputPath != null) {
        zipPath = outputPath;
      } else {
        // Generate name based on first file or folder
        final firstName = p.basenameWithoutExtension(validPaths.first);
        final parentDir = p.dirname(validPaths.first);

        if (validPaths.length == 1) {
          zipPath = p.join(parentDir, '$firstName.zip');
        } else {
          zipPath = p.join(parentDir, '${firstName}_and_${validPaths.length - 1}_more.zip');
        }

        // Ensure unique filename
        zipPath = await _getUniqueFilePath(zipPath);
      }

      debugPrint('ArchiveService: Compressing ${validPaths.length} files to $zipPath');

      // Run compression directly (compute can have issues with some file operations)
      final result = await _compressZipAsync(validPaths, zipPath);

      debugPrint('ArchiveService: Compression result: $result');

      if (result['success'] == true) {
        return ArchiveResult(
          success: true,
          outputPath: zipPath,
          fileCount: result['fileCount'] as int,
        );
      } else {
        return ArchiveResult(
          success: false,
          error: result['error'] as String?,
        );
      }
    } catch (e) {
      debugPrint('ArchiveService: Compression error: $e');
      return ArchiveResult(success: false, error: e.toString());
    }
  }

  /// Async compression that runs on main isolate but yields to UI
  Future<Map<String, dynamic>> _compressZipAsync(List<String> paths, String outputPath) async {
    try {
      final archive = Archive();
      int fileCount = 0;

      for (final path in paths) {
        final entityType = FileSystemEntity.typeSync(path);

        if (entityType == FileSystemEntityType.file) {
          // Add single file
          final file = File(path);
          final bytes = await file.readAsBytes();
          final archiveFile = ArchiveFile(
            p.basename(path),
            bytes.length,
            bytes,
          );
          archive.addFile(archiveFile);
          fileCount++;
        } else if (entityType == FileSystemEntityType.directory) {
          // Add directory recursively
          final dir = Directory(path);

          await for (final entity in dir.list(recursive: true)) {
            if (entity is File) {
              final relativePath = p.relative(entity.path, from: p.dirname(path));
              final bytes = await entity.readAsBytes();
              final archiveFile = ArchiveFile(
                relativePath,
                bytes.length,
                bytes,
              );
              archive.addFile(archiveFile);
              fileCount++;
            }
          }
        }

        // Yield to allow UI updates
        await Future.delayed(Duration.zero);
      }

      // Encode and write the zip file
      debugPrint('ArchiveService: Encoding $fileCount files...');
      final zipData = ZipEncoder().encode(archive);
      if (zipData != null) {
        await File(outputPath).writeAsBytes(zipData);
        debugPrint('ArchiveService: Written to $outputPath');
        return {'success': true, 'fileCount': fileCount};
      } else {
        return {'success': false, 'error': 'Failed to encode zip file'};
      }
    } catch (e) {
      debugPrint('ArchiveService: _compressZipAsync error: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Get a unique file path by appending numbers if file exists
  Future<String> _getUniqueFilePath(String path) async {
    var file = File(path);
    if (!await file.exists()) return path;

    final dir = p.dirname(path);
    final name = p.basenameWithoutExtension(path);
    final ext = p.extension(path);

    int counter = 1;
    while (await file.exists()) {
      file = File(p.join(dir, '$name ($counter)$ext'));
      counter++;
    }
    return file.path;
  }
}

/// Isolate function for extracting zip files
Map<String, dynamic> _extractZipIsolate(Map<String, String> params) {
  try {
    final archivePath = params['archivePath']!;
    final outputDir = params['outputDir']!;

    final bytes = File(archivePath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);

    int fileCount = 0;
    for (final file in archive) {
      final filePath = p.join(outputDir, file.name);

      if (file.isFile) {
        final outFile = File(filePath);
        outFile.createSync(recursive: true);
        outFile.writeAsBytesSync(file.content as List<int>);
        fileCount++;
      } else {
        Directory(filePath).createSync(recursive: true);
      }
    }

    return {'success': true, 'fileCount': fileCount};
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

/// Isolate function for compressing files to zip
Map<String, dynamic> _compressZipIsolate(Map<String, dynamic> params) {
  try {
    final paths = (params['paths'] as List).cast<String>();
    final outputPath = params['outputPath'] as String;

    final archive = Archive();
    int fileCount = 0;

    for (final path in paths) {
      final entity = FileSystemEntity.typeSync(path);

      if (entity == FileSystemEntityType.file) {
        // Add single file
        final file = File(path);
        final bytes = file.readAsBytesSync();
        final archiveFile = ArchiveFile(
          p.basename(path),
          bytes.length,
          bytes,
        );
        archive.addFile(archiveFile);
        fileCount++;
      } else if (entity == FileSystemEntityType.directory) {
        // Add directory recursively
        final dir = Directory(path);
        final baseName = p.basename(path);

        for (final entity in dir.listSync(recursive: true)) {
          if (entity is File) {
            final relativePath = p.relative(entity.path, from: p.dirname(path));
            final bytes = entity.readAsBytesSync();
            final archiveFile = ArchiveFile(
              relativePath,
              bytes.length,
              bytes,
            );
            archive.addFile(archiveFile);
            fileCount++;
          }
        }
      }
    }

    // Encode and write the zip file
    final zipData = ZipEncoder().encode(archive);
    if (zipData != null) {
      File(outputPath).writeAsBytesSync(zipData);
      return {'success': true, 'fileCount': fileCount};
    } else {
      return {'success': false, 'error': 'Failed to encode zip file'};
    }
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}
