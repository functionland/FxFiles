# FxFiles tests

Two tiers:

| Tier | Runs on | What it covers | Speed | Command |
|---|---|---|---|---|
| **Unit + widget** | Dart VM, no device | Service logic, Riverpod providers, widget rendering with mocked dependencies | <5s typical | `flutter test` |
| **Integration** | Connected device or desktop | Real platform plugins (MediaStore, PhotoKit, file viewers, SAF) | 30s–minutes | `flutter test integration_test/` |

## Tier 1 layout

```
test/
├── helpers/
│   ├── fake_fula_api.dart          # In-memory FulaApi for tests
│   ├── fixtures.dart                # Stock FulaObject / payloads
│   ├── test_container.dart          # Riverpod container + scope builders
│   └── helpers_sanity_test.dart     # Guards the helpers themselves
├── scenarios/
│   ├── upload_to_cloud_test.dart           # #3 — covered
│   ├── listing_test.dart                    # #4 — covered
│   ├── download_after_delete_test.dart      # #6 — covered
│   ├── cloud_storage_browse_test.dart       # #10 — covered
│   └── _deferred/                           # 10 skeleton files w/ TODOs
└── widget_test.dart                 # Smoke: app launches
```

## Tier 2 layout

```
integration_test/
├── app_smoke_test.dart                    # Boots the app on device
├── helpers/
│   ├── test_harness.dart                  # bootSignedIn() + tearDown()
│   ├── network_mutator.dart               # goOffline() / goOnline()
│   ├── test_bucket.dart                   # per-test key isolation
│   ├── test_fixture.dart                  # throwaway file generator
│   ├── wait_for.dart                      # wait-for-condition polling
│   └── failure_logger.dart                # diagnostic breadcrumbs
└── scenarios/
    ├── scenario_03_upload_test.dart       # baseline upload + listing
    ├── scenario_04_online_offline_list_test.dart  # **load-bearing for issue #8**
    ├── scenario_06_download_offline_test.dart      # warm offline download
    └── scenario_10_bucket_browse_test.dart         # bucket listing online/offline
```

### Tier 2 prerequisite — manual sign-in

The integration tests assume FxFiles is **already signed in** on the
target device. `TestHarness.bootSignedIn` reads the persisted session
and waits for `FulaApiService.isConfigured` to flip — it does NOT
drive the OAuth flow. If you've never signed in (or `pm clear`'d the
app), every test fails immediately with a clear message.

```sh
# 1. Sign in to FxFiles on the moto g85 5G manually (one time).
# 2. Make sure the device is connected (`flutter devices`).
# 3. Run:
flutter test integration_test/

# First run ~2 min (Gradle assembleDebug + APK install).
# Subsequent runs ~10-30s per test.
```

### What the network mutator does

`harness.network.goOffline()` calls
`FulaApiService.testOnlyReinitializeWithEndpoint('https://s33.cloud.fx.land')`.
That non-resolvable hostname is the same trick from issue #8
reproducing — DNS-fails fast → `is_master_unreachable_error` →
the SDK takes the offline-fallback path.

`harness.network.goOnline()` restores the original endpoint
snapshotted at `bootSignedIn` time. Always called in `tearDown` so
the next test starts from a clean online state.

### Test bucket isolation

All tests share `__integration_test__` on your real master, with
per-test key prefixes like `test/<timestamp>/<name>`. `tearDown`
deletes the keys the test created but **does not** delete the
bucket — too expensive, and the shared bucket also exercises the
walkable-v8 read-after-write upgrade path naturally.

### Note on issue #8 (the load-bearing scenario)

`scenario_04_online_offline_list_test.dart` is designed to **fail
on `fula_client: 0.5.1`** (the version currently pinned in
`pubspec.yaml`) and **pass on >= 0.6** (which has the fix #3
warm-on-write). The test's failure message explicitly calls out
which version range is buggy so a future maintainer reading a
failed CI log immediately knows whether to bump fula-client or
investigate a regression.

## Coverage status

✅ **Covered (Tier 1):** 32 tests across the helper sanity suite + the
four chosen scenarios.

⏳ **Skeleton (TODO):** 10 deferred scenarios in `test/scenarios/_deferred/`.
Each file documents why it's deferred and what to implement.

## How to mock the FulaApi surface

Production code uses `FulaApiService.instance` (a static singleton).
For tests, the abstract interface `FulaApi` in
`lib/core/services/fula_api.dart` is implemented by:
- `FulaApiService` (production, in `fula_api_service.dart`)
- `FakeFulaApi` (test helper, in `test/helpers/fake_fula_api.dart`)

The Riverpod provider `fulaApiProvider` (in
`lib/core/providers/fula_api_provider.dart`) returns the production
singleton by default. Tests override it.

### Unit test pattern

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/providers/fula_api_provider.dart';

import '../helpers/fake_fula_api.dart';
import '../helpers/test_container.dart';

void main() {
  test('listBuckets returns the canned list', () async {
    final fake = FakeFulaApi();
    fake.bucketsResponse = const ['images', 'videos'];
    final container = makeTestContainer(fulaApi: fake);

    final api = container.read(fulaApiProvider);
    expect(await api.listBuckets(), ['images', 'videos']);
  });
}
```

`makeTestContainer` calls `addTearDown(container.dispose)` so
Riverpod's leak detector stays quiet.

### Widget test pattern

```dart
testWidgets('cloud storage badge renders bucket count', (tester) async {
  final fake = FakeFulaApi();
  fake.bucketsResponse = const ['images'];

  await tester.pumpWidget(withTestProviderScope(
    fulaApi: fake,
    child: const MaterialApp(home: MyCloudBadgeWidget()),
  ));
  await tester.pumpAndSettle();

  expect(find.text('1 bucket'), findsOneWidget);
});
```

### Inducing failures

Each fake method has a paired error knob:

```dart
fake.listBucketsError = FulaApiException('master 503');
fake.downloadErrorFor['images:foo.jpg'] = FulaApiException('gateway race exhausted');
fake.uploadObjectError = FulaApiException('disk full');
fake.listBucketsCachedThrowsOnLive = true;
fake.bucketsCachedFallback = (
  buckets: const ['cached1'],
  stale: true,
  fetchedAt: DateTime.now(),
);
```

## Why this pattern (and what was rejected)

| Approach | Verdict | Why |
|---|---|---|
| **Riverpod-wrap each singleton in an abstract interface (chosen)** | ✅ | Tests don't reach into `fula_client` FRB internals. Production code keeps reading `FulaApiService.instance` for now; per-screen migration to `ref.watch(fulaApiProvider)` is incremental. |
| `static FakeFulaApi? testOverride;` on each singleton | ❌ | Leaks test-only API surface into production class definitions. Brittle. |
| Mock `fula_client` package directly | ❌ | The package surface is top-level functions like `fula.encListBuckets(client: ...)`. Dart can't mock top-level functions. |

## Constraints + gotchas

- **`Override` isn't exported in Riverpod 3.** `test_container.dart`
  works around this by offering one override (the `FulaApi`) and
  recommending that tests needing more construct `ProviderContainer`
  directly with both overrides inline.
- **`flutter test test/widget_test.dart` takes ~2.5 min on a clean
  run** because the Rust shared library has to load. Subsequent
  runs are seconds. **Scenario tests in `test/scenarios/`** don't
  pump `FulaFilesApp` so they don't pay this cost — they run in
  <5s total.
- **Digit-separator syntax (`1_000_000`) is not enabled.** Use plain
  literals (`1000000`).
- **Singleton state can leak between tests.** Tests that touch
  `FulaApiService.instance` directly (rather than the provider) can
  affect other tests. Prefer the provider via `makeTestContainer` /
  `withTestProviderScope`.

## Migration plan (for follow-up PRs)

To grow Tier-1 coverage past the current 4 scenarios:

1. **Add additional Riverpod providers** following the
   `fula_api_provider` pattern for `AuthService`, `SyncService`,
   `LocalStorageService`, `TagStorageService`, `MediaService`,
   `SharingService`. Each provider exposes the production singleton
   by default; tests override.
2. **Per scenario, refactor only the screens / services involved**
   to read from providers. Big-bang refactors are not required —
   incremental rollout works fine because the providers return the
   real singletons by default.
3. **Build `test/helpers/hive_test.dart`** when you need to cover
   scenarios that depend on `LocalStorageService` (e.g. tags +
   faces restore — scenario #8). Use `Hive.initFlutter(tempDir)`
   in `setUp` and close all boxes in `tearDown`.

## Running the suite

```sh
# Tier 1 (unit + widget) — fast, no device
flutter test

# Just the scenarios
flutter test test/scenarios/ test/helpers/

# Tier 2 (integration) — needs a connected device or desktop
flutter test integration_test/
```

## When something is integration-only

If unit/widget coverage genuinely can't reach a scenario (camera
permissions, file picker dialogs, OS file viewers, real cross-device
sharing), don't force it — leave the unit test as a skeleton with a
clear TODO and write the test in `integration_test/scenarios/`
instead. The skeleton makes the gap visible to reviewers.
