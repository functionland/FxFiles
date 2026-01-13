import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/audio_player_service.dart';
import 'package:fula_files/core/models/playlist.dart';
import 'package:fula_files/app/router.dart';

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<AudioTrack?>(
      stream: AudioPlayerService.instance.currentTrackStream,
      builder: (context, trackSnapshot) {
        final track = trackSnapshot.data;
        if (track == null) return const SizedBox.shrink();

        return _MiniPlayerContent(track: track, ref: ref);
      },
    );
  }
}

class _MiniPlayerContent extends StatelessWidget {
  final AudioTrack track;
  final WidgetRef ref;

  const _MiniPlayerContent({required this.track, required this.ref});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = AudioPlayerService.instance;

    return GestureDetector(
      onTap: () {
        // Use router from provider since MiniPlayer is outside GoRouter's widget tree
        final router = ref.read(routerProvider);
        router.push('/viewer/audio', extra: track.path);
      },
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Progress bar
            StreamBuilder<Duration>(
              stream: service.positionStream,
              builder: (context, positionSnapshot) {
                return StreamBuilder<Duration?>(
                  stream: service.durationStream,
                  builder: (context, durationSnapshot) {
                    final position = positionSnapshot.data ?? Duration.zero;
                    final duration = durationSnapshot.data ?? Duration.zero;
                    final progress = duration.inMilliseconds > 0
                        ? position.inMilliseconds / duration.inMilliseconds
                        : 0.0;

                    return LinearProgressIndicator(
                      value: progress,
                      minHeight: 2,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
                    );
                  },
                );
              },
            ),
            // Player content
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  // Album art
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      LucideIcons.music,
                      color: theme.colorScheme.onPrimaryContainer,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Track info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          track.name,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (track.artist != null)
                          Text(
                            track.artist!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  // Controls
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Previous
                      IconButton(
                        icon: const Icon(LucideIcons.skipBack, size: 20),
                        onPressed: () => service.skipToPrevious(),
                        padding: const EdgeInsets.all(8),
                        constraints: const BoxConstraints(),
                      ),
                      // Play/Pause
                      StreamBuilder<bool>(
                        stream: service.isPlayingStream,
                        builder: (context, snapshot) {
                          final isPlaying = snapshot.data ?? false;
                          return IconButton(
                            icon: Icon(
                              isPlaying ? LucideIcons.pause : LucideIcons.play,
                              size: 24,
                            ),
                            onPressed: () => service.playPause(),
                            padding: const EdgeInsets.all(8),
                            constraints: const BoxConstraints(),
                          );
                        },
                      ),
                      // Next
                      IconButton(
                        icon: const Icon(LucideIcons.skipForward, size: 20),
                        onPressed: () => service.skipToNext(),
                        padding: const EdgeInsets.all(8),
                        constraints: const BoxConstraints(),
                      ),
                      // Close
                      IconButton(
                        icon: const Icon(LucideIcons.x, size: 20),
                        onPressed: () => service.stop(),
                        padding: const EdgeInsets.all(8),
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Wrapper widget that includes mini player at the bottom
class MiniPlayerScaffold extends StatelessWidget {
  final Widget child;
  final Widget? bottomNavigationBar;

  const MiniPlayerScaffold({
    super.key,
    required this.child,
    this.bottomNavigationBar,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: child),
        const MiniPlayer(),
        if (bottomNavigationBar != null) bottomNavigationBar!,
      ],
    );
  }
}
