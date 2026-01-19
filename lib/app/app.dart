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
  bool _tosAccepted = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    // Check ToS acceptance after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkTosAcceptance();
    });
  }

  void _checkTosAcceptance() {
    final settings = ref.read(settingsProvider);
    setState(() {
      _tosAccepted = settings.tosAccepted;
      _initialized = true;
    });
  }

  void _onTosAccepted() {
    setState(() {
      _tosAccepted = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final router = ref.watch(routerProvider);

    // Update tosAccepted when settings change (for initial load)
    if (_initialized && settings.tosAccepted && !_tosAccepted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() => _tosAccepted = true);
      });
    }

    return MaterialApp.router(
      title: 'FxFiles',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: settings.themeMode,
      routerConfig: router,
      builder: (context, child) {
        // Show ToS screen if not accepted
        if (!_tosAccepted) {
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
