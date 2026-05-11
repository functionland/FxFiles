// SKELETON — Scenario #9: Categories show "uploaded" icon next to
// already-uploaded files.
//
// **Why this is testable but not yet done:**
// This is pure widget-test territory — given a file-tile widget +
// a state flag "this file is uploaded", does it render the cloud
// indicator? Easy to cover; just not in the first-cycle scope.
//
// **TODO:**
// - Identify the file-tile widget (likely in
//   `lib/features/browser/widgets/` or similar).
// - Stub the upload-status data source via a Riverpod provider
//   override.
// - Pump the tile in `withTestProviderScope` and `expect(find.byIcon
//   (Icons.cloud_done), findsOneWidget)`.

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Scenario #9 — Uploaded icon indicator (SKELETON)', () {
    test('TODO: widget — tile renders cloud-done when uploaded=true',
        () => null,
        skip: 'TODO: see file header for implementation plan');
    test('TODO: widget — tile hides cloud icon when uploaded=false',
        () => null,
        skip: 'TODO: see file header for implementation plan');
  });
}
