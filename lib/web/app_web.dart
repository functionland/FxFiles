import 'package:flutter/material.dart';

import 'package:fula_files/app/theme/app_theme.dart';
import 'package:fula_files/web/router_web.dart';

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
    );
  }
}
