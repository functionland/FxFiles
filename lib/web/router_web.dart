import 'package:go_router/go_router.dart';

import 'package:fula_files/web/screens/web_bucket_screen.dart';
import 'package:fula_files/web/screens/web_home_screen.dart';
import 'package:fula_files/web/screens/web_signin_screen.dart';
import 'package:fula_files/web/services/web_session.dart';

/// Web-shell router. Deliberately defines ONLY the cloud routes — the
/// native app's local-file/sync/AI routes never enter the web compile
/// graph (structural feature gating). Hash URL strategy (Flutter web
/// default) keeps GitHub Pages happy without 404 rewrites.
GoRouter buildWebRouter() {
  return GoRouter(
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
        ),
      ),
    ],
  );
}
