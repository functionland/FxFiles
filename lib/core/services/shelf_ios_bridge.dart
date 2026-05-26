import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_service.dart';

/// Pulls Share-Extension-staged content out of the iOS App Group
/// container and feeds it into the standard ingest pipeline. The
/// Share Extension itself can't link RustLib / `fula_client` (Shelf
/// plan Phase 6: separate process, 120 MB memory cap), so it only
/// copies payloads + writes a `manifest.json` commit marker. The
/// main app (this class) does the actual encryption + upload after
/// resume or on a BGTask fire.
///
/// Idempotent — concurrent calls dedup at the call site via
/// `ShelfService.ingestAndSchedule` (which goes through the same
/// `ShelfStorageService` R8 dedup as Android share-target ingestion).
class ShelfIosBridge {
  ShelfIosBridge._();
  static final ShelfIosBridge instance = ShelfIosBridge._();

  static const MethodChannel _channel =
      MethodChannel('land.fx.files/dump_ios_bridge');

  /// Test seam — set to `true` to force the iOS code path under any
  /// host platform. Production code leaves this `null`.
  @visibleForTesting
  static bool? debugForceIos;

  static bool get _isIosEnabled => debugForceIos ?? Platform.isIOS;

  /// Drains every committed transaction (a `<txn>/manifest.json` is
  /// present in the App Group container) and feeds it into
  /// `ShelfService.ingestAndSchedule`. After successful in-memory
  /// ingestion, asks the native side to delete the sidecar JSONs it
  /// wrote into `Documents/dump_pending/` — without that ack the
  /// sidecar would be re-ingested by `ShelfService.drainPendingDir`
  /// on the next resume (idempotent thanks to R8 dedup, but wasteful).
  /// If the ack call fails the sidecar stays as a recovery net.
  /// Returns the total number of newly-ingested [ShelfItem]s.
  Future<int> drainAppGroupContainer() async {
    if (!_isIosEnabled) return 0;
    final List<dynamic>? raw;
    try {
      raw = await _channel.invokeMethod<List<dynamic>>(
        'drainAppGroupContainer',
      );
    } catch (e) {
      debugPrint('ShelfIosBridge.drainAppGroupContainer channel error: $e');
      return 0;
    }
    if (raw == null || raw.isEmpty) return 0;

    var total = 0;
    final ackTxnIds = <String>[];
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
        // Accept either the new canonical `sourcePackage` field or
        // the legacy `sourceApp` field (older extension builds may
        // still write the latter for one release transition).
        final sourcePackage = (txn['sourcePackage'] as String?) ??
            (txn['sourceApp'] as String?);
        final txnId = txn['txnId'] as String?;

        final created = await ShelfService.instance.ingestAndSchedule(
          cachedPaths: paths,
          mimeTypes: mimeTypes,
          originalNames: originalNames,
          textPayload: textPayload,
          sourcePackage: sourcePackage,
        );
        total += created.length;
        if (txnId != null) ackTxnIds.add(txnId);
      } catch (e) {
        debugPrint('ShelfIosBridge: malformed descriptor entry skipped: $e');
      }
    }

    if (ackTxnIds.isNotEmpty) {
      try {
        await _channel.invokeMethod<bool>(
          'ackTxns',
          <String, dynamic>{'txnIds': ackTxnIds},
        );
      } catch (e) {
        // Best-effort — failures leave sidecars on disk for
        // drainPendingDir to re-pick-up later. Idempotent via R8.
        debugPrint('ShelfIosBridge: ackTxns failed (sidecars retained): $e');
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
