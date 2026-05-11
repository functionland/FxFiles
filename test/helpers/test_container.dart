// Riverpod ProviderContainer factory for tests.
//
// Riverpod 3 doesn't export the `Override` type publicly, so this
// helper offers ONE override (fulaApiProvider). When a test needs
// additional providers replaced, build the `ProviderContainer` /
// `ProviderScope` directly with both overrides in the same list.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/providers/fula_api_provider.dart';
import 'package:fula_files/core/services/fula_api.dart';

/// Build a `ProviderContainer` with [fulaApi] overriding the default
/// `fulaApiProvider`. Always disposed via `addTearDown` so Riverpod
/// doesn't emit leak warnings.
ProviderContainer makeTestContainer({required FulaApi fulaApi}) {
  final container = ProviderContainer(
    overrides: [fulaApiProvider.overrideWithValue(fulaApi)],
  );
  addTearDown(container.dispose);
  return container;
}

/// Wrap [child] in a `ProviderScope` with [fulaApi] override.
/// Convenience for `tester.pumpWidget` in widget tests.
Widget withTestProviderScope({
  required FulaApi fulaApi,
  required Widget child,
}) {
  return ProviderScope(
    overrides: [fulaApiProvider.overrideWithValue(fulaApi)],
    child: child,
  );
}
