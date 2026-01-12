import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:fula_files/core/models/playlist.dart';
import 'package:fula_files/core/services/playlist_service.dart';
import 'package:fula_files/core/services/audio_player_service.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final String playlistId;

  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  Playlist? _playlist;
  bool _isLoading = true;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _loadPlaylist();
  }

  Future<void> _loadPlaylist() async {
    await PlaylistService.instance.init();
    setState(() {
      _playlist = PlaylistService.instance.getPlaylist(widget.playlistId);
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_playlist == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Playlist not found')),
      );
    }

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // Header
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            actions: [
              IconButton(
                icon: Icon(_isEditing ? LucideIcons.check : LucideIcons.edit),
                onPressed: () => setState(() => _isEditing = !_isEditing),
                tooltip: _isEditing ? 'Done' : 'Edit',
              ),
              PopupMenuButton<String>(
                onSelected: _handleMenuAction,
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'shuffle_play',
                    child: ListTile(
                      leading: Icon(LucideIcons.shuffle),
                      title: Text('Shuffle play'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'clear',
                    child: ListTile(
                      leading: Icon(LucideIcons.trash2),
                      title: Text('Clear playlist'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                _playlist!.name,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
              ),
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      theme.colorScheme.primary,
                      theme.colorScheme.primary.withValues(alpha: 0.7),
                    ],
                  ),
                ),
                child: Center(
                  child: Icon(
                    LucideIcons.listMusic,
                    size: 80,
                    color: theme.colorScheme.onPrimary.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
          ),
          // Stats bar
          SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text(
                    '${_playlist!.trackCount} tracks',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    _formatDuration(_playlist!.totalDuration),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  // Play all button
                  FilledButton.icon(
                    onPressed: _playlist!.tracks.isNotEmpty ? _playAll : null,
                    icon: const Icon(LucideIcons.play, size: 18),
                    label: const Text('Play All'),
                  ),
                ],
              ),
            ),
          ),
          // Track list
          if (_playlist!.tracks.isEmpty)
            SliverFillRemaining(
              child: _buildEmptyState(theme),
            )
          else if (_isEditing)
            _buildEditableTrackList()
          else
            _buildTrackList(theme),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.music,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No tracks yet',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add tracks from the audio player',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackList(ThemeData theme) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final track = _playlist!.tracks[index];
          return _TrackListItem(
            track: track,
            index: index,
            onTap: () => _playFromIndex(index),
            onRemove: () => _removeTrack(index),
          );
        },
        childCount: _playlist!.tracks.length,
      ),
    );
  }

  Widget _buildEditableTrackList() {
    return SliverReorderableList(
      itemBuilder: (context, index) {
        final track = _playlist!.tracks[index];
        return ReorderableDragStartListener(
          key: ValueKey(track.path),
          index: index,
          child: _TrackListItem(
            track: track,
            index: index,
            isEditing: true,
            onTap: () => _playFromIndex(index),
            onRemove: () => _removeTrack(index),
          ),
        );
      },
      itemCount: _playlist!.tracks.length,
      onReorder: _reorderTrack,
    );
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'shuffle_play':
        _shufflePlay();
        break;
      case 'clear':
        _clearPlaylist();
        break;
    }
  }

  Future<void> _playAll() async {
    if (_playlist!.tracks.isEmpty) return;

    await AudioPlayerService.instance.playPlaylist(_playlist!);

    if (mounted) {
      context.push('/viewer/audio', extra: _playlist!.tracks.first.path);
    }
  }

  Future<void> _playFromIndex(int index) async {
    await AudioPlayerService.instance.playPlaylist(_playlist!, startIndex: index);

    if (mounted) {
      context.push('/viewer/audio', extra: _playlist!.tracks[index].path);
    }
  }

  Future<void> _shufflePlay() async {
    if (_playlist!.tracks.isEmpty) return;

    AudioPlayerService.instance.setRepeatMode(RepeatMode.off);
    // Enable shuffle before playing
    if (!AudioPlayerService.instance.shuffleMode) {
      AudioPlayerService.instance.toggleShuffle();
    }

    await AudioPlayerService.instance.playPlaylist(_playlist!);

    if (mounted) {
      context.push('/viewer/audio', extra: _playlist!.tracks.first.path);
    }
  }

  Future<void> _removeTrack(int index) async {
    await PlaylistService.instance.removeTrackFromPlaylist(_playlist!.id, index);
    await _loadPlaylist();
  }

  Future<void> _reorderTrack(int oldIndex, int newIndex) async {
    await PlaylistService.instance.reorderTrackInPlaylist(
      _playlist!.id,
      oldIndex,
      newIndex,
    );
    await _loadPlaylist();
  }

  Future<void> _clearPlaylist() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Playlist'),
        content: const Text('Remove all tracks from this playlist?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _playlist!.clearTracks();
      await PlaylistService.instance.updatePlaylist(_playlist!);
      await _loadPlaylist();
    }
  }

  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    }
    return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
  }
}

class _TrackListItem extends StatelessWidget {
  final AudioTrack track;
  final int index;
  final bool isEditing;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _TrackListItem({
    required this.track,
    required this.index,
    this.isEditing = false,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      child: ListTile(
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              '${index + 1}',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        title: Text(
          track.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          track.artist ?? p.extension(track.path).toUpperCase().replaceFirst('.', ''),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isEditing) ...[
              IconButton(
                icon: const Icon(LucideIcons.trash2, size: 20),
                tooltip: 'Remove track',
                onPressed: onRemove,
              ),
              const Icon(LucideIcons.gripVertical, size: 20),
            ] else
              IconButton(
                icon: const Icon(LucideIcons.moreVertical, size: 20),
                tooltip: 'More options',
                onPressed: () => _showTrackMenu(context),
              ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }

  void _showTrackMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(LucideIcons.play),
            title: const Text('Play'),
            onTap: () {
              Navigator.pop(context);
              onTap();
            },
          ),
          ListTile(
            leading: const Icon(LucideIcons.listPlus),
            title: const Text('Add to another playlist'),
            onTap: () async {
              Navigator.pop(context);
              await _showAddToPlaylistDialog(context);
            },
          ),
          ListTile(
            leading: const Icon(LucideIcons.trash2, color: Colors.red),
            title: const Text('Remove from playlist', style: TextStyle(color: Colors.red)),
            onTap: () {
              Navigator.pop(context);
              onRemove();
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Future<void> _showAddToPlaylistDialog(BuildContext context) async {
    await PlaylistService.instance.init();
    final playlists = PlaylistService.instance.getAllPlaylists();

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Add to playlist',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
            ),
          ),
          const Divider(),
          if (playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No other playlists available'),
            )
          else
            ...playlists.map((playlist) => ListTile(
              leading: const Icon(LucideIcons.listMusic),
              title: Text(playlist.name),
              subtitle: Text('${playlist.trackCount} tracks'),
              onTap: () async {
                await PlaylistService.instance.addTrackToPlaylist(
                  playlist.id,
                  track,
                );
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Added to ${playlist.name}')),
                  );
                }
              },
            )),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
