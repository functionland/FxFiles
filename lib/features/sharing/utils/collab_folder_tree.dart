/// Pure folder-tree derivation for a collaboration group, shared by the
/// native detail screen (`collaboration_detail_screen.dart`) and the web shell
/// (`web_collab_detail_screen.dart`) so both render an identical folder
/// hierarchy. Extracted from the native `_itemsAtPath` so the two platforms
/// can't drift.
///
/// A collab group stores a FLAT file list; folders are derived from each
/// file's `pathScope`. Only collab-uploaded files (`encType == 'collab'`,
/// which includes files an AI agent adds) carry a folder path in `pathScope`;
/// fula-encrypted files keep their storage key there, so they always render at
/// the root. AI-added files therefore render exactly like owner files.
library;

import 'package:fula_files/core/models/collaboration_group.dart';

/// Folders and files visible at [currentPath] (use `''` for the root).
({List<String> folders, List<CollaborationFile> files}) collabItemsAtPath(
  CollaborationGroup group,
  String currentPath,
) {
  final folderSet = <String>{};
  final filesHere = <CollaborationFile>[];

  for (final file in group.files) {
    // Only collab-uploaded files use pathScope as folder path.
    // Fula files have pathScope as storage key — show at root.
    final filePath = file.encType == 'collab' ? (file.pathScope ?? '') : '';
    final isFolder = file.contentType == 'application/x-directory';

    if (currentPath.isEmpty) {
      if (filePath.isEmpty) {
        if (!isFolder) filesHere.add(file);
      } else {
        folderSet.add(filePath.split('/')[0]);
      }
    } else {
      if (filePath == currentPath && !isFolder) {
        filesHere.add(file);
      } else if (filePath.startsWith('$currentPath/')) {
        final remainder = filePath.substring(currentPath.length + 1);
        folderSet.add(remainder.split('/')[0]);
      }
    }
  }

  // Also pick up explicit folder markers at this level
  for (final file in group.files) {
    if (file.contentType == 'application/x-directory' && file.pathScope != null) {
      final parent = file.pathScope!.contains('/')
          ? file.pathScope!.substring(0, file.pathScope!.lastIndexOf('/'))
          : '';
      if (parent == currentPath) {
        final name =
            file.pathScope!.substring(parent.isEmpty ? 0 : parent.length + 1);
        if (name.isNotEmpty && !name.contains('/')) {
          folderSet.add(name);
        }
      }
    }
  }

  final sortedFolders = folderSet.toList()..sort((a, b) => a.compareTo(b));
  filesHere.sort((a, b) => a.addedAt.compareTo(b.addedAt));
  return (folders: sortedFolders, files: filesHere);
}

/// Count of non-directory files at or beneath [folderPath].
int collabCountFolderFiles(CollaborationGroup group, String folderPath) {
  return group.files.where((f) {
    final p = f.encType == 'collab' ? (f.pathScope ?? '') : '';
    return (p == folderPath || p.startsWith('$folderPath/')) &&
        f.contentType != 'application/x-directory';
  }).length;
}
