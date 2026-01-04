import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:fula_files/core/services/audio_player_service.dart';
import 'package:fula_files/core/services/playlist_service.dart';
import 'package:fula_files/core/models/playlist.dart';
import 'package:fula_files/shared/widgets/audio_visualizer.dart';
import 'package:fula_files/shared/widgets/audio_equalizer.dart';

class AudioPlayerScreen extends StatefulWidget {
  final String filePath;
  final List<String>? playlist;
  final String? playlistName;

  const AudioPlayerScreen({
    super.key,
    required this.filePath,
    this.playlist,
    this.playlistName,
  });

  @override
  State<AudioPlayerScreen> createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends State<AudioPlayerScreen> {
  bool _isLoading = true;
  String? _error;
  bool _showQueue = false;
  StreamSubscription<NotificationPermissionStatus>? _permissionSubscription;
  bool _permissionDialogShown = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
    _setupPermissionListener();
  }

  @override
  void dispose() {
    _permissionSubscription?.cancel();
    super.dispose();
  }

  void _setupPermissionListener() {
    final service = AudioPlayerService.instance;
    _permissionSubscription = service.notificationPermissionStream.listen((status) {
      if (status == NotificationPermissionStatus.permanentlyDenied && !_permissionDialogShown) {
        _permissionDialogShown = true;
        // Delay slightly to ensure the screen is fully built
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            _showNotificationPermissionDialog();
          }
        });
      }
    });
  }

  void _showNotificationPermissionDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(LucideIcons.bellOff, size: 48, color: Colors.orange),
        title: const Text('Notifications Disabled'),
        content: const Text(
          'To see playback controls in the status bar and on the lock screen, '
          'please enable notifications for FxFiles in Settings.\n\n'
          'Audio will continue to play in the background, but you won\'t see '
          'the media player controls outside the app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Not Now'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              AudioPlayerService.instance.openNotificationSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _initPlayer() async {
    try {
      final service = AudioPlayerService.instance;

      // Initialize service (should be quick if already initialized)
      await service.init();

      // Set loading to false immediately - the player UI uses StreamBuilders
      // so it will update automatically with track info
      if (mounted) {
        setState(() => _isLoading = false);
      }

      // Check if we should preserve the existing playlist
      // This prevents overriding the playlist when navigating from PlaylistDetailScreen
      final currentTrack = service.currentTrack;
      final existingPlaylist = service.playlist;

      // If this file is already in the current playlist, don't reinitialize
      // This allows next/previous to work correctly with playlists
      if (currentTrack != null && existingPlaylist.isNotEmpty) {
        final isFileInPlaylist = existingPlaylist.any((t) => t.path == widget.filePath);
        if (isFileInPlaylist) {
          // File is in the current playlist, just switch to it if needed
          if (currentTrack.path != widget.filePath) {
            // Switch to the requested track within the existing playlist
            final targetIndex = existingPlaylist.indexWhere((t) => t.path == widget.filePath);
            if (targetIndex >= 0) {
              service.skipToIndex(targetIndex);
            }
          }
          return;
        }
      }

      // Create track from file path
      final track = audioTrackFromPath(widget.filePath);

      // If playlist is provided, use it
      if (widget.playlist != null && widget.playlist!.isNotEmpty) {
        final tracks = widget.playlist!.map((path) => audioTrackFromPath(path)).toList();
        service.playTrack(track, playlist: tracks, playlistName: widget.playlistName);
      } else {
        // Start playing the single track immediately
        service.playTrack(track);

        // Then scan for other audio files in background and update playlist
        _loadDirectoryPlaylist(track);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Failed to load audio: $e';
        });
      }
    }
  }

  /// Load directory playlist in background (doesn't block UI)
  void _loadDirectoryPlaylist(AudioTrack currentTrack) async {
    try {
      final dir = Directory(p.dirname(widget.filePath));
      final audioFiles = await _getAudioFilesInDirectory(dir);

      if (audioFiles.length > 1 && mounted) {
        final tracks = audioFiles.map((path) => audioTrackFromPath(path)).toList();
        final service = AudioPlayerService.instance;
        // Update playlist while keeping current track playing
        await service.playTrack(currentTrack, playlist: tracks, playlistName: p.basename(dir.path));
      }
    } catch (e) {
      debugPrint('Failed to load directory playlist: $e');
    }
  }

  Future<List<String>> _getAudioFilesInDirectory(Directory dir) async {
    final audioExtensions = ['mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a', 'wma'];
    final files = <String>[];

    try {
      await for (final entity in dir.list()) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
          if (audioExtensions.contains(ext)) {
            files.add(entity.path);
          }
        }
      }
      files.sort();
    } catch (e) {
      // Ignore errors
    }

    return files;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = AudioPlayerService.instance;

    return Scaffold(
      appBar: AppBar(
        title: StreamBuilder<String?>(
          stream: service.playlistNameStream,
          builder: (context, snapshot) {
            final playlistName = snapshot.data;
            return Text(
              playlistName ?? 'Now Playing',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          },
        ),
        actions: [
          IconButton(
            icon: Icon(_showQueue ? LucideIcons.x : LucideIcons.listMusic),
            onPressed: () => setState(() => _showQueue = !_showQueue),
            tooltip: 'Queue',
          ),
          const EqualizerButton(),
          PopupMenuButton<String>(
            icon: const Icon(LucideIcons.moreVertical),
            onSelected: (value) => _handleMenuAction(value),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'add_to_playlist',
                child: ListTile(
                  leading: Icon(LucideIcons.listPlus),
                  title: Text('Add to playlist'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'save_as_playlist',
                child: ListTile(
                  leading: Icon(LucideIcons.save),
                  title: Text('Save queue as playlist'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(LucideIcons.alertCircle, size: 48, color: Colors.red),
                      const SizedBox(height: 16),
                      Text(_error!, textAlign: TextAlign.center),
                    ],
                  ),
                )
              : _showQueue
                  ? _buildQueueView()
                  : _buildPlayerView(theme, service),
    );
  }

  Widget _buildPlayerView(ThemeData theme, AudioPlayerService service) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 16),
            // Album art with visualization
            Stack(
              alignment: Alignment.center,
              children: [
                // Circular visualizer behind album art
                CircularAudioVisualizer(
                  size: 280,
                  barCount: 64,
                  color: theme.colorScheme.primary.withValues(alpha: 0.5),
                ),
                // Album art
                Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Icon(
                    LucideIcons.music,
                    size: 80,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            // Waveform visualization
            const WaveformVisualizer(height: 50),
            const SizedBox(height: 24),
            // Track info
            StreamBuilder<AudioTrack?>(
              stream: service.currentTrackStream,
              builder: (context, snapshot) {
                final track = snapshot.data;
                return Column(
                  children: [
                    Text(
                      track?.name ?? 'Unknown',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      track?.artist ?? 'Unknown Artist',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 24),
            // Progress bar
            _buildProgressBar(theme, service),
            const SizedBox(height: 24),
            // Controls
            _buildControls(theme, service),
            const SizedBox(height: 16),
            // Secondary controls (shuffle, repeat)
            _buildSecondaryControls(theme, service),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressBar(ThemeData theme, AudioPlayerService service) {
    return StreamBuilder<Duration>(
      stream: service.positionStream,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration?>(
          stream: service.durationStream,
          builder: (context, durationSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final duration = durationSnapshot.data ?? Duration.zero;

            return Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  ),
                  child: Slider(
                    value: duration.inMilliseconds > 0
                        ? position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble()
                        : 0,
                    max: duration.inMilliseconds.toDouble(),
                    onChanged: (value) {
                      service.seek(Duration(milliseconds: value.toInt()));
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_formatDuration(position), style: theme.textTheme.bodySmall),
                      Text(_formatDuration(duration), style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildControls(ThemeData theme, AudioPlayerService service) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Previous
        IconButton(
          iconSize: 36,
          icon: const Icon(LucideIcons.skipBack),
          onPressed: () => service.skipToPrevious(),
        ),
        const SizedBox(width: 8),
        // Rewind 10s
        IconButton(
          iconSize: 28,
          icon: const Icon(LucideIcons.rewind),
          onPressed: () => service.seekBackward(),
        ),
        const SizedBox(width: 8),
        // Play/Pause
        StreamBuilder<bool>(
          stream: service.isPlayingStream,
          builder: (context, snapshot) {
            final isPlaying = snapshot.data ?? false;
            return StreamBuilder<bool>(
              stream: service.bufferingStream,
              builder: (context, bufferingSnapshot) {
                final isBuffering = bufferingSnapshot.data ?? false;

                if (isBuffering) {
                  return Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: SizedBox(
                        width: 32,
                        height: 32,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 3,
                        ),
                      ),
                    ),
                  );
                }

                return GestureDetector(
                  onTap: () => service.playPause(),
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isPlaying ? LucideIcons.pause : LucideIcons.play,
                      size: 36,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                );
              },
            );
          },
        ),
        const SizedBox(width: 8),
        // Forward 10s
        IconButton(
          iconSize: 28,
          icon: const Icon(LucideIcons.fastForward),
          onPressed: () => service.seekForward(),
        ),
        const SizedBox(width: 8),
        // Next
        IconButton(
          iconSize: 36,
          icon: const Icon(LucideIcons.skipForward),
          onPressed: () => service.skipToNext(),
        ),
      ],
    );
  }

  Widget _buildSecondaryControls(ThemeData theme, AudioPlayerService service) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Shuffle
        StreamBuilder<bool>(
          stream: service.shuffleModeStream,
          builder: (context, snapshot) {
            final shuffleEnabled = snapshot.data ?? false;
            return IconButton(
              icon: Icon(
                LucideIcons.shuffle,
                color: shuffleEnabled ? theme.colorScheme.primary : null,
              ),
              onPressed: () => service.toggleShuffle(),
              tooltip: 'Shuffle',
            );
          },
        ),
        const SizedBox(width: 24),
        // Repeat
        StreamBuilder<RepeatMode>(
          stream: service.repeatModeStream,
          builder: (context, snapshot) {
            final repeatMode = snapshot.data ?? RepeatMode.off;
            IconData icon;
            Color? color;

            switch (repeatMode) {
              case RepeatMode.off:
                icon = LucideIcons.repeat;
                color = null;
                break;
              case RepeatMode.one:
                icon = LucideIcons.repeat1;
                color = theme.colorScheme.primary;
                break;
              case RepeatMode.all:
                icon = LucideIcons.repeat;
                color = theme.colorScheme.primary;
                break;
            }

            return IconButton(
              icon: Icon(icon, color: color),
              onPressed: () => service.toggleRepeatMode(),
              tooltip: _getRepeatTooltip(repeatMode),
            );
          },
        ),
      ],
    );
  }

  Widget _buildQueueView() {
    final service = AudioPlayerService.instance;
    final theme = Theme.of(context);

    return StreamBuilder<List<AudioTrack>>(
      stream: service.playlistStream,
      builder: (context, snapshot) {
        final playlist = snapshot.data ?? [];

        if (playlist.isEmpty) {
          return const Center(child: Text('Queue is empty'));
        }

        return StreamBuilder<int>(
          stream: service.currentIndexStream,
          builder: (context, indexSnapshot) {
            final currentIndex = indexSnapshot.data ?? -1;

            return ReorderableListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: playlist.length,
              onReorder: (oldIndex, newIndex) {
                service.reorderQueue(oldIndex, newIndex);
              },
              itemBuilder: (context, index) {
                final track = playlist[index];
                final isPlaying = index == currentIndex;

                return Card(
                  key: ValueKey(track.path),
                  color: isPlaying
                      ? theme.colorScheme.primaryContainer
                      : null,
                  child: ListTile(
                    leading: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: isPlaying
                          ? const AudioVisualizer(
                              barCount: 3,
                              barWidth: 4,
                              maxHeight: 24,
                            )
                          : Icon(
                              LucideIcons.music,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                    ),
                    title: Text(
                      track.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: isPlaying
                          ? TextStyle(
                              color: theme.colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.w600,
                            )
                          : null,
                    ),
                    subtitle: track.artist != null
                        ? Text(
                            track.artist!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(LucideIcons.x, size: 20),
                          onPressed: () => service.removeFromQueue(index),
                        ),
                        ReorderableDragStartListener(
                          index: index,
                          child: const Icon(LucideIcons.gripVertical, size: 20),
                        ),
                      ],
                    ),
                    onTap: () => service.skipToIndex(index),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _handleMenuAction(String action) async {
    debugPrint('_handleMenuAction: $action');

    switch (action) {
      case 'add_to_playlist':
        _showAddToPlaylistDialog();
        break;
      case 'save_as_playlist':
        _showSaveQueueAsPlaylistDialog();
        break;
    }
  }

  void _showAddToPlaylistDialog() async {
    debugPrint('_showAddToPlaylistDialog called');
    final currentTrack = AudioPlayerService.instance.currentTrack;
    debugPrint('currentTrack: ${currentTrack?.name}');
    if (currentTrack == null) {
      debugPrint('No current track, returning');
      return;
    }

    await PlaylistService.instance.init();
    final playlists = PlaylistService.instance.getAllPlaylists();
    debugPrint('Found ${playlists.length} playlists');

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(LucideIcons.plus),
            title: const Text('Create new playlist'),
            onTap: () {
              Navigator.pop(context);
              _showCreatePlaylistDialog(initialTrack: currentTrack);
            },
          ),
          const Divider(),
          if (playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No playlists yet'),
            )
          else
            ...playlists.map((playlist) => ListTile(
              leading: const Icon(LucideIcons.listMusic),
              title: Text(playlist.name),
              subtitle: Text('${playlist.trackCount} tracks'),
              onTap: () async {
                await PlaylistService.instance.addTrackToPlaylist(
                  playlist.id,
                  currentTrack,
                );
                if (mounted) {
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

  void _showSaveQueueAsPlaylistDialog() {
    debugPrint('_showSaveQueueAsPlaylistDialog called');
    final tracks = AudioPlayerService.instance.playlist;
    debugPrint('Queue has ${tracks.length} tracks');
    if (tracks.isEmpty) {
      debugPrint('Queue is empty, returning');
      return;
    }

    _showCreatePlaylistDialog(initialTracks: tracks);
  }

  void _showCreatePlaylistDialog({
    AudioTrack? initialTrack,
    List<AudioTrack>? initialTracks,
  }) {
    debugPrint('_showCreatePlaylistDialog called');
    debugPrint('initialTrack: ${initialTrack?.name}, initialTracks count: ${initialTracks?.length}');
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
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              debugPrint('Create button pressed, name: $name');
              if (name.isEmpty) {
                debugPrint('Name is empty, returning');
                return;
              }

              final tracks = initialTracks ?? (initialTrack != null ? [initialTrack] : <AudioTrack>[]);
              debugPrint('Creating playlist with ${tracks.length} tracks');
              await PlaylistService.instance.createPlaylist(name, tracks: tracks);
              debugPrint('Playlist created');

              if (mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Created playlist: $name')),
                );
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return '--:--';
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      final hours = duration.inHours.toString();
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  String _getRepeatTooltip(RepeatMode mode) {
    switch (mode) {
      case RepeatMode.off:
        return 'Repeat off';
      case RepeatMode.one:
        return 'Repeat one';
      case RepeatMode.all:
        return 'Repeat all';
    }
  }
}
