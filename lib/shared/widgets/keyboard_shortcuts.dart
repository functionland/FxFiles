import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:fula_files/core/utils/platform_capabilities.dart';

/// Wraps the app with desktop keyboard shortcuts.
/// On mobile platforms, this is a transparent pass-through.
class DesktopKeyboardShortcuts extends StatelessWidget {
  final Widget child;

  const DesktopKeyboardShortcuts({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!PlatformCapabilities.isDesktop) return child;

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            const _SearchIntent(),
        const SingleActivator(LogicalKeyboardKey.comma, control: true):
            const _SettingsIntent(),
        const SingleActivator(LogicalKeyboardKey.f5):
            const _RefreshIntent(),
        const SingleActivator(LogicalKeyboardKey.escape):
            const DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SearchIntent: CallbackAction<_SearchIntent>(
            onInvoke: (_) {
              final router = GoRouter.of(context);
              router.push('/search');
              return null;
            },
          ),
          _SettingsIntent: CallbackAction<_SettingsIntent>(
            onInvoke: (_) {
              final router = GoRouter.of(context);
              router.push('/settings');
              return null;
            },
          ),
          _RefreshIntent: CallbackAction<_RefreshIntent>(
            onInvoke: (_) {
              // Trigger a rebuild/refresh — individual screens handle their own refresh
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

class _SearchIntent extends Intent {
  const _SearchIntent();
}

class _SettingsIntent extends Intent {
  const _SettingsIntent();
}

class _RefreshIntent extends Intent {
  const _RefreshIntent();
}
