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
import 'package:fula_files/features/nft/screens/nfts_browser_screen.dart';
import 'package:fula_files/features/nft/screens/nft_detail_screen.dart';
import 'package:fula_files/features/nft/screens/nft_claim_screen.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/services/wallet_service.dart';
import 'package:fula_files/features/settings/screens/blox_pairing_screen.dart';

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
