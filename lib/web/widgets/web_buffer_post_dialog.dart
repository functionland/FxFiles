import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/social_post_record.dart';
import 'package:fula_files/core/services/social_post_logic.dart';
import 'package:fula_files/web/services/web_social_post_service.dart';

/// Channel picker + poster for Buffer. Loads the user's channels through
/// the backend proxy, auto-picks the short caption for X/Twitter-like
/// channels (overridable), posts per caption variant, and shows
/// per-channel results inline.
class WebBufferPostDialog extends StatefulWidget {
  final SocialCaptions captions;
  final String imageUrl;
  const WebBufferPostDialog(
      {super.key, required this.captions, required this.imageUrl});

  @override
  State<WebBufferPostDialog> createState() => _WebBufferPostDialogState();
}

class _WebBufferPostDialogState extends State<WebBufferPostDialog> {
  List<({String id, String name, String service})>? _channels;
  String? _loadError;
  final Set<String> _selected = {};
  bool _shortEverywhere = false;
  bool _posting = false;
  Map<String, ({bool ok, String? error})>? _results;

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    setState(() {
      _channels = null;
      _loadError = null;
    });
    try {
      final channels =
          await WebSocialPostService.instance.fetchBufferChannels();
      if (!mounted) return;
      setState(() => _channels = channels);
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _loadError = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  String _captionFor(String service) => _shortEverywhere
      ? widget.captions.short
      : captionForBufferService(service,
          long: widget.captions.long, short: widget.captions.short);

  Future<void> _post() async {
    final channels = _channels;
    if (channels == null || _selected.isEmpty) return;
    setState(() {
      _posting = true;
      _results = null;
    });

    // Group the selected channels by their caption text (≤2 variants) so
    // each variant is one proxy call.
    final byCaption = <String, List<String>>{};
    for (final ch in channels.where((c) => _selected.contains(c.id))) {
      byCaption.putIfAbsent(_captionFor(ch.service), () => []).add(ch.id);
    }

    final results = <String, ({bool ok, String? error})>{};
    for (final entry in byCaption.entries) {
      try {
        final r = await WebSocialPostService.instance.postToBuffer(
          channelIds: entry.value,
          text: entry.key,
          imageUrl: widget.imageUrl,
        );
        for (final item in r) {
          results[item.channelId] = (ok: item.ok, error: item.error);
        }
      } catch (e) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        for (final id in entry.value) {
          results[id] = (ok: false, error: msg);
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _posting = false;
      _results = results;
    });

    final summary = summarizeBufferResults([
      for (final e in results.entries)
        (channelId: e.key, ok: e.value.ok, error: e.value.error)
    ]);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(summary.summary)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final channels = _channels;
    return AlertDialog(
      title: const Text('Post to social media'),
      content: SizedBox(
        width: 420,
        child: _loadError != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_loadError!,
                      style: TextStyle(color: theme.colorScheme.error)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton(
                          onPressed: _loadChannels,
                          child: const Text('Retry')),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          context.go('/settings/buffer');
                        },
                        child: const Text('Buffer settings'),
                      ),
                    ],
                  ),
                ],
              )
            : channels == null
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : channels.isEmpty
                    ? const Text(
                        'No channels connected in Buffer. Connect a channel '
                        'at buffer.com first.')
                    : SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                'Each post carries the generated image; '
                                'X-style channels get the short caption.',
                                style: theme.textTheme.bodySmall),
                            const SizedBox(height: 4),
                            for (final ch in channels)
                              CheckboxListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                value: _selected.contains(ch.id),
                                onChanged: _posting
                                    ? null
                                    : (v) => setState(() => v == true
                                        ? _selected.add(ch.id)
                                        : _selected.remove(ch.id)),
                                title: Text(ch.name),
                                subtitle: Text(ch.service),
                                secondary: _results == null
                                    ? null
                                    : _resultIcon(ch.id),
                              ),
                            SwitchListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                  'Use the short caption everywhere',
                                  style: TextStyle(fontSize: 13)),
                              value: _shortEverywhere,
                              onChanged: _posting
                                  ? null
                                  : (v) =>
                                      setState(() => _shortEverywhere = v),
                            ),
                            if (_results != null &&
                                _results!.values.any((r) => !r.ok)) ...[
                              const SizedBox(height: 4),
                              for (final e in _results!.entries)
                                if (!e.value.ok)
                                  Text(
                                    '${channels.firstWhere((c) => c.id == e.key, orElse: () => (id: e.key, name: e.key, service: '')).name}: ${e.value.error ?? 'failed'}',
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(
                                            color:
                                                theme.colorScheme.error),
                                  ),
                            ],
                          ],
                        ),
                      ),
      ),
      actions: [
        TextButton(
          onPressed:
              _posting ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          icon: _posting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(LucideIcons.send, size: 14),
          label: const Text('Post'),
          onPressed:
              (_posting || channels == null || _selected.isEmpty)
                  ? null
                  : _post,
        ),
      ],
    );
  }

  Widget _resultIcon(String channelId) {
    final r = _results?[channelId];
    if (r == null) return const SizedBox.shrink();
    return r.ok
        ? const Icon(LucideIcons.checkCircle, size: 16, color: Colors.green)
        : const Icon(LucideIcons.alertCircle, size: 16, color: Colors.red);
  }
}
