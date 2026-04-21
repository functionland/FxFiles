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
  final GlobalKey categoriesKey = GlobalKey(debugLabel: 'tutorial_on_this_phone');
  final GlobalKey cloudKey = GlobalKey(debugLabel: 'tutorial_in_the_cloud');
  final GlobalKey createKey = GlobalKey(debugLabel: 'tutorial_create');
  final GlobalKey storageKey = GlobalKey(debugLabel: 'tutorial_storage');
  final GlobalKey moreKey = GlobalKey(debugLabel: 'tutorial_more');
  final GlobalKey settingsKey = GlobalKey(debugLabel: 'tutorial_settings');
  final GlobalKey searchKey = GlobalKey(debugLabel: 'tutorial_search');

  // Legacy keys kept only to preserve existing GlobalKey references; no longer part of the sequence.
  final GlobalKey starredKey = GlobalKey(debugLabel: 'tutorial_starred_legacy');
  final GlobalKey sharedKey = GlobalKey(debugLabel: 'tutorial_shared_legacy');
  final GlobalKey playlistsKey = GlobalKey(debugLabel: 'tutorial_playlists_legacy');
  final GlobalKey trashKey = GlobalKey(debugLabel: 'tutorial_trash_legacy');

  // GlobalKeys for browser/category screen tutorial
  final GlobalKey browserRefreshKey = GlobalKey(debugLabel: 'browser_refresh');
  final GlobalKey browserSortKey = GlobalKey(debugLabel: 'browser_sort');
  final GlobalKey browserViewModeKey = GlobalKey(debugLabel: 'browser_viewmode');
  final GlobalKey browserSyncKey = GlobalKey(debugLabel: 'browser_sync');
  final GlobalKey browserItemMenuKey = GlobalKey(debugLabel: 'browser_item_menu');
  final GlobalKey browserItemKey = GlobalKey(debugLabel: 'browser_item');

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
      cloudKey,
      createKey,
      storageKey,
      moreKey,
      settingsKey,
      searchKey,
    ];
  }

  /// Get the step index offset when setup is skipped
  int getStepOffset({bool includeSetup = true}) {
    return includeSetup ? 0 : 1;
  }

  /// Tutorial step descriptions for home screen
  static const Map<int, TutorialStep> steps = {
    0: TutorialStep(
      title: 'Finish Setup',
      description: 'Sign in, connect cloud storage, and link a wallet to unlock all features. Tap the bar to see what\'s left.',
    ),
    1: TutorialStep(
      title: 'Recent Files',
      description: 'Your recently opened files appear here for quick access. Tap any file to open it again.',
    ),
    2: TutorialStep(
      title: 'On this phone',
      description: 'Browse files stored locally on your device — Photos, Videos, Audio, Docs, Downloads, and Archives.',
    ),
    3: TutorialStep(
      title: 'In the cloud',
      description: 'Your cloud files, shared folders, and starred items live here. Upload items to back them up to the Fula network.',
    ),
    4: TutorialStep(
      title: 'Create',
      description: 'Build a personal Website or mint NFTs from your photos. Some features need your wallet linked first.',
    ),
    5: TutorialStep(
      title: 'Storage',
      description: 'See how much space is used on your phone, SD card, and cloud — with a friendly bar for each.',
    ),
    6: TutorialStep(
      title: 'More',
      description: 'Trash, Tags, Apps, and Playlists live here. Deleted files stay in Trash until you empty it.',
    ),
    7: TutorialStep(
      title: 'Settings',
      description: 'Access additional settings including billing, credits, and face tagging management.',
    ),
    8: TutorialStep(
      title: 'Search',
      description: 'Search files by name or by tagged people in your photos.',
    ),
  };

  /// Tutorial step descriptions for browser/category screen
  static const Map<int, TutorialStep> browserSteps = {
    0: TutorialStep(
      title: 'Refresh',
      description: 'Tap to refresh the loaded files. These are all files in your local storage for this category.',
    ),
    1: TutorialStep(
      title: 'Sort Order',
      description: 'Tap to change the sort order. You can sort by date or name, ascending or descending.',
    ),
    2: TutorialStep(
      title: 'View Mode',
      description: 'Tap to switch between list view and grid view. Grid view shows larger thumbnails.',
    ),
    3: TutorialStep(
      title: 'Auto-Sync',
      description: 'Tap to activate auto-sync for this category. All items will automatically sync to the Fula network.',
    ),
    4: TutorialStep(
      title: 'Item Actions',
      description: 'Tap to see all actions for this file: upload to cloud, share through link, share through another app, or delete.',
    ),
    5: TutorialStep(
      title: 'Open File',
      description: 'Tap to open the file. For images, you can edit or tag faces. Long press to activate multi-select for bulk actions like upload.',
    ),
  };

  /// Get ordered list of browser tutorial keys
  List<GlobalKey> getBrowserTutorialKeys() {
    return [
      browserRefreshKey,
      browserSortKey,
      browserViewModeKey,
      browserSyncKey,
      browserItemMenuKey,
      browserItemKey,
    ];
  }
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

/// Custom Showcase widget for browser/category screens
class BrowserTutorialShowcase extends StatelessWidget {
  final GlobalKey showcaseKey;
  final int stepIndex;
  final Widget child;
  final ShapeBorder? targetShapeBorder;
  final BorderRadius? targetBorderRadius;
  final VoidCallback? onComplete;

  const BrowserTutorialShowcase({
    super.key,
    required this.showcaseKey,
    required this.stepIndex,
    required this.child,
    this.targetShapeBorder,
    this.targetBorderRadius,
    this.onComplete,
  });

  @override
  Widget build(BuildContext context) {
    final step = TutorialService.browserSteps[stepIndex];
    final totalSteps = TutorialService.browserSteps.length;
    final isFirst = stepIndex == 0;
    final isLast = stepIndex == totalSteps - 1;

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
            stepIndex: stepIndex,
            totalSteps: totalSteps,
            isFirst: isFirst,
            isLast: isLast,
            onSkip: () {
              ShowCaseWidget.of(showcaseContext).dismiss();
            },
            onPrev: () => ShowCaseWidget.of(showcaseContext).previous(),
            onNext: () {
              if (isLast) {
                ShowCaseWidget.of(showcaseContext).dismiss();
                onComplete?.call();
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
