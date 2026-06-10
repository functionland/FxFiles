// Phase 0 — baseline oracle capture (read-only).
//
// Records, for the signed-in account, the current state of the LEGACY
// content buckets BEFORE any migration: per-bucket object count + a few
// (key -> size + sha256) samples. Later phases assert against these so
// the migration never silently drops or corrupts a legacy item, and so
// the completeness-verified legacy cache (Phase 3) knows the expected
// count to freeze against.
//
// Strictly READ-ONLY: it lists buckets and downloads a small,
// deterministic sample from each; it writes NOTHING to the cloud and
// never deletes anything. Safe on the real account.
//
// The baseline is emitted as a JSON blob between PHASE0_BASELINE_JSON
// markers in the test log — copy it into tool/e2e/baseline.json for the
// regression suite.
//
// PREREQUISITE: a device signed into FxFiles (see test_harness.dart).

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fula_files/core/services/fula_api_service.dart';

import '../helpers/test_harness.dart';

/// The legacy content buckets whose listings must survive the migration.
const List<String> kLegacyContentBuckets = <String>[
  'images',
  'videos',
  'audio',
  'documents',
  'dump',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 0 — baseline oracle capture (read-only)', () {
    late TestHarness harness;

    tearDown(() async {
      await harness.tearDown();
    });

    testWidgets('capture legacy bucket counts + sample hashes',
        (tester) async {
      harness = await TestHarness.bootSignedIn(tester);
      final api = FulaApiService.instance;

      final Map<String, dynamic> buckets = <String, dynamic>{};

      for (final b in kLegacyContentBuckets) {
        try {
          if (!await api.bucketExists(b)) {
            buckets[b] = <String, dynamic>{'exists': false};
            harness.logger.step('baseline $b: does not exist');
            continue;
          }

          final files = await api.listObjects(b);

          // Up to 3 deterministic samples: the smallest non-empty objects
          // (by size, then key) so the downloads stay fast and the choice
          // is stable across runs.
          final candidates = files.where((f) => f.size > 0).toList()
            ..sort((a, c) {
              final s = a.size.compareTo(c.size);
              return s != 0 ? s : a.key.compareTo(c.key);
            });
          final samples = <Map<String, dynamic>>[];
          for (final f in candidates.take(3)) {
            try {
              final bytes = await api.downloadObject(b, f.key);
              samples.add(<String, dynamic>{
                'key': f.key,
                'size': bytes.length,
                'sha256': sha256.convert(bytes).toString(),
              });
            } catch (e) {
              samples.add(<String, dynamic>{'key': f.key, 'error': '$e'});
            }
          }

          buckets[b] = <String, dynamic>{
            'exists': true,
            'count': files.length,
            'samples': samples,
          };
          harness.logger.step(
            'baseline $b: ${files.length} objects, ${samples.length} samples',
          );
        } catch (e) {
          // A gc-damaged bucket may list slowly or partially — record the
          // error rather than failing the whole capture.
          buckets[b] = <String, dynamic>{'error': '$e'};
          harness.logger.step('baseline $b: error $e');
        }
      }

      final baseline = <String, dynamic>{
        'capturedAtMs': DateTime.now().millisecondsSinceEpoch,
        'note': 'Phase 0 legacy baseline — counts are expected-minimums for '
            'the Phase 3 completeness gate; samples are key->sha256 oracles.',
        'buckets': buckets,
      };

      // Emit so it can be saved as the regression oracle.
      // ignore: avoid_print
      print('=== PHASE0_BASELINE_JSON_BEGIN ===');
      // ignore: avoid_print
      print(const JsonEncoder.withIndent('  ').convert(baseline));
      // ignore: avoid_print
      print('=== PHASE0_BASELINE_JSON_END ===');

      expect(
        buckets,
        isNotEmpty,
        reason: 'baseline must capture at least one bucket. '
            '${harness.diagnostics()}',
      );
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
