import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/web/services/web_generation_steps.dart';

/// Compact view of the checklist for assertions: one letter per step.
String _shape(List<WebsiteStep> steps) => steps
    .map((s) => switch (s.state) {
          WebsiteStepState.done => 'D',
          WebsiteStepState.active => 'A',
          WebsiteStepState.pending => '.',
          WebsiteStepState.failed => 'X',
        })
    .join();

void main() {
  group('buildWebsiteGenerationSteps', () {
    test('uploading marks only the first step active', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.uploading,
      );
      expect(_shape(steps), 'A....');
      expect(steps.length, kWebsiteStepTitles.length);
    });

    test('parsing completes upload and activates analyze', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.parsing,
      );
      expect(_shape(steps), 'DA...');
    });

    test('generating with no server phase yet activates Generate', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.generating,
      );
      expect(_shape(steps), 'DDA..');
    });

    test('server phase "pending" still means Generate is the live step', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.generating,
        serverPhase: kServerPhasePending,
      );
      expect(_shape(steps), 'DDA..');
    });

    test('server phase "publishing" advances to the Publish step', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.generating,
        serverPhase: kServerPhasePublishing,
      );
      expect(_shape(steps), 'DDDA.');
    });

    test('an UNRECOGNISED server phase leaves the current step active', () {
      // A server that grows a new phase name must never blank the
      // checklist or bounce the user back to an earlier step.
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.generating,
        serverPhase: 'refining-something-new',
      );
      expect(_shape(steps), 'DDA..');
    });

    test('completed marks every step done', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.completed,
        serverPhase: kServerPhasePublishing,
      );
      expect(_shape(steps), 'DDDDD');
    });

    test('error fails the step that was actually running', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.error,
        lastActiveStatus: WebsiteGenStatus.parsing,
      );
      expect(_shape(steps), 'DX...');
    });

    test('error during publish fails the publish step', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.error,
        lastActiveStatus: WebsiteGenStatus.generating,
        serverPhase: kServerPhasePublishing,
      );
      expect(_shape(steps), 'DDDX.');
    });

    test('error with no recorded phase falls back to Generate', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.error,
      );
      expect(_shape(steps), 'DDX..');
    });

    test('statusMessage lands on the active step only', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.generating,
        statusMessage: 'Polishing layout',
      );
      expect(steps[2].subtitle, 'Polishing layout');
      expect(steps[0].subtitle, isNull);
      expect(steps[1].subtitle, isNull);
      expect(steps[3].subtitle, isNull);
    });

    test('upload step falls back to asset counts when no message', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.uploading,
        uploadedAssets: 2,
        totalAssets: 5,
      );
      expect(steps[0].subtitle, '2/5 assets uploaded');
    });

    test('a real statusMessage wins over the asset-count fallback', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.uploading,
        statusMessage: 'Uploading asset 2/5',
        uploadedAssets: 2,
        totalAssets: 5,
      );
      expect(steps[0].subtitle, 'Uploading asset 2/5');
    });

    test('failed step shows what it was doing, not a blank', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.error,
        lastActiveStatus: WebsiteGenStatus.generating,
        statusMessage: 'Building pages',
      );
      expect(steps[2].state, WebsiteStepState.failed);
      expect(steps[2].subtitle, 'Building pages');
    });

    test('errorMessage takes the subtitle when supplied', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.error,
        lastActiveStatus: WebsiteGenStatus.generating,
        statusMessage: 'Building pages',
        errorMessage: 'Insufficient credits',
      );
      expect(steps[2].subtitle, 'Insufficient credits');
    });
  });

  group('advanceServerPhase', () {
    test('adopts the first recognised phase', () {
      expect(advanceServerPhase(null, kServerPhaseGenerating),
          kServerPhaseGenerating);
    });

    test('moves forward', () {
      expect(
        advanceServerPhase(kServerPhaseGenerating, kServerPhasePublishing),
        kServerPhasePublishing,
      );
    });

    test('NEVER walks backwards', () {
      // The user must not watch "Publish" un-tick because a later poll
      // reported an older phase.
      expect(
        advanceServerPhase(kServerPhasePublishing, kServerPhaseGenerating),
        kServerPhasePublishing,
      );
      expect(
        advanceServerPhase(kServerPhasePublishing, kServerPhasePending),
        kServerPhasePublishing,
      );
    });

    test('ignores unknown values instead of resetting', () {
      expect(
        advanceServerPhase(kServerPhasePublishing, 'something-new'),
        kServerPhasePublishing,
      );
      expect(advanceServerPhase(null, 'something-new'), isNull);
      expect(advanceServerPhase(null, null), isNull);
    });

    test('terminal server statuses do not become phases', () {
      // 'completed'/'error' are handled by the poll loop itself; they are
      // not ranked phases and must not clobber a real one.
      expect(
        advanceServerPhase(kServerPhaseGenerating, 'completed'),
        kServerPhaseGenerating,
      );
    });
  });

  group('generation passes (sub-steps)', () {
    // These strings come from ai/src/services/claudeService.ts, which
    // reports each pass through the job's statusMessage.
    test('maps the three real server pass markers', () {
      expect(subStepFromStatusMessage('Designing art direction...'),
          WebsiteSubStep.design);
      expect(subStepFromStatusMessage('Building your website...'),
          WebsiteSubStep.build);
      expect(subStepFromStatusMessage('Polishing design and motion...'),
          WebsiteSubStep.polish);
    });

    test('"Polishing design and motion" is POLISH, not design', () {
      // It contains the word "design", so a naive contains-check reports
      // the wrong pass for the last one.
      expect(subStepFromStatusMessage('Polishing design and motion...'),
          isNot(WebsiteSubStep.design));
    });

    test('the legacy single-pass message names no pass', () {
      expect(subStepFromStatusMessage('Generating website...'), isNull);
      expect(subStepFromStatusMessage('Queued for generation'), isNull);
      expect(subStepFromStatusMessage(null), isNull);
    });

    test('advanceSubStep never walks backwards', () {
      expect(advanceSubStep(null, 'Designing art direction...'),
          WebsiteSubStep.design);
      expect(
          advanceSubStep(WebsiteSubStep.build, 'Polishing design and motion...'),
          WebsiteSubStep.polish);
      // A late/stale poll must not un-tick a pass already seen.
      expect(advanceSubStep(WebsiteSubStep.polish, 'Building your website...'),
          WebsiteSubStep.polish);
      // An unrecognised line leaves the pass alone rather than clearing it.
      expect(advanceSubStep(WebsiteSubStep.build, 'Almost there'),
          WebsiteSubStep.build);
    });

    test('passes hang off Generate site, and only once one is known', () {
      final none = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.generating,
      );
      expect(none[2].subSteps, isEmpty);

      final building = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.generating,
        subStep: WebsiteSubStep.build,
      );
      expect(building[2].subSteps.map((s) => s.title).toList(),
          ['Design', 'Build', 'Polish']);
      expect(building[2].subSteps[0].state, WebsiteStepState.done);
      expect(building[2].subSteps[1].state, WebsiteStepState.active);
      expect(building[2].subSteps[2].state, WebsiteStepState.pending);
      // No other step grows sub-steps.
      expect(building.where((s) => s.subSteps.isNotEmpty).length, 1);
    });

    test('a failure inside generation fails the pass it was on', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.error,
        lastActiveStatus: WebsiteGenStatus.generating,
        subStep: WebsiteSubStep.polish,
      );
      expect(steps[2].state, WebsiteStepState.failed);
      expect(steps[2].subSteps[2].state, WebsiteStepState.failed);
      expect(steps[2].subSteps[0].state, WebsiteStepState.done);
    });

    test('a completed generation collapses the passes away', () {
      final steps = buildWebsiteGenerationSteps(
        status: WebsiteGenStatus.completed,
        subStep: WebsiteSubStep.polish,
      );
      expect(steps[2].subSteps, isEmpty);
    });
  });

  group('serverPhaseRank', () {
    test('ranks the three known phases in pipeline order', () {
      expect(serverPhaseRank(kServerPhasePending), 0);
      expect(serverPhaseRank(kServerPhaseGenerating), 1);
      expect(serverPhaseRank(kServerPhasePublishing), 2);
    });

    test('returns null for anything else', () {
      expect(serverPhaseRank('completed'), isNull);
      expect(serverPhaseRank(null), isNull);
      expect(serverPhaseRank(''), isNull);
    });
  });
}
