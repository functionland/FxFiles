import 'dart:io';

/// Size in bytes of the file at [path], without reading its contents.
Future<int> fileLength(String path) => File(path).length();
