import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/playlist.dart';
import 'package:fula_files/web/services/web_audio_controller.dart';
import 'package:fula_files/web/services/web_audio_queue.dart';
import 'package:fula_files/web/services/web_features.dart';
import 'package:fula_files/web/services/web_playlist_service.dart';
import 'package:fula_files/web/services/web_save.dart';

/// Full-screen web audio player (#21), mirroring the native
/// `audio_player_screen.dart`: now-playing, seek slider, play/pause, skip
/// prev/next, rewind/forward 10s, repeat (off/one/all), shuffle, a tappable
/// queue, add-to-playlist and download. Shown via `Dialog.fullscreen` (like
/// the image/text previews) over the [WebAudioController] singleton: the
/// caller starts playback with `WebAudioController.instance.playQueue(...)`
/// BEFORE opening this, and closing just MINIMIZES to the mini-player
/// (playback continues in the background).
class WebAudioPlayer extends StatefulWidget {
  const WebAudioPlayer({super.key});

  @override
  State<WebAudioPlayer> createState() => _WebAudioPlayerState();
}

class _WebAudioPlayerState extends State<WebAudioPlayer> {
  WebAudioController get _c => WebAudioController.instance;

  // NOTE: the expanded flag is set by the CALLERS around showDialog (event
  // context), NOT in initState/dispose — doing it here fires notifyListeners
  // during the dialog's build/dispose phase and marks the already-built
  // mini-player dirty mid-build (a framework assertion). See app_web /
  // web_bucket_screen / web_playlists_screen / web_mini_audio_player.

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _download() async {
    final t = _c.current;
    if (t == null) return;
    try {
      final bytes = await t.download();
      saveBytesAsDownload(t.name, bytes, mimeType: t.mime);
    } catch (e) {
      _snack('Download failed: $e');
    }
  }

  Future<void> _addToPlaylist() async {
    final t = _c.current;
    if (t == null) return;
    final at = AudioTrack(
      path: t.cloudKey,
      name: t.name,
      durationMs: _c.player.duration?.inMilliseconds ?? 0,
    );
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _AddToPlaylistSheet(track: at),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.chevronDown),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => Text(
            _c.current?.name ?? 'Audio',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.listPlus),
            tooltip: 'Add to playlist',
            onPressed: _addToPlaylist,
          ),
          IconButton(
            icon: const Icon(LucideIcons.download),
            tooltip: 'Download',
            onPressed: _download,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Column(
          children: [
            Expanded(child: _nowPlaying(theme)),
            _progressBar(theme),
            _mainControls(theme),
            _secondaryControls(theme),
            const Divider(height: 1),
            Expanded(child: _queueView(theme)),
          ],
        ),
      ),
    );
  }

  Widget _nowPlaying(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(LucideIcons.music,
                size: 72, color: theme.colorScheme.onPrimaryContainer),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _c.current?.name ?? '',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressBar(ThemeData theme) {
    return StreamBuilder<Duration?>(
      stream: _c.player.durationStream,
      builder: (_, durSnap) {
        final total = durSnap.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: _c.player.positionStream,
          builder: (_, posSnap) {
            var pos = posSnap.data ?? Duration.zero;
            if (pos > total) pos = total;
            final maxMs = total.inMilliseconds.toDouble();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  Slider(
                    value: pos.inMilliseconds
                        .clamp(0, maxMs.toInt())
                        .toDouble(),
                    max: maxMs <= 0 ? 1 : maxMs,
                    onChanged: maxMs <= 0
                        ? null
                        : (v) =>
                            _c.seek(Duration(milliseconds: v.round())),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(fmtDuration(pos),
                            style: theme.textTheme.bodySmall),
                        Text(fmtDuration(total),
                            style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _mainControls(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(LucideIcons.skipBack),
          tooltip: 'Previous',
          onPressed: _c.previous,
        ),
        IconButton(
          icon: const Icon(LucideIcons.rewind),
          tooltip: 'Back 10s',
          onPressed: _c.rewind,
        ),
        const SizedBox(width: 8),
        StreamBuilder<PlayerState>(
          stream: _c.player.playerStateStream,
          builder: (_, snap) {
            final playing = snap.data?.playing ?? false;
            return IconButton.filled(
              iconSize: 40,
              icon: Icon(playing ? LucideIcons.pause : LucideIcons.play),
              tooltip: playing ? 'Pause' : 'Play',
              onPressed: _c.playPause,
            );
          },
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(LucideIcons.fastForward),
          tooltip: 'Forward 10s',
          onPressed: _c.forward,
        ),
        IconButton(
          icon: const Icon(LucideIcons.skipForward),
          tooltip: 'Next',
          onPressed: _c.next,
        ),
      ],
    );
  }

  Widget _secondaryControls(ThemeData theme) {
    final repeat = _c.repeatMode;
    final repeatActive = repeat != WebRepeatMode.off;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: Icon(LucideIcons.shuffle,
                color: _c.shuffle ? theme.colorScheme.primary : null),
            tooltip: _c.shuffle ? 'Shuffle on' : 'Shuffle off',
            onPressed: _c.toggleShuffle,
          ),
          const SizedBox(width: 32),
          IconButton(
            icon: Icon(
              repeat == WebRepeatMode.one
                  ? LucideIcons.repeat1
                  : LucideIcons.repeat,
              color: repeatActive ? theme.colorScheme.primary : null,
            ),
            tooltip: switch (repeat) {
              WebRepeatMode.off => 'Repeat off',
              WebRepeatMode.one => 'Repeat one',
              WebRepeatMode.all => 'Repeat all',
            },
            onPressed: _c.cycleRepeat,
          ),
        ],
      ),
    );
  }

  Widget _queueView(ThemeData theme) {
    if (_c.queue.isEmpty) return const SizedBox.shrink();
    return ListView.builder(
      itemCount: _c.queue.length,
      itemBuilder: (context, i) {
        final t = _c.queue[i];
        final isCurrent = i == _c.index;
        return ListTile(
          dense: true,
          selected: isCurrent,
          leading: Icon(
            isCurrent ? LucideIcons.volume2 : LucideIcons.music,
            size: 18,
            color: isCurrent ? theme.colorScheme.primary : null,
          ),
          title: Text(t.name,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _c.jumpTo(i),
        );
      },
    );
  }
}

/// Bottom sheet: create a new playlist or add the track to an existing one.
/// Writes go through [WebPlaylistService] (cloud, native-compatible).
class _AddToPlaylistSheet extends StatefulWidget {
  final AudioTrack track;
  const _AddToPlaylistSheet({required this.track});

  @override
  State<_AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends State<_AddToPlaylistSheet> {
  late Future<List<Playlist>> _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = WebFeatures.loadPlaylists();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _createNew() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Create playlist'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Playlist name'),
            onSubmitted: (_) =>
                Navigator.pop(ctx, controller.text.trim()),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;
    setState(() => _busy = true);
    try {
      await WebPlaylistService.instance
          .createPlaylist(name, tracks: [widget.track]);
      if (!mounted) return;
      Navigator.pop(context);
      _snack('Created "$name"');
    } catch (e) {
      setState(() => _busy = false);
      _snack('Could not create playlist: $e');
    }
  }

  Future<void> _addToExisting(Playlist p) async {
    setState(() => _busy = true);
    try {
      final added = await WebPlaylistService.instance
          .addTrackToPlaylist(p.id, widget.track);
      if (!mounted) return;
      Navigator.pop(context);
      _snack(added ? 'Added to "${p.name}"' : 'Already in "${p.name}"');
    } catch (e) {
      setState(() => _busy = false);
      _snack('Could not add to playlist: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(LucideIcons.plus),
            title: const Text('Create new playlist'),
            onTap: _createNew,
          ),
          const Divider(height: 1),
          Flexible(
            child: FutureBuilder<List<Playlist>>(
              future: _future,
              builder: (_, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final playlists = snap.data ?? const <Playlist>[];
                if (playlists.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No playlists yet'),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: playlists.length,
                  itemBuilder: (_, i) {
                    final p = playlists[i];
                    return ListTile(
                      leading: const Icon(LucideIcons.listMusic),
                      title: Text(p.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${p.tracks.length} tracks'),
                      onTap: () => _addToExisting(p),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
