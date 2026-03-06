import 'package:flutter/material.dart';
import 'package:fula_files/core/utils/platform_capabilities.dart';

/// Shows a modal bottom sheet on mobile and a centered dialog on desktop.
/// [builder] receives the context for building the sheet/dialog content.
Future<T?> showAdaptiveSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext) builder,
  bool isScrollControlled = true,
  bool useSafeArea = true,
  Color? backgroundColor,
}) {
  if (PlatformCapabilities.isDesktop) {
    return showDialog<T>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: backgroundColor ?? Theme.of(ctx).dialogTheme.backgroundColor,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 600),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: builder(ctx),
          ),
        ),
      ),
    );
  }

  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    backgroundColor: backgroundColor,
    builder: builder,
  );
}

/// Shows a context menu at the given position (for right-click on desktop).
Future<T?> showFileContextMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<PopupMenuEntry<T>> items,
}) {
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx + 1,
      position.dy + 1,
    ),
    items: items,
  );
}
