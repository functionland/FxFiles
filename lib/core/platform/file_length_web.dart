/// Web stub: path-based file access does not exist in browsers. The
/// path-based upload variants that call this are never invoked by the web
/// shell (web uploads pass picked bytes, not paths).
Future<int> fileLength(String path) =>
    throw UnsupportedError('fileLength($path): no filesystem paths on web');
