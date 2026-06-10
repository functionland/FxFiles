// Platform seam for measuring a file's size from a filesystem path.
//
// The IO implementation backs the path-based upload variants in
// FulaApiService (sync-queue uploads, resumable uploads). The web
// implementation throws: web uploads carry bytes picked in memory, never
// filesystem paths, so these call sites are unreachable in the web shell.
export 'file_length_io.dart' if (dart.library.js_interop) 'file_length_web.dart';
