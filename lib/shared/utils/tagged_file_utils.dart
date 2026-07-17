import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/media_service.dart';

/// Look up `iosAssetId` for an iOS virtual path (e.g. "PhotoKit/123ABC") by
/// scanning recent files and sync states.
String? lookupIosAssetId(String virtualPath) {
  final recentFiles = LocalStorageService.instance.getRecentFiles(limit: 1000);
  for (final rf in recentFiles) {
    if (rf.path == virtualPath && rf.iosAssetId != null) {
      return rf.iosAssetId;
    }
  }
  return LocalStorageService.instance
      .getSyncStateByDisplayPath(virtualPath)
      ?.iosAssetId;
}

/// Resolves a [TaggedFile] to a usable filesystem path, or null if no such
/// path can be obtained. Handles:
/// - iOS PhotoKit virtual paths (via [MediaService.getOriginalFile])
/// - iOS Documents-relative paths (e.g. "Imported/foo.jpg") that survive
///   sandbox-UUID changes across app updates
/// - stale absolute iOS paths recoverable via the "Documents/" marker
Future<String?> resolveTaggedFilePath(TaggedFile file) async {
  final path = file.localPath;
  if (path == null) return null;
  if (kIsWeb) return null; // local paths don't exist on web

  if (Platform.isIOS && !path.startsWith('/')) {
    // First try Documents-relative resolution (handles "Imported/foo.jpg").
    final appDir = await getApplicationDocumentsDirectory();
    final docsResolved = p.join(appDir.path, path);
    if (File(docsResolved).existsSync()) {
      return docsResolved;
    }
    // Otherwise treat as a PhotoKit virtual path.
    final iosAssetId = file.iosAssetId ?? lookupIosAssetId(path);
    if (iosAssetId == null) return null;
    final actualFile = await MediaService.instance.getOriginalFile(iosAssetId);
    return actualFile?.path;
  }

  if (path.startsWith('/')) {
    if (File(path).existsSync()) return path;
    // iOS sandbox-UUID drift: try recovering via "Documents/" marker.
    if (Platform.isIOS) {
      const marker = 'Documents/';
      final idx = path.indexOf(marker);
      if (idx != -1) {
        final relative = path.substring(idx + marker.length);
        final appDir = await getApplicationDocumentsDirectory();
        final recovered = p.join(appDir.path, relative);
        if (File(recovered).existsSync()) return recovered;
      }
    }
    return null;
  }

  // Non-iOS relative path — resolve against Documents directory.
  final appDir = await getApplicationDocumentsDirectory();
  final resolved = p.join(appDir.path, path);
  return File(resolved).existsSync() ? resolved : null;
}

/// Opens a [TaggedFile] using the same viewer routing as the Files browser:
/// built-in viewers for image/video/audio/text, [OpenFilex] for everything
/// else. Shows a snackbar on resolution failure.
Future<void> openTaggedFile(BuildContext context, TaggedFile file) async {
  final originalPath = file.localPath;
  if (originalPath == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('File location not available')),
    );
    return;
  }

  // Mirror the lookup that resolveTaggedFilePath does internally so the
  // failure-mode snackbar can distinguish "no asset id at all" from "asset
  // id found but the photo is gone".
  final isVirtual = !kIsWeb && Platform.isIOS && !originalPath.startsWith('/');
  final effectiveAssetId = isVirtual
      ? (file.iosAssetId ?? lookupIosAssetId(originalPath))
      : null;

  final filePath = await resolveTaggedFilePath(file);
  if (!context.mounted) return;
  if (filePath == null) {
    final message = isVirtual
        ? (effectiveAssetId != null
            ? 'File no longer available in Photos library'
            : 'Cannot locate file — try re-tagging it')
        : 'File not found';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
    return;
  }

  final localFile = LocalFile(
    path: filePath,
    name: filePath.split(Platform.pathSeparator).last,
    size: 0,
    modifiedAt: DateTime.now(),
    isDirectory: false,
  );

  if (localFile.isImage) {
    context.push('/viewer/image', extra: filePath);
  } else if (localFile.isVideo) {
    context.push('/viewer/video', extra: filePath);
  } else if (localFile.isAudio) {
    context.push('/viewer/audio', extra: filePath);
  } else if (localFile.isTextViewable) {
    context.push('/viewer/text', extra: filePath);
  } else {
    final result = await OpenFilex.open(filePath);
    if (result.type != ResultType.done && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open file: ${result.message}')),
      );
    }
  }
}
