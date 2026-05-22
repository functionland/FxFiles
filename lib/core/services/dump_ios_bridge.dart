import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/core/services/dump_service.dart';

/// Pulls Share-Extension-staged content out of the iOS App Group
/// container and feeds it into the standard ingest pipeline. The
/// Share Extension itself can't link RustLib / `fula_client` (Dump
/// plan Phase 6: separate process, 120 MB memory cap), so it only
/// copies payloads + writes a `manifest.json` commit marker. The
/// main app (this class) does the actual encryption + upload after
/// resume or on a BGTask fire.
///
/// Idempotent — concurrent calls dedup at the call site via
/// `DumpService.ingestAndSchedule` (which goes through the same
/// `DumpStorageService` R8 dedup as Android share-target ingestion).
class DumpIosBridge {
  DumpIosBridge._();
  static final DumpIosBridge instance = DumpIosBridge._();

  static const MethodChannel _channel =
      MethodChannel('land.fx.files/dump_ios_bridge');

  /// Test seam — set to `true` to force the iOS code path under any
  /// host platform. Production code leaves this `null`.
  @visibleForTesting
  static bool? debugForceIos;

  static bool get _isIosEnabled => debugForceIos ?? Platform.isIOS;

  /// Drains every committed transaction (a `<txn>/manifest.json` is
  /// present in the App Group container) and feeds it into
  /// `DumpService.ingestAndSchedule`. Returns the total number of
  /// newly-ingested [DumpItem]s across all drained transactions.
  Future<int> drainAppGroupContainer() async {
    if (!_isIosEnabled) return 0;
    final List<dynamic>? raw;
    try {
      raw = await _channel.invokeMethod<List<dynamic>>(
        'drainAppGroupContainer',
      );
    } catch (e) {
      debugPrint('DumpIosBridge.drainAppGroupContainer channel error: $e');
      return 0;
    }
    if (raw == null || raw.isEmpty) return 0;

    var total = 0;
    for (final entry in raw) {
      try {
        final txn = (entry as Map).cast<String, Object?>();
        final paths = (txn['paths'] as List?)?.cast<String>() ??
            const <String>[];
        if (paths.isEmpty) continue;

        final mimeTypes = (txn['mimeTypes'] as List?)
                ?.map((e) => e is String ? e : null)
                .toList() ??
            List<String?>.filled(paths.length, null);

        final originalNames = (txn['originalNames'] as List?)
                ?.cast<String>() ??
            paths.map((p) => p.split(Platform.pathSeparator).last).toList();

        final textPayload = txn['textPayload'] as String?;
        final sourceApp = txn['sourceApp'] as String?;

        final created = await DumpService.instance.ingestAndSchedule(
          cachedPaths: paths,
          mimeTypes: mimeTypes,
          originalNames: originalNames,
          textPayload: textPayload,
          sourcePackage: sourceApp,
        );
        total += created.length;
      } catch (e) {
        debugPrint('DumpIosBridge: malformed descriptor entry skipped: $e');
      }
    }
    return total;
  }

  /// Test-only: the channel name (so the MethodChannel mock can hook
  /// the right name without `'land.fx.files/dump_ios_bridge'` magic
  /// string scattered around test code).
  @visibleForTesting
  static String get channelName => _channel.name;
}
