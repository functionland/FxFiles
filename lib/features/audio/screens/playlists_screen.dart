import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/playlist.dart';
import 'package:fula_files/core/services/playlist_service.dart';
import 'package:fula_files/core/services/audio_player_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/shared/utils/error_messages.dart';
import 'package:fula_files/shared/widgets/skeleton_loaders.dart';

class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  List<Playlist> _playlists = [];
  bool _isLoading = true;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    await PlaylistService.instance.init();
    var playlists = PlaylistService.instance.getAllPlaylists();

    // Auto-restore from cloud if local is empty and cloud is configured
    if (playlists.isEmpty && FulaApiService.instance.isConfigured) {
      try {
        await PlaylistService.instance.restorePlaylistsFromCloud();
        playlists = PlaylistService.instance.getAllPlaylists();
      } catch (e) {
        debugPrint('Auto-restore playlists from cloud failed: $e');
      }
    }

    setState(() {
      _playlists = playlists;
      _isLoading = false;
    });
  }

  Future<void> _syncPlaylists() async {
    if (!FulaApiService.instance.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cloud storage not configured')),
      );
      return;
    }

    setState(() => _isSyncing = true);

    try {
      await PlaylistService.instance.restorePlaylistsFromCloud();
      await PlaylistService.instance.syncAllPlaylistsToCloud();
      await _loadPlaylists();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Playlists synced')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forSync(e))),
        );
      }
    } finally {
      setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlists'),
        actions: [
          if (_isSyncing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(LucideIcons.refreshCw),
              onPressed: _syncPlaylists,
              tooltip: 'Sync with cloud',
            ),
        ],
      ),
      body: _isLoading
          ? const PlaylistListSkeleton(itemCount: 5)
          : _playlists.isEmpty
              ? _buildEmptyState(theme)
              : _buildPlaylistList(theme),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreatePlaylistDialog(),
        child: const Icon(LucideIcons.plus),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.listMusic,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No playlists yet',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create your first playlist',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistList(ThemeData theme) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _playlists.length,
      itemBuilder: (context, index) {
        final playlist = _playlists[index];
        return _PlaylistCard(
          playlist: playlist,
          onTap: () => _openPlaylist(playlist),
          onPlay: () => _playPlaylist(playlist),
          onEdit: () => _showRenameDialog(playlist),
          onDelete: () => _deletePlaylist(playlist),
          onSync: () => _syncPlaylist(playlist),
        );
      },
    );
  }

  void _openPlaylist(Playlist playlist) {
    context.push('/playlist/${playlist.id}');
  }

  Future<void> _playPlaylist(Playlist playlist) async {
    if (playlist.tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Playlist is empty')),
      );
      return;
    }

    await AudioPlayerService.instance.playPlaylist(playlist);

    if (mounted) {
      context.push('/viewer/audio', extra: playlist.tracks.first.path);
    }
  }

  void _showCreatePlaylistDialog() {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Playlist'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Playlist name',
            hintText: 'Enter playlist name',
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;

              await PlaylistService.instance.createPlaylist(name);
              await _loadPlaylists();

              if (mounted) {
                Navigator.pop(context);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(Playlist playlist) {
    final controller = TextEditingController(text: playlist.name);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Playlist'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Playlist name',
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;

              await PlaylistService.instance.renamePlaylist(playlist.id, name);
              await _loadPlaylists();

              if (mounted) {
                Navigator.pop(context);
              }
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Playlist'),
        content: Text('Are you sure you want to delete "${playlist.name}"?'),
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await PlaylistService.instance.deletePlaylist(playlist.id);
      await _loadPlaylists();
    }
  }

  Future<void> _syncPlaylist(Playlist playlist) async {
    if (!FulaApiService.instance.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cloud storage not configured')),
      );
      return;
    }

    try {
      await PlaylistService.instance.syncPlaylistToCloud(playlist.id);
      await _loadPlaylists();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${playlist.name} synced to cloud')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forSync(e))),
        );
      }
    }
  }
}

class _PlaylistCard extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onSync;

  const _PlaylistCard({
    required this.playlist,
    required this.onTap,
    required this.onPlay,
    required this.onEdit,
    required this.onDelete,
    required this.onSync,
  });

  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    }
    return '${duration.inMinutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Playlist cover
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Stack(
                  children: [
                    Center(
                      child: Icon(
                        LucideIcons.listMusic,
                        color: theme.colorScheme.onPrimaryContainer,
                        size: 28,
                      ),
                    ),
                    if (playlist.isSyncedToCloud)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            LucideIcons.cloud,
                            size: 12,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Playlist info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${playlist.trackCount} tracks • ${_formatDuration(playlist.totalDuration)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // Play button
              IconButton(
                icon: const Icon(LucideIcons.play),
                onPressed: onPlay,
                style: IconButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                ),
              ),
              // Menu
              PopupMenuButton<String>(
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      onEdit();
                      break;
                    case 'sync':
                      onSync();
                      break;
                    case 'delete':
                      onDelete();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      leading: Icon(LucideIcons.edit),
                      title: Text('Rename'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'sync',
                    child: ListTile(
                      leading: Icon(LucideIcons.cloud),
                      title: Text('Sync to cloud'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: Icon(LucideIcons.trash2, color: Colors.red),
                      title: Text('Delete', style: TextStyle(color: Colors.red)),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
