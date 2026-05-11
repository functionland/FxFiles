// Creates throwaway files on the device's temp dir for upload tests.
//
// Files are auto-cleaned by the OS when the app sandbox is cleared,
// but tests should still call [dispose] in teardown so per-test
// state doesn't accumulate within a session.

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class TestFixture {
  final File file;
  final Uint8List bytes;

  TestFixture._(this.file, this.bytes);

  /// Write a file of [sizeBytes] deterministic bytes into the app's
  /// temp dir. The content is `(index & 0xFF)` so the test can
  /// regenerate it locally without a separate fixture asset.
  static Future<TestFixture> createSmall({
    required String name,
    int sizeBytes = 1024,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final path = '${tempDir.path}/test-fixture-$name';
    final bytes = Uint8List.fromList(
      List<int>.generate(sizeBytes, (i) => i & 0xFF),
    );
    final file = File(path);
    await file.writeAsBytes(bytes);
    return TestFixture._(file, bytes);
  }

  /// Variant that crosses the 768 KB chunked-upload threshold so
  /// scenarios that need the chunked path exercise it.
  static Future<TestFixture> createLarge({
    required String name,
    int sizeBytes = 1024 * 1024,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final path = '${tempDir.path}/test-fixture-large-$name';
    final bytes = Uint8List.fromList(
      List<int>.generate(sizeBytes, (i) => (i * 7) & 0xFF),
    );
    final file = File(path);
    await file.writeAsBytes(bytes);
    return TestFixture._(file, bytes);
  }

  Future<void> dispose() async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort — temp files are OS-cleaned anyway.
    }
  }
}
