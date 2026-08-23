// Pure mapping from a website generation's real progress to a step
// checklist. Kept free of Flutter widgets so it can be unit-tested
// directly — same precedent as `web_website_jobs_logic.dart`.
//
// WHY THIS EXISTS
// ---------------
// The card used to show one opaque line of `statusMessage`, so a user
// could not tell a slow generation from a hung one. The steps below are
// derived ONLY from state the client genuinely knows:
//
//   * `WebsiteGenStatus` — the client's own pipeline phase (upload →
//     parse → generate), set at the phase boundaries in
//     `web_website_service.dart`.
//   * the SERVER's phase, which `GET /api/v1/status/:jobId` has always
//     returned in `status` and the client used to discard (it only
//     checked for 'completed'/'error'). The values are the AI service's
//     own `ai_generations.status` CHECK constraint:
//     ('pending','generating','publishing','completed','error').
//
// Nothing here advances on a timer or a guess. The 3-pass AI pipeline
// (design brief → build → polish) runs entirely server-side and exposes
// no pass boundaries, so it is surfaced honestly as the server's own
// free-text `statusMessage` on the active step rather than being faked
// into steps the client cannot observe.

import 'package:fula_files/core/models/website_generation.dart';

/// Server phase values from `GET /api/v1/status/:jobId`.
const String kServerPhasePending = 'pending';
const String kServerPhaseGenerating = 'generating';
const String kServerPhasePublishing = 'publishing';

enum WebsiteStepState { pending, active, done, failed }

class WebsiteStep {
  final String title;
  final WebsiteStepState state;

  /// Shown under the title. Only ever populated for the current step.
  final String? subtitle;

  const WebsiteStep({
    required this.title,
    required this.state,
    this.subtitle,
  });

  @override
  String toString() => '$title:${state.name}';
}

const List<String> kWebsiteStepTitles = <String>[
  'Upload assets',
  'Analyze content',
  'Generate site',
  'Publish to IPFS',
  'Live',
];

/// Monotonic rank of a server phase. Unknown strings return null so the
/// caller can KEEP the phase it already had.
int? serverPhaseRank(String? phase) => switch (phase) {
      kServerPhasePending => 0,
      kServerPhaseGenerating => 1,
      kServerPhasePublishing => 2,
      _ => null,
    };

/// Fold a freshly-polled server phase into the one already held.
///
/// The checklist must never walk backwards: a server that reports
/// `publishing` and then, on a later poll, something older or
/// unrecognised must not un-tick a step the user already saw complete.
/// Unknown values are ignored rather than treated as a reset.
String? advanceServerPhase(String? previous, String? incoming) {
  final incomingRank = serverPhaseRank(incoming);
  if (incomingRank == null) return previous;
  final previousRank = serverPhaseRank(previous);
  if (previousRank == null) return incoming;
  return incomingRank >= previousRank ? incoming : previous;
}

/// Index of the step currently in flight.
int _indexFor(WebsiteGenStatus status, String? serverPhase) {
  switch (status) {
    case WebsiteGenStatus.uploading:
      return 0;
    case WebsiteGenStatus.parsing:
      return 1;
    case WebsiteGenStatus.generating:
      // Only an explicit 'publishing' advances past Generate; anything
      // unrecognised leaves Generate active.
      return serverPhase == kServerPhasePublishing ? 3 : 2;
    case WebsiteGenStatus.completed:
      return kWebsiteStepTitles.length - 1;
    case WebsiteGenStatus.error:
      // Caller supplies `lastActiveStatus`; this is only the fallback.
      return 2;
  }
}

/// Build the checklist.
///
/// [lastActiveStatus] is the last non-error client phase. `status` is
/// overwritten with `error` when a generation fails, which would
/// otherwise lose which step actually broke.
List<WebsiteStep> buildWebsiteGenerationSteps({
  required WebsiteGenStatus status,
  String? serverPhase,
  WebsiteGenStatus? lastActiveStatus,
  String? statusMessage,
  String? errorMessage,
  int uploadedAssets = 0,
  int totalAssets = 0,
}) {
  final failed = status == WebsiteGenStatus.error;
  final completed = status == WebsiteGenStatus.completed;
  final current = failed
      ? _indexFor(lastActiveStatus ?? WebsiteGenStatus.generating, serverPhase)
      : _indexFor(status, serverPhase);

  final steps = <WebsiteStep>[];
  for (var i = 0; i < kWebsiteStepTitles.length; i++) {
    final WebsiteStepState state;
    if (completed) {
      state = WebsiteStepState.done;
    } else if (i < current) {
      state = WebsiteStepState.done;
    } else if (i == current) {
      state = failed ? WebsiteStepState.failed : WebsiteStepState.active;
    } else {
      state = WebsiteStepState.pending;
    }

    String? subtitle;
    if (i == current && !completed) {
      if (failed) {
        subtitle = (errorMessage != null && errorMessage.isNotEmpty)
            ? errorMessage
            : statusMessage;
      } else {
        subtitle = (statusMessage != null && statusMessage.isNotEmpty)
            ? statusMessage
            : (i == 0 && totalAssets > 0
                ? '$uploadedAssets/$totalAssets assets uploaded'
                : null);
      }
    }

    steps.add(WebsiteStep(
      title: kWebsiteStepTitles[i],
      state: state,
      subtitle: subtitle,
    ));
  }
  return steps;
}
