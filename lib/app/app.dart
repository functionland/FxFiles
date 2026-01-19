import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/app/router.dart';
import 'package:fula_files/app/theme/app_theme.dart';
import 'package:fula_files/features/settings/providers/settings_provider.dart';
import 'package:fula_files/features/onboarding/screens/terms_of_service_screen.dart';
import 'package:fula_files/shared/widgets/mini_player.dart';

class FulaFilesApp extends ConsumerStatefulWidget {
  const FulaFilesApp({super.key});

  @override
  ConsumerState<FulaFilesApp> createState() => _FulaFilesAppState();
}

class _FulaFilesAppState extends ConsumerState<FulaFilesApp> {
  // Track if user accepted ToS in this session (before async save completes)
  bool _acceptedThisSession = false;

  void _onTosAccepted() {
    setState(() {
      _acceptedThisSession = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final router = ref.watch(routerProvider);

    // ToS is accepted if: saved in storage OR accepted this session
    final tosAccepted = settings.tosAccepted || _acceptedThisSession;

    return MaterialApp.router(
      title: 'FxFiles',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: settings.themeMode,
      routerConfig: router,
      builder: (context, child) {
        // Show ToS screen if not accepted
        if (!tosAccepted) {
          return TermsOfServiceScreen(onAccepted: _onTosAccepted);
        }

        return Column(
          children: [
            Expanded(child: child ?? const SizedBox()),
            const MiniPlayer(),
          ],
        );
      },
    );
  }
}
