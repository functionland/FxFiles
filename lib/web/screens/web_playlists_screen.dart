import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:fula_files/core/models/playlist.dart';
import 'package:fula_files/web/services/web_audio_controller.dart';
import 'package:fula_files/web/services/web_features.dart';
import 'package:fula_files/web/widgets/web_audio_player.dart';

/// Mirror of lib/features/audio/screens/playlists_screen.dart
/// (view-only): 64x64 list-music cover, name + "N tracks · duration"
/// rows, Play button, native empty-state copy. Creation/reorder stay
/// native.
class WebPlaylistsScreen extends StatefulWidget {
  const WebPlaylistsScreen({super.key});

  @override
  State<WebPlaylistsScreen> createState() => _WebPlaylistsScreenState();
}

class _WebPlaylistsScreenState extends State<WebPlaylistsScreen> {
  List<Playlist>? _playlists;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _playlists = null;
      _error = null;
    });
    try {
      final p = await WebFeatures.loadPlaylists();
      setState(() => _playlists = p);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: const Text('Playlists'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Could not load playlists.\n$_error'))
          : _playlists == null
              ? const Center(child: CircularProgressIndicator())
              : _playlists!.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.queue_music, size: 64),
                          const SizedBox(height: 12),
                          Text('No playlists yet',
                              style: theme.textTheme.titleMedium),
                          const SizedBox(height: 6),
                          Text('Create your first playlist in the FxFiles app',
                              style: theme.textTheme.bodySmall),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _playlists!.length,
                      itemBuilder: (ctx, i) {
                        final p = _playlists![i];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            leading: Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(Icons.queue_music,
                                  size: 28,
                                  color: theme
                                      .colorScheme.onPrimaryContainer),
                            ),
                            title: Text(
                              p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text(
                              '${p.tracks.length} tracks · ${_fmtTotal(p)}',
                              style: theme.textTheme.bodySmall,
                            ),
                            trailing: FilledButton.icon(
                              onPressed: () =>
                                  context.go('/playlist/${p.id}'),
                              icon: const Icon(Icons.play_arrow, size: 18),
                              label: const Text('Play'),
                            ),
                            onTap: () => context.go('/playlist/${p.id}'),
                          ),
                        );
                      },
                    ),
    );
  }

  String _fmtTotal(Playlist p) {
    final total = p.tracks.fold<int>(0, (s, t) => s + t.durationMs);
    final d = Duration(milliseconds: total);
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inMinutes}m';
  }
}

/// Mirror of lib/features/audio/screens/playlist_detail_screen.dart
/// (view-only): stats bar with Play All, numbered track rows with
/// name + artist. Tracks play through the web audio player; reorder /
/// edit stays native.
class WebPlaylistDetailScreen extends StatefulWidget {
  final String playlistId;
  const WebPlaylistDetailScreen({super.key, required this.playlistId});

  @override
  State<WebPlaylistDetailScreen> createState() =>
      _WebPlaylistDetailScreenState();
}

class _WebPlaylistDetailScreenState extends State<WebPlaylistDetailScreen> {
  Playlist? _playlist;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final all = await WebFeatures.loadPlaylists();
      setState(() => _playlist =
          all.where((p) => p.id == widget.playlistId).firstOrNull);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  /// Play the playlist through the full-screen web audio player (#21), with
  /// the whole playlist as the queue starting at [track]. Tracks download on
  /// demand inside the player.
  void _play(AudioTrack track) {
    final p = _playlist;
    if (p == null || p.tracks.isEmpty) return;
    var start = p.tracks.indexWhere((t) => t.path == track.path);
    if (start < 0) start = 0;
    showDialog<void>(
      context: context,
      useSafeArea: false,
      builder: (ctx) => Dialog.fullscreen(
        child: WebAudioPlayer(
          queue: [
            for (final t in p.tracks)
              WebAudioTrack(
                name: t.name,
                mime: 'audio/mpeg',
                cloudKey: t.path,
                download: () => WebFeatures.downloadTrack(t),
              ),
          ],
          startIndex: start,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _playlist;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/playlists'),
        ),
        title: Text(p?.name ?? 'Playlist'),
      ),
      body: _error != null
          ? Center(child: Text('Could not load playlist.\n$_error'))
          : p == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Text(
                            '${p.tracks.length} tracks',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const Spacer(),
                          FilledButton.icon(
                            onPressed: p.tracks.isEmpty
                                ? null
                                : () => _play(p.tracks.first),
                            icon: const Icon(Icons.play_arrow, size: 18),
                            label: const Text('Play All'),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: p.tracks.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.music_note, size: 64),
                                  const SizedBox(height: 12),
                                  Text('No tracks yet',
                                      style: theme.textTheme.titleMedium),
                                  const SizedBox(height: 6),
                                  Text(
                                      'Add tracks from the audio player '
                                      'in the FxFiles app',
                                      style: theme.textTheme.bodySmall),
                                ],
                              ),
                            )
                          : ListView.builder(
                              itemCount: p.tracks.length,
                              itemBuilder: (ctx, i) {
                                final t = p.tracks[i];
                                return ListTile(
                                  leading: Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme
                                          .surfaceContainerHighest,
                                      borderRadius:
                                          BorderRadius.circular(8),
                                    ),
                                    child: Center(child: Text('${i + 1}')),
                                  ),
                                  title: Text(t.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  subtitle: Text(
                                    t.artist ??
                                        t.path
                                            .split('.')
                                            .last
                                            .toUpperCase(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  onTap: () => _play(t),
                                );
                              },
                            ),
                    ),
                  ],
                ),
    );
  }
}
