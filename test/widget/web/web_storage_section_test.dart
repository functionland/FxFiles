import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/billing/storage_info.dart';
import 'package:fula_files/web/widgets/web_storage_section.dart';

/// Widget tests for the web Storage section (#6). The data
/// (BillingApiService) is network-bound and verified live; this is the VM-safe
/// presentational core — it renders a Cloud progress bar from a StorageInfo.
void main() {
  Future<void> pump(WidgetTester tester, StorageInfo info) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: WebStorageSection(info: info))),
    );
  }

  const halfFull = StorageInfo(
    currentStorageBytes: 524288000, // 500 MB
    freeTierBytes: 1073741824, // 1 GB
    paidStorageBytes: 1073741824, // 1 GB (total 2 GB)
    balanceFula: 0,
    usedCredits: 0,
    totalCredits: 0,
  );

  testWidgets('renders STORAGE header, Cloud Files label and used/total bytes',
      (tester) async {
    await pump(tester, halfFull);
    expect(find.text('STORAGE'), findsOneWidget);
    // The row was relabelled 'Cloud' -> 'Cloud Files' when the Cloud
    // Files manager shipped; this assertion was never updated.
    expect(find.text('Cloud Files'), findsOneWidget);
    expect(find.text('500.0 MB / 2.00 GB'), findsOneWidget);
    // No native "Phone"/device row on web.
    expect(find.text('Phone'), findsNothing);
  });

  testWidgets('progress bar reflects the usage fraction', (tester) async {
    await pump(tester, halfFull);
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(524288000 / 2147483648, 0.001)); // ~0.244
  });

  testWidgets('zero quota renders gracefully (0% bar, 0 B / 0 B)',
      (tester) async {
    const empty = StorageInfo(
      currentStorageBytes: 0,
      freeTierBytes: 0,
      paidStorageBytes: 0,
      balanceFula: 0,
      usedCredits: 0,
      totalCredits: 0,
    );
    await pump(tester, empty);
    expect(find.text('0 B / 0 B'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, 0.0);
  });

  testWidgets('over-quota usage clamps the bar to 1.0', (tester) async {
    const over = StorageInfo(
      currentStorageBytes: 3221225472, // 3 GB used
      freeTierBytes: 1073741824,
      paidStorageBytes: 1073741824, // 2 GB total
      balanceFula: 0,
      usedCredits: 0,
      totalCredits: 0,
    );
    await pump(tester, over);
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, 1.0);
  });
}
