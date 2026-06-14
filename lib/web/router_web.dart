import 'package:go_router/go_router.dart';

import 'package:fula_files/core/services/wallet_service.dart'
    show walletNavigatorKey;
import 'package:fula_files/web/screens/web_automate_task_detail_screen.dart';
import 'package:fula_files/web/screens/web_automate_task_run_screen.dart';
import 'package:fula_files/web/screens/web_automate_tasks_screen.dart';
import 'package:fula_files/web/screens/web_bucket_screen.dart';
import 'package:fula_files/web/screens/web_collab_detail_screen.dart';
import 'package:fula_files/web/screens/web_home_screen.dart';
import 'package:fula_files/web/screens/web_nft_claim_screen.dart';
import 'package:fula_files/web/screens/web_nft_detail_screen.dart';
import 'package:fula_files/web/screens/web_nfts_screen.dart';
import 'package:fula_files/web/screens/web_playlists_screen.dart';
import 'package:fula_files/web/screens/web_shared_screen.dart';
import 'package:fula_files/web/screens/web_shelf_screen.dart';
import 'package:fula_files/web/screens/web_signin_screen.dart';
import 'package:fula_files/web/screens/web_tags_screen.dart';
import 'package:fula_files/web/screens/web_website_detail_screen.dart';
import 'package:fula_files/web/screens/web_websites_screen.dart';
import 'package:fula_files/web/services/web_session.dart';

/// Web-shell router. Deliberately defines ONLY the cloud routes — the
/// native app's local-file/sync/AI routes never enter the web compile
/// graph (structural feature gating). Hash URL strategy (Flutter web
/// default) keeps GitHub Pages happy without 404 rewrites.
GoRouter buildWebRouter() {
  return GoRouter(
    // Root navigator anchored to walletNavigatorKey — same as the
    // native router (lib/app/router.dart). Reown AppKit's modal keeps
    // the context it was initialized with; anchoring it to the
    // app-lifetime root navigator (instead of a screen that the next
    // context.go() disposes) is what keeps Connect Wallet / Mint
    // working after any navigation.
    navigatorKey: walletNavigatorKey,
    initialLocation: '/',
    refreshListenable: WebSession.instance,
    redirect: (context, state) {
      final signedIn = WebSession.instance.isSignedIn;
      final onSignIn = state.matchedLocation == '/signin';
      if (!signedIn && !onSignIn) return '/signin';
      if (signedIn && onSignIn) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/signin',
        builder: (context, state) => const WebSignInScreen(),
      ),
      GoRoute(
        path: '/',
        builder: (context, state) => const WebHomeScreen(),
      ),
      GoRoute(
        path: '/b/:base',
        builder: (context, state) => WebBucketScreen(
          base: state.pathParameters['base'] ?? 'documents',
          // Home Recent strip taps land here as /b/<base>?open=<key> so the
          // file reopens via the bucket screen's existing preview path.
          openKey: state.uri.queryParameters['open'],
        ),
      ),
      GoRoute(
        path: '/shelf',
        builder: (context, state) => const WebShelfScreen(),
      ),
      GoRoute(
        path: '/websites',
        builder: (context, state) => const WebWebsitesScreen(),
      ),
      GoRoute(
        path: '/websites/:id',
        builder: (context, state) => WebWebsiteDetailScreen(
          tagId: state.pathParameters['id'] ?? '',
        ),
      ),
      GoRoute(
        path: '/tags',
        builder: (context, state) => const WebTagsScreen(),
      ),
      GoRoute(
        path: '/tags/:id',
        builder: (context, state) => WebTaggedFilesScreen(
          tagId: state.pathParameters['id'] ?? '',
        ),
      ),
      GoRoute(
        path: '/playlists',
        builder: (context, state) => const WebPlaylistsScreen(),
      ),
      GoRoute(
        path: '/nfts',
        builder: (context, state) => const WebNftsScreen(),
      ),
      GoRoute(
        path: '/nfts/:id',
        builder: (context, state) => WebNftDetailScreen(
          tagId: state.pathParameters['id'] ?? '',
        ),
      ),
      GoRoute(
        path: '/nft-claim',
        builder: (context, state) {
          final q = state.uri.queryParameters;
          return WebNftClaimScreen(
            chainId: int.tryParse(q['chain'] ?? ''),
            contractAddress: q['contract'],
            tokenId: int.tryParse(q['token'] ?? ''),
            secret: q['hash'] ?? q['secret'],
          );
        },
      ),
      GoRoute(
        path: '/playlist/:id',
        builder: (context, state) => WebPlaylistDetailScreen(
          playlistId: state.pathParameters['id'] ?? '',
        ),
      ),
      GoRoute(
        path: '/shared',
        builder: (context, state) => const WebSharedScreen(),
      ),
      GoRoute(
        path: '/collab/:id',
        builder: (context, state) => WebCollabDetailScreen(
          groupId: state.pathParameters['id'] ?? '',
        ),
      ),
      GoRoute(
        path: '/automate-tasks',
        builder: (context, state) => const WebAutomateTasksScreen(),
      ),
      GoRoute(
        path: '/automate-tasks/:id',
        builder: (context, state) => WebAutomateTaskDetailScreen(
          tagId: state.pathParameters['id'] ?? '',
        ),
      ),
      GoRoute(
        path: '/automate-tasks/:id/run',
        builder: (context, state) => WebAutomateTaskRunScreen(
          tagId: state.pathParameters['id'] ?? '',
        ),
      ),
    ],
  );
}
