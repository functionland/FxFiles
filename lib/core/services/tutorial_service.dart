import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:showcaseview/showcaseview.dart';

/// Service to manage interactive tutorial state and keys
class TutorialService {
  TutorialService._();
  static final TutorialService instance = TutorialService._();

  static const String _tutorialCompletedKey = 'tutorial_completed';
  static const String _tutorialEnabledKey = 'tutorial_enabled';

  SharedPreferences? _prefs;

  // GlobalKeys for all tutorial target widgets
  final GlobalKey setupBannerKey = GlobalKey(debugLabel: 'tutorial_setup');
  final GlobalKey recentFilesKey = GlobalKey(debugLabel: 'tutorial_recent');
  final GlobalKey categoriesKey = GlobalKey(debugLabel: 'tutorial_categories');
  final GlobalKey starredKey = GlobalKey(debugLabel: 'tutorial_starred');
  final GlobalKey cloudKey = GlobalKey(debugLabel: 'tutorial_cloud');
  final GlobalKey sharedKey = GlobalKey(debugLabel: 'tutorial_shared');
  final GlobalKey playlistsKey = GlobalKey(debugLabel: 'tutorial_playlists');
  final GlobalKey storageKey = GlobalKey(debugLabel: 'tutorial_storage');
  final GlobalKey trashKey = GlobalKey(debugLabel: 'tutorial_trash');
  final GlobalKey settingsKey = GlobalKey(debugLabel: 'tutorial_settings');
  final GlobalKey searchKey = GlobalKey(debugLabel: 'tutorial_search');

  bool _tutorialActive = false;
  bool get isTutorialActive => _tutorialActive;

  // Track if setup is included in current tutorial run
  bool _includeSetupInCurrentRun = true;
  bool get includeSetupInCurrentRun => _includeSetupInCurrentRun;

  void setIncludeSetup(bool include) {
    _includeSetupInCurrentRun = include;
  }

  /// Initialize the service
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  /// Check if tutorial has been completed before
  Future<bool> isTutorialCompleted() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!.getBool(_tutorialCompletedKey) ?? false;
  }

  /// Mark tutorial as completed
  Future<void> setTutorialCompleted(bool completed) async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setBool(_tutorialCompletedKey, completed);
  }

  /// Set tutorial active state
  void setTutorialActive(bool active) {
    _tutorialActive = active;
  }

  /// Get ordered list of tutorial keys for the showcase sequence
  /// If [includeSetup] is false, skips the setup banner step
  List<GlobalKey> getTutorialKeys({bool includeSetup = true}) {
    return [
      if (includeSetup) setupBannerKey,
      recentFilesKey,
      categoriesKey,
      starredKey,
      cloudKey,
      sharedKey,
      playlistsKey,
      storageKey,
      trashKey,
      settingsKey,
      searchKey,
    ];
  }

  /// Get the step index offset when setup is skipped
  int getStepOffset({bool includeSetup = true}) {
    return includeSetup ? 0 : 1;
  }

  /// Tutorial step descriptions
  static const Map<int, TutorialStep> steps = {
    0: TutorialStep(
      title: 'Complete Setup',
      description: 'Complete these tasks to get started with FxFiles. Sign in, configure your API key, and link your wallet.',
    ),
    1: TutorialStep(
      title: 'Recent Files',
      description: 'Your recently opened files appear here for quick access. Tap any file to open it again.',
    ),
    2: TutorialStep(
      title: 'Categories',
      description: 'Browse different file types on your phone. Tap any category to view images, videos, audio, documents, and more.',
    ),
    3: TutorialStep(
      title: 'Starred Files',
      description: 'Star your important files for quick access. All starred files appear here.',
    ),
    4: TutorialStep(
      title: 'Cloud Storage',
      description: 'Upload local files to Fula network for secure backup. Uploaded files are listed here but also accessible from their original category.',
    ),
    5: TutorialStep(
      title: 'Shared Files',
      description: 'Create share links for uploaded files and share them with others. Your sharing history appears here.',
    ),
    6: TutorialStep(
      title: 'Playlists',
      description: 'Create and manage audio playlists from your music files.',
    ),
    7: TutorialStep(
      title: 'Storage',
      description: 'Directly explore your phone\'s file system. Access internal storage and external drives.',
    ),
    8: TutorialStep(
      title: 'Trash',
      description: 'Deleted files are moved here. Empty trash manually to free up storage space.',
    ),
    9: TutorialStep(
      title: 'Settings',
      description: 'Access additional settings including billing, credits, and face tagging management.',
    ),
    10: TutorialStep(
      title: 'Search',
      description: 'Search files by name or by tagged people in your photos.',
    ),
  };
}

/// Data class for tutorial step information
class TutorialStep {
  final String title;
  final String description;

  const TutorialStep({
    required this.title,
    required this.description,
  });
}

/// Custom Showcase widget with Skip/Prev/Next buttons and auto-scroll support
class TutorialShowcase extends StatelessWidget {
  final GlobalKey showcaseKey;
  final int stepIndex;
  final Widget child;
  final ShapeBorder? targetShapeBorder;
  final BorderRadius? targetBorderRadius;

  const TutorialShowcase({
    super.key,
    required this.showcaseKey,
    required this.stepIndex,
    required this.child,
    this.targetShapeBorder,
    this.targetBorderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final step = TutorialService.steps[stepIndex];
    final includeSetup = TutorialService.instance.includeSetupInCurrentRun;

    // Calculate actual position in current tutorial sequence
    final actualStepIndex = includeSetup ? stepIndex : stepIndex - 1;
    final totalSteps = includeSetup
        ? TutorialService.steps.length
        : TutorialService.steps.length - 1;
    final isFirst = actualStepIndex == 0;
    final isLast = actualStepIndex == totalSteps - 1;

    // Capture ShowCaseWidget reference from the correct context
    return Builder(
      builder: (showcaseContext) {
        return Showcase.withWidget(
          key: showcaseKey,
          targetShapeBorder: targetShapeBorder ?? const RoundedRectangleBorder(),
          targetBorderRadius: targetBorderRadius,
          height: 220,
          width: MediaQuery.of(showcaseContext).size.width * 0.85 > 300
              ? 300
              : MediaQuery.of(showcaseContext).size.width * 0.85,
          container: _TutorialTooltipContent(
            title: step?.title ?? '',
            description: step?.description ?? '',
            stepIndex: actualStepIndex,
            totalSteps: totalSteps,
            isFirst: isFirst,
            isLast: isLast,
            onSkip: () {
              ShowCaseWidget.of(showcaseContext).dismiss();
              TutorialService.instance.setTutorialActive(false);
            },
            onPrev: () => ShowCaseWidget.of(showcaseContext).previous(),
            onNext: () {
              if (isLast) {
                ShowCaseWidget.of(showcaseContext).dismiss();
                TutorialService.instance.setTutorialActive(false);
                TutorialService.instance.setTutorialCompleted(true);
              } else {
                ShowCaseWidget.of(showcaseContext).next();
              }
            },
          ),
          child: child,
        );
      },
    );
  }
}

/// Custom tooltip content with description and navigation buttons
class _TutorialTooltipContent extends StatelessWidget {
  final String title;
  final String description;
  final int stepIndex;
  final int totalSteps;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onSkip;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  const _TutorialTooltipContent({
    required this.title,
    required this.description,
    required this.stepIndex,
    required this.totalSteps,
    required this.isFirst,
    required this.isLast,
    required this.onSkip,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final tooltipWidth = (screenWidth * 0.85).clamp(200.0, 300.0);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: tooltipWidth,
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            // Description
            Text(
              description,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.black54,
                height: 1.4,
              ),
              softWrap: true,
            ),
            const SizedBox(height: 16),
            // Navigation buttons
            Row(
              mainAxisSize: MainAxisSize.max,
              children: [
                // Skip button
                TextButton(
                  onPressed: onSkip,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: Colors.grey[600],
                  ),
                  child: const Text('Skip'),
                ),
                const Spacer(),
                // Prev button
                if (!isFirst)
                  TextButton(
                    onPressed: onPrev,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Prev'),
                  ),
                const SizedBox(width: 8),
                // Next/Finish button
                ElevatedButton(
                  onPressed: onNext,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(isLast ? 'Finish' : 'Next'),
                ),
              ],
            ),
            // Step indicator
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${stepIndex + 1} of $totalSteps',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[500],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
