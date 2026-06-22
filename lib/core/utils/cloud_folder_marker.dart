/// Hidden keep-marker used to materialize empty folders in the encrypted
/// forest. Folders are virtual key-prefixes (there is no `mkdir`), so an empty
/// folder needs at least one object under it. Defined in `core` because the
/// storage layer (`FulaApiService.createFolder`) writes it; the web file
/// browser filters it from display (`stripFolderMarkers` in
/// `web/utils/cloud_folder_tree.dart`, which re-exports these).
const String kFolderMarkerName = '.fula_keep';

/// Tiny NON-empty body for the marker (empty PUTs can misbehave on the gateway).
List<int> folderMarkerBytes() => kFolderMarkerName.codeUnits;
