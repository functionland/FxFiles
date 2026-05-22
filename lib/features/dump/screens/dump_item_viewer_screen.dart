import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/core/models/dump_item.dart';
import 'package:fula_files/core/services/dump_storage_service.dart';

/// Resolves a `/dump/:id` route to the appropriate existing viewer
/// screen / system handler based on the item's [DumpCategory]:
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
class DumpItemViewerScreen extends ConsumerStatefulWidget {
  final String itemId;
  const DumpItemViewerScreen({super.key, required this.itemId});

  @override
  ConsumerState<DumpItemViewerScreen> createState() =>
      _DumpItemViewerScreenState();
}

class _DumpItemViewerScreenState extends ConsumerState<DumpItemViewerScreen> {
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

    final item = DumpStorageService.instance.getById(widget.itemId);
    if (item == null) {
      if (mounted) setState(() => _error = 'Dump item not found');
      return;
    }

    final outcome = await openDumpItem(context, item);
    // openDumpItem may pop us off the stack if it pushed a viewer.
    // For link / open_filex cases, the dispatch completes here and
    // we want to fall back to the parent (/dump). If we're still
    // mounted, pop.
    if (!mounted) return;
    if (outcome == DumpDispatchOutcome.handledInline) {
      // External handler invoked — pop back to /dump.
      if (context.canPop()) {
        context.pop();
      } else {
        // Cold-start path: nothing to pop to, route to /dump.
        context.go('/dump');
      }
    } else if (outcome == DumpDispatchOutcome.errored) {
      setState(() => _error = 'Could not open this dump.');
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
        appBar: AppBar(title: const Text('Dump')),
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

/// Outcome of [openDumpItem]'s dispatch — public so the API surface
/// is self-describing for callers in Session 3b's manual-add flows.
enum DumpDispatchOutcome {
  /// Pushed an in-app viewer screen via go_router. The user will
  /// navigate back through normal flow.
  handledByPush,

  /// Invoked an external app (browser / open_filex). The viewer
  /// screen should return to /dump.
  handledInline,

  /// Could not dispatch — show an error.
  errored,
}

/// Routes a [DumpItem] to the appropriate viewer. Exposed at
/// file-scope so the future Session 3b FAB-import flow / manual-add
/// flows can reuse the dispatch logic.
Future<DumpDispatchOutcome> openDumpItem(
    BuildContext context, DumpItem item) async {
  switch (item.category) {
    case DumpCategory.image:
    case DumpCategory.screenshot:
      return _pushOrError(context, '/viewer/image', item.localCachePath);
    case DumpCategory.video:
      return _pushOrError(context, '/viewer/video', item.localCachePath);
    case DumpCategory.audio:
      return _pushOrError(context, '/viewer/audio', item.localCachePath);
    case DumpCategory.note:
      return _pushOrError(context, '/viewer/text', item.localCachePath);
    case DumpCategory.link:
      final raw = item.textPayload?.trim();
      if (raw == null || raw.isEmpty) return DumpDispatchOutcome.errored;
      final uri = Uri.tryParse(raw);
      if (uri == null) return DumpDispatchOutcome.errored;
      try {
        final ok =
            await launchUrl(uri, mode: LaunchMode.externalApplication);
        return ok
            ? DumpDispatchOutcome.handledInline
            : DumpDispatchOutcome.errored;
      } catch (_) {
        return DumpDispatchOutcome.errored;
      }
    case DumpCategory.document:
    case DumpCategory.file:
    case DumpCategory.other:
      if (!await File(item.localCachePath).exists()) {
        return DumpDispatchOutcome.errored;
      }
      try {
        final res = await OpenFilex.open(item.localCachePath);
        return res.type == ResultType.done
            ? DumpDispatchOutcome.handledInline
            : DumpDispatchOutcome.errored;
      } catch (_) {
        return DumpDispatchOutcome.errored;
      }
  }
}

Future<DumpDispatchOutcome> _pushOrError(
    BuildContext context, String route, String localPath) async {
  if (!await File(localPath).exists()) return DumpDispatchOutcome.errored;
  if (!context.mounted) return DumpDispatchOutcome.errored;
  context.push(route, extra: localPath);
  return DumpDispatchOutcome.handledByPush;
}
