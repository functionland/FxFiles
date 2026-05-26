import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/services/shelf_storage_service.dart';

/// Resolves a `/dump/:id` route to the appropriate existing viewer
/// screen / system handler based on the item's [ShelfCategory]:
///
///   - image / screenshot → `/viewer/image`
///   - video → `/viewer/video`
///   - audio → `/viewer/audio`
///   - note → `/viewer/text`
///   - link → `url_launcher` (external browser)
///   - document / file / other → `open_filex` (system handler)
///
/// Renders a brief loading state while the dispatch happens, and an
/// error state when the item is unknown or its local file is missing.
class ShelfItemViewerScreen extends ConsumerStatefulWidget {
  final String itemId;
  const ShelfItemViewerScreen({super.key, required this.itemId});

  @override
  ConsumerState<ShelfItemViewerScreen> createState() =>
      _ShelfItemViewerScreenState();
}

class _ShelfItemViewerScreenState extends ConsumerState<ShelfItemViewerScreen> {
  bool _dispatched = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _dispatch());
  }

  Future<void> _dispatch() async {
    if (_dispatched) return;
    _dispatched = true;

    final item = ShelfStorageService.instance.getById(widget.itemId);
    if (item == null) {
      if (mounted) setState(() => _error = 'Shelf item not found');
      return;
    }

    final outcome = await openShelfItem(context, item);
    // openShelfItem may pop us off the stack if it pushed a viewer.
    // For link / open_filex cases, the dispatch completes here and
    // we want to fall back to the parent (/dump). If we're still
    // mounted, pop.
    if (!mounted) return;
    if (outcome == ShelfDispatchOutcome.handledInline) {
      // External handler invoked — pop back to /dump.
      if (context.canPop()) {
        context.pop();
      } else {
        // Cold-start path: nothing to pop to, route to /dump.
        context.go('/shelf');
      }
    } else if (outcome == ShelfDispatchOutcome.errored) {
      setState(() => _error = 'Could not open this item.');
    }
    // outcome == handledByPush → the viewer screen is now on top;
    // when the user pops it, they land back on /dump/:id. The post-
    // frame `_dispatch` already ran so no re-dispatch. Showing the
    // tile preview here is fine.
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Shelf')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.alertCircle,
                    size: 48, color: theme.colorScheme.error),
                const SizedBox(height: 12),
                Text(_error!, style: theme.textTheme.titleMedium),
              ],
            ),
          ),
        ),
      );
    }
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

/// Outcome of [openShelfItem]'s dispatch — public so the API surface
/// is self-describing for callers in Session 3b's manual-add flows.
enum ShelfDispatchOutcome {
  /// Pushed an in-app viewer screen via go_router. The user will
  /// navigate back through normal flow.
  handledByPush,

  /// Invoked an external app (browser / open_filex). The viewer
  /// screen should return to /dump.
  handledInline,

  /// Could not dispatch — show an error.
  errored,
}

/// Routes a [ShelfItem] to the appropriate viewer. Exposed at
/// file-scope so the future Session 3b FAB-import flow / manual-add
/// flows can reuse the dispatch logic.
Future<ShelfDispatchOutcome> openShelfItem(
    BuildContext context, ShelfItem item) async {
  switch (item.category) {
    case ShelfCategory.image:
    case ShelfCategory.screenshot:
      return _pushOrError(context, '/viewer/image', item.localCachePath);
    case ShelfCategory.video:
      return _pushOrError(context, '/viewer/video', item.localCachePath);
    case ShelfCategory.audio:
      return _pushOrError(context, '/viewer/audio', item.localCachePath);
    case ShelfCategory.note:
      return _pushOrError(context, '/viewer/text', item.localCachePath);
    case ShelfCategory.link:
      final raw = item.textPayload?.trim();
      if (raw == null || raw.isEmpty) return ShelfDispatchOutcome.errored;
      final uri = Uri.tryParse(raw);
      if (uri == null) return ShelfDispatchOutcome.errored;
      try {
        final ok =
            await launchUrl(uri, mode: LaunchMode.externalApplication);
        return ok
            ? ShelfDispatchOutcome.handledInline
            : ShelfDispatchOutcome.errored;
      } catch (_) {
        return ShelfDispatchOutcome.errored;
      }
    case ShelfCategory.document:
    case ShelfCategory.file:
    case ShelfCategory.other:
      if (!await File(item.localCachePath).exists()) {
        return ShelfDispatchOutcome.errored;
      }
      try {
        final res = await OpenFilex.open(item.localCachePath);
        return res.type == ResultType.done
            ? ShelfDispatchOutcome.handledInline
            : ShelfDispatchOutcome.errored;
      } catch (_) {
        return ShelfDispatchOutcome.errored;
      }
  }
}

Future<ShelfDispatchOutcome> _pushOrError(
    BuildContext context, String route, String localPath) async {
  if (!await File(localPath).exists()) return ShelfDispatchOutcome.errored;
  if (!context.mounted) return ShelfDispatchOutcome.errored;
  context.push(route, extra: localPath);
  return ShelfDispatchOutcome.handledByPush;
}
