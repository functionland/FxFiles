// Programmatic endpoint mutation for online ↔ offline test phases.
//
// Wraps `FulaApiService.testOnlyReinitializeWithEndpoint` with named
// helpers + state tracking so tests don't have to remember which
// endpoint was the original.
//
// **Limitations:**
// - The mutator can flip the endpoint, but the device's actual
//   network state stays online. Tests rely on the SDK seeing
//   master-unreachable when the endpoint DNS-fails (the same
//   pattern as the user's manual `s3 → s33` test).
// - The mutator does NOT clear the BLOCKS cache. For cold-start
//   scenarios, a separate helper would be needed.
// - Endpoint config in SecureStorage is NOT updated — so a `signOut`
//   + `signIn` round-trip during a test would revert to the
//   user's original endpoint. Don't do that mid-test.

import 'package:fula_files/core/services/fula_api_service.dart';

import 'failure_logger.dart';

/// A non-resolvable hostname designed to make the master DNS-fail
/// fast. Same pattern as the user's manual `s33.cloud.fx.land`
/// trick — exact DNS failure mode is acceptable here because the
/// fula-client offline-fallback path treats DNS errors as
/// "master unreachable" (see issue #8 analysis).
const String _bogusOfflineEndpoint = 'https://s33.cloud.fx.land';

class NetworkMutator {
  String? _originalEndpoint;
  final _logger = FailureLogger();

  /// Capture the currently-configured endpoint so [goOnline] can
  /// restore it. Call once before any [goOffline].
  void snapshotCurrent({required String currentEndpoint}) {
    _originalEndpoint = currentEndpoint;
    _logger.step('snapshotted online endpoint: $currentEndpoint');
  }

  /// Reinitialize FulaApiService with a non-resolvable URL so the
  /// next master request fails with a DNS error → master-unreachable.
  ///
  /// **Effect:** The SDK's health gate sees the failure, marks
  /// master as Down for its TTL, and the warm-cache / cid-hint
  /// offline path takes over.
  Future<void> goOffline() async {
    _logger.step('flipping to offline endpoint: $_bogusOfflineEndpoint');
    await FulaApiService.instance
        .testOnlyReinitializeWithEndpoint(_bogusOfflineEndpoint);
    _logger.step('FulaApiService re-initialized with bogus URL');
  }

  /// Restore the snapshot from [snapshotCurrent]. Call in `tearDown`
  /// even when the test failed, so subsequent tests start from a
  /// clean online state.
  Future<void> goOnline() async {
    final original = _originalEndpoint;
    if (original == null) {
      _logger.step(
        'goOnline: no snapshot to restore — original endpoint never captured',
      );
      return;
    }
    _logger.step('restoring online endpoint: $original');
    await FulaApiService.instance.testOnlyReinitializeWithEndpoint(original);
    _logger.step('FulaApiService restored to online');
  }
}
