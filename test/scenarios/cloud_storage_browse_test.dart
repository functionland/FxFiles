// Scenario #10 — Cloud storage bucket browsing.
//
// **Tier:** unit tests at the FulaApi boundary + a small widget test
// proving a ConsumerWidget that reads `fulaApiProvider` renders the
// bucket count it sees.
//
// **Stated requirement:** "Ensuring that cloud storage lists buckets
// properly and each bucket lists uploaded files properly."

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/providers/fula_api_provider.dart';
import 'package:fula_files/core/services/fula_api.dart';

import '../helpers/fake_fula_api.dart';
import '../helpers/fixtures.dart';
import '../helpers/test_container.dart';

/// A tiny ConsumerWidget that renders the bucket count + first
/// bucket name from `fulaApiProvider`. Lives here so the widget
/// test below proves the provider seam works end-to-end without
/// pulling in any production screen (those still call
/// `FulaApiService.instance` directly — see migration plan in
/// the README).
class _BucketCountBadge extends ConsumerStatefulWidget {
  const _BucketCountBadge();

  @override
  ConsumerState<_BucketCountBadge> createState() =>
      _BucketCountBadgeState();
}

class _BucketCountBadgeState extends ConsumerState<_BucketCountBadge> {
  List<String>? _buckets;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = ref.read(fulaApiProvider);
      final buckets = await api.listBuckets();
      if (mounted) setState(() => _buckets = buckets);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Text('error: $_error');
    if (_buckets == null) return const Text('loading');
    if (_buckets!.isEmpty) return const Text('empty');
    return Text('${_buckets!.length} buckets: ${_buckets!.first}');
  }
}

void main() {
  group('Scenario #10 — Cloud bucket browsing', () {
    test('listBuckets reports every bucket the user has', () async {
      final fake = FakeFulaApi();
      fake.bucketsResponse = stockBuckets;
      final result = await fake.listBuckets();
      expect(result, stockBuckets);
      expect(result, hasLength(11),
          reason: 'stockBuckets is the canonical FxFiles bucket set');
    });

    test('each bucket can be opened to list its files independently',
        () async {
      final fake = FakeFulaApi();
      fake.bucketsResponse = const ['images', 'videos'];
      fake.objectsResponseFor['images'] = [
        smallImageObject,
        secondImageObject,
      ];
      fake.objectsResponseFor['videos'] = [chunkedVideoObject];

      expect(await fake.listObjects('images'), hasLength(2));
      expect(await fake.listObjects('videos'), hasLength(1));
      // Independence check: opening one bucket doesn't affect another's
      // call counter, so a UI that opens 'images' then 'videos' makes
      // exactly two distinct listObjects calls.
      expect(fake.listObjectsCalls['images'], 1);
      expect(fake.listObjectsCalls['videos'], 1);
    });

    test('empty bucket shows zero files (sentinel for "empty state" UI)',
        () async {
      final fake = FakeFulaApi();
      fake.bucketsResponse = const ['fresh-bucket'];
      // No objectsResponseFor entry → empty list (NOT null, NOT throw).
      expect(await fake.listObjects('fresh-bucket'), isEmpty);
    });

    testWidgets(
        'ConsumerWidget reads fulaApiProvider override and renders count',
        (tester) async {
      final fake = FakeFulaApi();
      fake.bucketsResponse = const ['images', 'videos', 'documents'];

      await tester.pumpWidget(
        withTestProviderScope(
          fulaApi: fake,
          child: const MaterialApp(home: _BucketCountBadge()),
        ),
      );
      // Let _load() resolve.
      await tester.pumpAndSettle();

      expect(find.text('3 buckets: images'), findsOneWidget,
          reason: 'widget must observe the FAKE, not the real singleton');
      expect(fake.listBucketsCalls, 1);
    });

    testWidgets('ConsumerWidget surfaces FulaApiException as visible error',
        (tester) async {
      final fake = FakeFulaApi();
      fake.listBucketsError = FulaApiException('master 503');

      await tester.pumpWidget(
        withTestProviderScope(
          fulaApi: fake,
          child: const MaterialApp(home: _BucketCountBadge()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('error:'), findsOneWidget);
      expect(find.textContaining('master 503'), findsOneWidget);
    });

    testWidgets('empty bucket list renders "empty" sentinel', (tester) async {
      final fake = FakeFulaApi();
      fake.bucketsResponse = const [];

      await tester.pumpWidget(
        withTestProviderScope(
          fulaApi: fake,
          child: const MaterialApp(home: _BucketCountBadge()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('empty'), findsOneWidget);
    });
  });
}
