import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/upload_progress.dart';
import 'package:fula_files/core/services/upload_progress_manager.dart';

UploadProgressState _state({
  int totalBytes = 1000,
  int? bytesUploaded,
  Duration elapsedAgo = Duration.zero,
  Duration estimated = const Duration(seconds: 100),
}) {
  return UploadProgressState(
    localPath: '/a.mp4',
    remoteKey: '/a.mp4',
    fileName: 'a.mp4',
    totalBytes: totalBytes,
    bytesUploaded: bytesUploaded,
    startedAt: DateTime.now().subtract(elapsedAgo),
    estimatedDuration: estimated,
  );
}

void main() {
  group('UploadProgressState.percentage', () {
    test('uses REAL bytes when bytesUploaded is set', () {
      expect(_state(totalBytes: 1000, bytesUploaded: 250).percentage, 25.0);
      expect(_state(totalBytes: 1000, bytesUploaded: 900).percentage, 90.0);
    });

    test('caps real-byte progress at 99% (never 100 until completion)', () {
      // SDK cumulative bytes reach total at the last chunk PUT, before the
      // index PUT + forest-flush tail — so the bar must hold at 99%.
      expect(_state(totalBytes: 1000, bytesUploaded: 1000).percentage, 99.0);
      expect(_state(totalBytes: 1000, bytesUploaded: 5000).percentage, 99.0);
    });

    test('falls back to the time estimate when bytesUploaded is null', () {
      // Half the estimated duration elapsed, no real bytes -> ~50%.
      final pct = _state(
        bytesUploaded: null,
        elapsedAgo: const Duration(seconds: 50),
        estimated: const Duration(seconds: 100),
      ).percentage;
      expect(pct, greaterThan(45));
      expect(pct, lessThan(55));
    });

    test('real bytes take precedence over the time estimate', () {
      // Lots of wall-clock elapsed (estimate would say ~99%) but only 10% of
      // bytes actually uploaded -> the real 10% wins.
      final pct = _state(
        totalBytes: 1000,
        bytesUploaded: 100,
        elapsedAgo: const Duration(seconds: 200),
        estimated: const Duration(seconds: 100),
      ).percentage;
      expect(pct, 10.0);
    });
  });

  group('UploadProgressManager.updateProgress', () {
    setUp(() => UploadProgressManager.instance.reset());
    tearDown(() => UploadProgressManager.instance.reset());

    test('feeds real bytes into the tracked upload', () {
      final mgr = UploadProgressManager.instance;
      mgr.startBatch(totalFiles: 1, totalBytes: 1000);
      mgr.startUpload(localPath: '/a.mp4', remoteKey: '/a.mp4', totalBytes: 1000);

      mgr.updateProgress('/a.mp4', 400);
      final s = mgr.getFileProgress('/a.mp4')!;
      expect(s.bytesUploaded, 400);
      expect(s.percentage, 40.0);
    });

    test('is a no-op for an untracked / already-completed path', () {
      final mgr = UploadProgressManager.instance;
      mgr.startBatch(totalFiles: 1, totalBytes: 1000);
      // Never started for this path — must not throw, must not create it.
      mgr.updateProgress('/missing.mp4', 999);
      expect(mgr.getFileProgress('/missing.mp4'), isNull);
    });
  });
}
