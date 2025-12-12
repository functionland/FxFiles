import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fula_files/features/home/screens/home_screen.dart';
import 'package:fula_files/features/browser/screens/file_browser_screen.dart';
import 'package:fula_files/features/fula/screens/fula_browser_screen.dart';
import 'package:fula_files/features/settings/screens/settings_screen.dart';
import 'package:fula_files/features/search/screens/search_screen.dart';
import 'package:fula_files/features/trash/screens/trash_screen.dart';
import 'package:fula_files/features/sharing/screens/share_screen.dart';
import 'package:fula_files/features/viewer/screens/image_viewer_screen.dart';
import 'package:fula_files/features/viewer/screens/video_viewer_screen.dart';
import 'package:fula_files/features/viewer/screens/text_viewer_screen.dart';
import 'package:fula_files/features/viewer/screens/audio_player_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
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
          return FulaBrowserScreen(bucket: bucket, prefix: prefix);
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
          final filePath = state.extra as String;
          return ImageViewerScreen(filePath: filePath);
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
    ],
  );
});
