import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/web/services/web_website_generate_logic.dart';

/// Guards the client half of the "Recreate makes a whole new website" fix.
///
/// Recreate used to be a from-scratch generation whose only link to the
/// previous site was a sentence in the prompt text. The link is now
/// structural — `base_cid` names the build to edit — so the checks that
/// matter are that it is SENT when editing, ABSENT when building fresh,
/// and that the server's "nothing changed" answer is not mistaken for a
/// failure.
void main() {
  Map<String, dynamic> body({String? baseCid, String revisionRequest = ''}) =>
      buildGenerateRequestBody(
        prompt: 'Website Name: Aurora\nCategory: Corporation\n\nA studio.',
        assets: [
          {'fileName': 'hero.png', 'url': 'https://gw/ipfs/cid-a'}
        ],
        enableTracking: false,
        listed: false,
        listingName: 'aurora',
        listingGroup: 'tag-1',
        baseCid: baseCid,
        revisionRequest: revisionRequest,
      );

  group('buildGenerateRequestBody', () {
    test('a first-time build sends no revision fields at all', () {
      final b = body();
      expect(b.containsKey('base_cid'), isFalse);
      expect(b.containsKey('revision_request'), isFalse);
      // The rest of the contract is unchanged for a fresh generation.
      expect(b['pipeline_version'], 2);
      expect(b['listed'], false);
      expect(b['listing_group'], 'tag-1');
      expect(b['listing_name'], 'aurora');
    });

    test('an edit names the build it is editing', () {
      final b = body(baseCid: 'bafy-base', revisionRequest: 'bluer headline');
      expect(b['base_cid'], 'bafy-base');
      expect(b['revision_request'], 'bluer headline');
    });

    test('an EMPTY change request is still sent — it means "change nothing"',
        () {
      final b = body(baseCid: 'bafy-base');
      expect(b['base_cid'], 'bafy-base');
      expect(b.containsKey('revision_request'), isTrue);
      expect(b['revision_request'], '');
    });

    test('an empty base cid is treated as no base, not as an edit', () {
      final b = body(baseCid: '', revisionRequest: 'ignored');
      expect(b.containsKey('base_cid'), isFalse);
      expect(b.containsKey('revision_request'), isFalse);
    });

    test('listing consent is carried explicitly, never by omission', () {
      final b = buildGenerateRequestBody(
        prompt: 'p',
        assets: const [],
        enableTracking: true,
        listed: true,
        listingName: 'n',
        listingGroup: 'g',
      );
      expect(b['listed'], true);
      expect(b['enable_tracking'], true);
    });
  });

  group('classifyGenerateResponse', () {
    test('202 is a job to poll', () {
      expect(classifyGenerateResponse(202, {'jobId': 'x', 'mode': 'revision'}),
          GenerateOutcome.accepted);
    });

    test('200 "unchanged" is a real answer, not a failure', () {
      expect(
        classifyGenerateResponse(200, {
          'mode': 'unchanged',
          'resultCid': 'bafy-base',
        }),
        GenerateOutcome.unchanged,
      );
    });

    test('an unexpected 200 is a failure, not silently accepted', () {
      expect(classifyGenerateResponse(200, const {}), GenerateOutcome.failed);
    });

    test('409 means the base cannot be edited', () {
      expect(
        classifyGenerateResponse(409, {'code': 'BASE_SOURCE_UNAVAILABLE'}),
        GenerateOutcome.baseUnusable,
      );
      expect(
        classifyGenerateResponse(409, {'code': 'BASE_NOT_FOUND'}),
        GenerateOutcome.baseUnusable,
      );
    });

    test('other statuses fail', () {
      for (final code in [400, 401, 402, 429, 500, 503]) {
        expect(classifyGenerateResponse(code, const {}),
            GenerateOutcome.failed);
      }
    });
  });

  group('generateFailureMessage', () {
    test('a site that predates editing is explained, not blamed', () {
      final m = generateFailureMessage({'code': 'BASE_SOURCE_UNAVAILABLE'});
      expect(m, contains('before editing was supported'));
      expect(m, contains('Create Website'));
    });

    test('an unknown base falls back to a plain explanation', () {
      final m = generateFailureMessage({'code': 'BASE_NOT_FOUND'});
      expect(m, contains('could not be found'));
      expect(m, contains('Create Website'));
    });
  });
}
