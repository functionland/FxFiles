import 'package:go_router/go_router.dart';

import 'package:fula_files/core/services/blox_pairing_links.dart';
import 'package:fula_files/core/services/wallet_service.dart'
    show walletNavigatorKey;
import 'package:fula_files/web/screens/web_api_config_screen.dart';
import 'package:fula_files/web/screens/web_buffer_settings_screen.dart';
import 'package:fula_files/web/screens/web_automate_task_detail_screen.dart';
import 'package:fula_files/web/screens/web_automate_task_run_screen.dart';
import 'package:fula_files/web/screens/web_automate_tasks_screen.dart';
import 'package:fula_files/web/screens/web_blox_pairing_screen.dart';
import 'package:fula_files/web/screens/web_bucket_screen.dart';
import 'package:fula_files/web/screens/web_cloud_files_screen.dart';
import 'package:fula_files/web/screens/web_collab_detail_screen.dart';
import 'package:fula_files/web/screens/web_home_screen.dart';
import 'package:fula_files/web/screens/web_nft_claim_screen.dart';
import 'package:fula_files/web/screens/web_nft_detail_screen.dart';
import 'package:fula_files/web/screens/web_nfts_screen.dart';
import 'package:fula_files/web/screens/web_playlists_screen.dart';
import 'package:fula_files/web/screens/web_search_screen.dart';
import 'package:fula_files/web/screens/web_settings_screen.dart';
import 'package:fula_files/web/screens/web_shared_screen.dart';
import 'package:fula_files/web/screens/web_shelf_screen.dart';
import 'package:fula_files/web/screens/web_signin_screen.dart';
import 'package:fula_files/web/screens/web_sync_queue_screen.dart';
import 'package:fula_files/web/screens/web_tags_screen.dart';
import 'package:fula_files/web/screens/web_website_detail_screen.dart';
import 'package:fula_files/web/screens/web_websites_screen.dart';
import 'package:fula_files/web/services/web_autopin_return.dart';
import 'package:fula_files/web/services/web_session.dart';

/// Web-shell router. Deliberately defines ONLY the cloud routes — the
/// native app's local-file/sync routes never enter the web compile
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
      final loc = state.matchedLocation;
      // Blox pairing return (`#/autopin-complete?secret=…`). main() normally
      // captures + strips this BEFORE the router mounts, so reaching here is
      // the replaceState-failed fallback. Logged out: park the params for the
      // post-login hand-off (web home init) instead of the blind bounce below
      // that would drop them; signed in: fall through and let the route
      // render (it persists the params and then cleans the URL).
      if (loc == '/autopin-complete' && !signedIn) {
        stashPendingAutopinReturn(parseAutopinCompleteParams(state.uri));
        return '/';
      }
      if (signedIn) {
        // Once authenticated, the standalone sign-in screen has no purpose.
        return loc == '/signin' ? '/' : null;
      }
      // Logged out: the home renders and auto-presents a CANCELABLE login
      // sheet (plus a top "sign in" bar). The home is the only logged-out
      // surface — every other route needs auth, so funnel logged-out users
      // there instead of a dead/empty screen. '/signin' stays reachable as a
      // full-screen fallback.
      if (loc == '/' || loc == '/signin') return null;
      return '/';
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
        path: '/search',
        builder: (context, state) => const WebSearchScreen(),
      ),
      GoRoute(
        path: '/cloud-files',
        builder: (context, state) => const WebCloudFilesScreen(),
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
      // Blox pairing (Settings → My Devices). The post-login hand-off from the
      // web home lands here with the FxBlox return as `extra` (never a query,
      // so the secret stays out of the address bar); a query is accepted too
      // for robustness.
      GoRoute(
        path: '/blox-pairing',
        builder: (context, state) {
          final extra = state.extra;
          return WebBloxPairingScreen(
            incoming: extra is AutopinCompleteParams
                ? extra
                : parseAutopinCompleteParams(state.uri),
          );
        },
      ),
      // Fallback receiver for `#/autopin-complete?secret=…` when main()'s
      // capture could not strip the URL (see the redirect above): persist,
      // then move to /blox-pairing so the secret leaves the URL.
      GoRoute(
        path: '/autopin-complete',
        builder: (context, state) => WebBloxPairingScreen(
          incoming: parseAutopinCompleteParams(state.uri),
          fromReturnUrl: true,
        ),
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
      GoRoute(
        path: '/settings',
        builder: (context, state) => const WebSettingsScreen(),
      ),
      GoRoute(
        path: '/settings/api',
        builder: (context, state) => const WebApiConfigScreen(),
      ),
      GoRoute(
        path: '/settings/buffer',
        builder: (context, state) => const WebBufferSettingsScreen(),
      ),
      GoRoute(
        path: '/sync-queue',
        builder: (context, state) => const WebSyncQueueScreen(),
      ),
    ],
  );
}
