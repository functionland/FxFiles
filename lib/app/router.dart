import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fula_files/features/home/screens/home_screen.dart';
import 'package:fula_files/features/browser/screens/file_browser_screen.dart';
import 'package:fula_files/features/settings/screens/settings_screen.dart';
import 'package:fula_files/features/search/screens/search_screen.dart';
import 'package:fula_files/features/trash/screens/trash_screen.dart';
import 'package:fula_files/features/sharing/screens/share_screen.dart';
import 'package:fula_files/features/viewer/screens/image_viewer_screen.dart';
import 'package:fula_files/features/viewer/screens/video_viewer_screen.dart';
import 'package:fula_files/features/viewer/screens/text_viewer_screen.dart';
import 'package:fula_files/features/viewer/screens/audio_player_screen.dart';
import 'package:fula_files/features/audio/screens/playlists_screen.dart';
import 'package:fula_files/features/audio/screens/playlist_detail_screen.dart';
import 'package:fula_files/features/tags/screens/tags_browser_screen.dart';
import 'package:fula_files/features/tags/screens/tagged_files_screen.dart';
import 'package:fula_files/features/websites/screens/websites_browser_screen.dart';
import 'package:fula_files/features/websites/screens/website_detail_screen.dart';
import 'package:fula_files/features/ai_tasks/screens/ai_tasks_browser_screen.dart';
import 'package:fula_files/features/ai_tasks/screens/ai_task_detail_screen.dart';
import 'package:fula_files/features/ai_tasks/screens/ai_task_run_screen.dart';
import 'package:fula_files/features/automate/screens/automate_tasks_browser_screen.dart';
import 'package:fula_files/features/automate/screens/automate_task_detail_screen.dart';
import 'package:fula_files/features/automate/screens/automate_task_run_screen.dart';
import 'package:fula_files/features/nft/screens/nfts_browser_screen.dart';
import 'package:fula_files/features/nft/screens/nft_detail_screen.dart';
import 'package:fula_files/features/nft/screens/nft_claim_screen.dart';
import 'package:fula_files/features/apps/screens/apps_browser_screen.dart';
import 'package:fula_files/features/apps/screens/whatsapp_backup_screen.dart';
import 'package:fula_files/features/apps/screens/restore_screen.dart';
import 'package:fula_files/features/sharing/screens/collaboration_detail_screen.dart';
import 'package:fula_files/features/sharing/screens/accept_collab_screen.dart';
import 'package:fula_files/features/sharing/screens/accept_share_screen.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/services/wallet_service.dart';
import 'package:fula_files/features/settings/screens/blox_pairing_screen.dart';
import 'package:fula_files/features/settings/screens/sync_queue_screen.dart';
import 'package:fula_files/features/onboarding/screens/mode_a_signin_screen.dart';
import 'package:fula_files/features/onboarding/screens/mode_b_signin_screen.dart';
import 'package:fula_files/features/onboarding/screens/mode_c_signin_screen.dart';
import 'package:fula_files/features/onboarding/screens/mode_choice_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: walletNavigatorKey,
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/browser',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          final path = state.uri.queryParameters['path'] ?? extra?['path'];
          final category = extra?['category'] as String?;
          return FileBrowserScreen(initialPath: path, category: category);
        },
      ),
      GoRoute(
        path: '/fula',
        builder: (context, state) {
          final bucket = state.uri.queryParameters['bucket'];
          final prefix = state.uri.queryParameters['prefix'];
          return FileBrowserScreen(
            cloudMode: true,
            initialBucket: bucket,
            initialPrefix: prefix,
          );
        },
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      // Audit F-A1 / F-A3 redesign — seed-as-identity onboarding.
      // Existing Mode A users never see these routes; they're
      // entered only from new-user / new-device sign-in entry points.
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const ModeChoiceScreen(),
      ),
      GoRoute(
        path: '/onboarding/mode-a',
        builder: (context, state) => const ModeASignInScreen(),
      ),
      GoRoute(
        path: '/onboarding/mode-b',
        builder: (context, state) => const ModeBSignInScreen(),
      ),
      GoRoute(
        path: '/onboarding/mode-c',
        builder: (context, state) => const ModeCSignInScreen(),
      ),
      GoRoute(
        path: '/sync-queue',
        builder: (context, state) => const SyncQueueScreen(),
      ),
      GoRoute(
        path: '/search',
        builder: (context, state) => const SearchScreen(),
      ),
      GoRoute(
        path: '/trash',
        builder: (context, state) => const TrashScreen(),
      ),
      GoRoute(
        path: '/shared',
        builder: (context, state) => const ShareScreen(),
      ),
      GoRoute(
        path: '/collab/accept-link',
        builder: (context, state) => AcceptCollabScreen(
          initialFolderPath: state.extra as String?,
        ),
      ),
      GoRoute(
        path: '/share/accept-link',
        builder: (context, state) => AcceptShareScreen(
          initialFolderPath: state.extra as String?,
        ),
      ),
      GoRoute(
        path: '/collab/:id',
        builder: (context, state) {
          final groupId = state.pathParameters['id']!;
          return CollaborationDetailScreen(groupId: groupId);
        },
      ),
      GoRoute(
        path: '/viewer/image',
        builder: (context, state) {
          final extra = state.extra;
          if (extra is String) {
            return ImageViewerScreen(filePath: extra);
          } else if (extra is Map<String, dynamic>) {
            return ImageViewerScreen(
              filePath: extra['filePath'] as String,
              imageList: extra['imageList'] as List<String>?,
              initialIndex: extra['initialIndex'] as int?,
            );
          }
          return ImageViewerScreen(filePath: extra as String);
        },
      ),
      GoRoute(
        path: '/viewer/video',
        builder: (context, state) {
          final filePath = state.extra as String;
          return VideoViewerScreen(filePath: filePath);
        },
      ),
      GoRoute(
        path: '/viewer/text',
        builder: (context, state) {
          final filePath = state.extra as String;
          return TextViewerScreen(filePath: filePath);
        },
      ),
      GoRoute(
        path: '/viewer/audio',
        builder: (context, state) {
          final filePath = state.extra as String;
          return AudioPlayerScreen(filePath: filePath);
        },
      ),
      GoRoute(
        path: '/playlists',
        builder: (context, state) => const PlaylistsScreen(),
      ),
      GoRoute(
        path: '/playlist/:id',
        builder: (context, state) {
          final playlistId = state.pathParameters['id']!;
          return PlaylistDetailScreen(playlistId: playlistId);
        },
      ),
      GoRoute(
        path: '/tags',
        builder: (context, state) => const TagsBrowserScreen(),
      ),
      GoRoute(
        path: '/tags/:id',
        builder: (context, state) {
          final tagId = state.pathParameters['id']!;
          final tag = state.extra as FileTag?;
          return TaggedFilesScreen(tagId: tagId, tag: tag);
        },
      ),
      GoRoute(
        path: '/blox-pairing',
        builder: (context, state) {
          return BloxPairingScreen(
            pairingSecret: state.uri.queryParameters['secret'],
            hardwareId: state.uri.queryParameters['hardwareId'],
            bloxPeerId: state.uri.queryParameters['bloxPeerId'],
            bloxName: state.uri.queryParameters['bloxName'],
          );
        },
      ),
      GoRoute(
        path: '/websites',
        builder: (context, state) => const WebsitesBrowserScreen(),
      ),
      GoRoute(
        path: '/websites/:id',
        builder: (context, state) {
          final tagId = state.pathParameters['id']!;
          final tag = state.extra as FileTag?;
          return WebsiteDetailScreen(tagId: tagId, tag: tag);
        },
      ),
      GoRoute(
        path: '/ai-tasks',
        builder: (context, state) => const AiTasksBrowserScreen(),
      ),
      GoRoute(
        path: '/ai-tasks/:id',
        builder: (context, state) {
          final tagId = state.pathParameters['id']!;
          final tag = state.extra as FileTag?;
          return AiTaskDetailScreen(tagId: tagId, tag: tag);
        },
      ),
      GoRoute(
        path: '/ai-tasks/:id/run',
        builder: (context, state) {
          final tagId = state.pathParameters['id']!;
          return AiTaskRunScreen(tagId: tagId);
        },
      ),
      // Automate feature — deterministic bulk-send (no LLM). Replaces
      // the user-facing role the AI tile used to fill; AI routes above
      // stay registered so stranded `ai-tasks-*` tags from earlier
      // installs still resolve cleanly.
      GoRoute(
        path: '/automate-tasks',
        builder: (context, state) => const AutomateTasksBrowserScreen(),
      ),
      GoRoute(
        path: '/automate-tasks/:id',
        builder: (context, state) {
          final tagId = state.pathParameters['id']!;
          final tag = state.extra as FileTag?;
          return AutomateTaskDetailScreen(tagId: tagId, tag: tag);
        },
      ),
      GoRoute(
        path: '/automate-tasks/:id/run',
        builder: (context, state) {
          final tagId = state.pathParameters['id']!;
          return AutomateTaskRunScreen(tagId: tagId);
        },
      ),
      GoRoute(
        path: '/nfts',
        builder: (context, state) => const NftsBrowserScreen(),
      ),
      GoRoute(
        path: '/nfts/:id',
        builder: (context, state) {
          final tagId = state.pathParameters['id']!;
          final tag = state.extra as FileTag?;
          return NftDetailScreen(tagId: tagId, tag: tag);
        },
      ),
      GoRoute(
        path: '/apps',
        builder: (context, state) => const AppsBrowserScreen(),
      ),
      GoRoute(
        path: '/apps/:id',
        builder: (context, state) {
          final appId = state.pathParameters['id']!;
          return WhatsAppBackupScreen(appId: appId);
        },
      ),
      GoRoute(
        path: '/apps/:id/restore',
        builder: (context, state) {
          final appId = state.pathParameters['id']!;
          final extra = state.extra as Map<String, dynamic>?;
          final showCategoryPicker = extra?['showCategoryPicker'] as bool? ?? false;
          return RestoreScreen(appId: appId, showCategoryPicker: showCategoryPicker);
        },
      ),
      GoRoute(
        path: '/nft-claim',
        builder: (context, state) {
          return NftClaimScreen(
            chainId: state.uri.queryParameters['chain'],
            contractAddress: state.uri.queryParameters['contract'],
            tokenId: state.uri.queryParameters['token'],
            linkHash: state.uri.queryParameters['hash'],
            receivedNftId: state.uri.queryParameters['receivedId'],
          );
        },
      ),
    ],
  );
});
