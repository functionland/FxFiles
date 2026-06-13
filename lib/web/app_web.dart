import 'package:flutter/material.dart';

import 'package:fula_files/app/theme/app_theme.dart';
import 'package:fula_files/web/router_web.dart';
import 'package:fula_files/web/widgets/web_upload_tray.dart';

/// Root widget of the FxFiles web shell.
class FxFilesWebApp extends StatefulWidget {
  const FxFilesWebApp({super.key});

  @override
  State<FxFilesWebApp> createState() => _FxFilesWebAppState();
}

class _FxFilesWebAppState extends State<FxFilesWebApp> {
  late final router = buildWebRouter();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'FxFiles',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      routerConfig: router,
      // The upload tray lives ABOVE the router so it shows on every screen
      // and survives in-app navigation. It paints on top of page content
      // (and, being a thin strip at the very bottom, only minimally over a
      // centred dialog); it renders nothing when no upload is queued.
      builder: (context, child) {
        return Stack(
          children: [
            if (child != null) Positioned.fill(child: child),
            const WebUploadTray(),
          ],
        );
      },
    );
  }
}
