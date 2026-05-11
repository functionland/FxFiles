// Riverpod provider exposing the FulaApi surface.
//
// Production: returns the existing singleton `FulaApiService.instance`,
// preserving current behavior — no caller refactor required for the
// initial test infrastructure roll-out.
//
// Tests: override via `ProviderScope.overrides` (widget tests) or
// `ProviderContainer.test(...)` (unit tests) — see
// `test/helpers/test_container.dart` for the recommended factory.
//
// Migration plan: as scenarios get covered, the screens / services
// involved should be refactored to read `ref.watch(fulaApiProvider)`
// instead of `FulaApiService.instance` directly. Until that refactor
// is complete the provider acts as the "test-only" injection point;
// production reads via .instance keep working.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fula_files/core/services/fula_api.dart';
import 'package:fula_files/core/services/fula_api_service.dart';

/// The cloud client used by FxFiles. Override in tests.
///
/// Default implementation: `FulaApiService.instance`. Override with a
/// `FakeFulaApi` (test/helpers/fake_fula_api.dart) to control
/// listBuckets / listObjects / upload / download / etc. responses.
final fulaApiProvider = Provider<FulaApi>((ref) {
  return FulaApiService.instance;
});
