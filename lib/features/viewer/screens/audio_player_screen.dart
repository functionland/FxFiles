import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;

class AudioPlayerScreen extends StatefulWidget {
  final String filePath;

  const AudioPlayerScreen({super.key, required this.filePath});

  @override
  State<AudioPlayerScreen> createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends State<AudioPlayerScreen> {
  late AudioPlayer _player;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      await _player.setFilePath(widget.filePath);
      setState(() => _isLoading = false);
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = 'Failed to load audio: $e';
      });
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final fileName = p.basename(widget.filePath);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
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
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const Spacer(),
                      // Album art placeholder
                      Container(
                        width: 250,
                        height: 250,
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
                          size: 100,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 48),
                      // Title
                      Text(
                        p.basenameWithoutExtension(widget.filePath),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        p.extension(widget.filePath).toUpperCase().replaceFirst('.', ''),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 32),
                      // Progress bar
                      StreamBuilder<Duration?>(
                        stream: _player.positionStream,
                        builder: (context, positionSnapshot) {
                          final position = positionSnapshot.data ?? Duration.zero;
                          final duration = _player.duration ?? Duration.zero;
                          
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
                                    _player.seek(Duration(milliseconds: value.toInt()));
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
                      ),
                      const SizedBox(height: 24),
                      // Controls
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Rewind 10s
                          IconButton(
                            iconSize: 36,
                            icon: const Icon(LucideIcons.rewind),
                            onPressed: () {
                              final newPos = _player.position - const Duration(seconds: 10);
                              _player.seek(newPos < Duration.zero ? Duration.zero : newPos);
                            },
                          ),
                          const SizedBox(width: 16),
                          // Play/Pause
                          StreamBuilder<PlayerState>(
                            stream: _player.playerStateStream,
                            builder: (context, snapshot) {
                              final playerState = snapshot.data;
                              final playing = playerState?.playing ?? false;
                              final processingState = playerState?.processingState;

                              if (processingState == ProcessingState.loading ||
                                  processingState == ProcessingState.buffering) {
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
                                onTap: () {
                                  if (playing) {
                                    _player.pause();
                                  } else {
                                    if (processingState == ProcessingState.completed) {
                                      _player.seek(Duration.zero);
                                    }
                                    _player.play();
                                  }
                                },
                                child: Container(
                                  width: 72,
                                  height: 72,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    playing ? LucideIcons.pause : LucideIcons.play,
                                    size: 36,
                                    color: theme.colorScheme.onPrimary,
                                  ),
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 16),
                          // Forward 10s
                          IconButton(
                            iconSize: 36,
                            icon: const Icon(LucideIcons.fastForward),
                            onPressed: () {
                              final duration = _player.duration ?? Duration.zero;
                              final newPos = _player.position + const Duration(seconds: 10);
                              _player.seek(newPos > duration ? duration : newPos);
                            },
                          ),
                        ],
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
    );
  }
}
