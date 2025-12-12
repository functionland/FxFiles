import 'dart:io';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:video_player/video_player.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/models/recent_file.dart';

class VideoViewerScreen extends StatefulWidget {
  final String filePath;

  const VideoViewerScreen({super.key, required this.filePath});

  @override
  State<VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends State<VideoViewerScreen> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _showControls = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
    _trackRecentFile();
  }

  Future<void> _trackRecentFile() async {
    final file = File(widget.filePath);
    if (await file.exists()) {
      final stat = await file.stat();
      await LocalStorageService.instance.addRecentFile(RecentFile(
        path: widget.filePath,
        name: widget.filePath.split(Platform.pathSeparator).last,
        mimeType: 'video/*',
        size: stat.size,
        accessedAt: DateTime.now(),
      ));
    }
  }

  Future<void> _initializeVideo() async {
    try {
      _controller = VideoPlayerController.file(File(widget.filePath));
      await _controller.initialize();
      setState(() => _isInitialized = true);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.filePath.split(Platform.pathSeparator).last;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _showControls ? AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: Text(fileName, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.share),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Sharing: ${widget.filePath.split(Platform.pathSeparator).last}')),
              );
            },
          ),
        ],
      ) : null,
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        child: Center(
          child: _buildVideoContent(),
        ),
      ),
      bottomNavigationBar: _showControls && _isInitialized ? _buildControls() : null,
    );
  }

  Widget _buildVideoContent() {
    if (_error != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(LucideIcons.videoOff, size: 64, color: Colors.white54),
          const SizedBox(height: 16),
          Text('Error: $_error', style: const TextStyle(color: Colors.white54)),
        ],
      );
    }

    if (!_isInitialized) {
      return const CircularProgressIndicator(color: Colors.white);
    }

    return AspectRatio(
      aspectRatio: _controller.value.aspectRatio,
      child: VideoPlayer(_controller),
    );
  }

  Widget _buildControls() {
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder(
            valueListenable: _controller,
            builder: (context, value, child) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text(
                      _formatDuration(value.position),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    Expanded(
                      child: Slider(
                        value: value.position.inMilliseconds.toDouble(),
                        min: 0,
                        max: value.duration.inMilliseconds.toDouble(),
                        onChanged: (v) {
                          _controller.seekTo(Duration(milliseconds: v.toInt()));
                        },
                      ),
                    ),
                    Text(
                      _formatDuration(value.duration),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              );
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(LucideIcons.skipBack, color: Colors.white),
                onPressed: () {
                  final pos = _controller.value.position;
                  _controller.seekTo(pos - const Duration(seconds: 10));
                },
              ),
              ValueListenableBuilder(
                valueListenable: _controller,
                builder: (context, value, child) {
                  return IconButton(
                    icon: Icon(
                      value.isPlaying ? LucideIcons.pause : LucideIcons.play,
                      color: Colors.white,
                      size: 32,
                    ),
                    onPressed: () {
                      if (value.isPlaying) {
                        _controller.pause();
                      } else {
                        _controller.play();
                      }
                    },
                  );
                },
              ),
              IconButton(
                icon: const Icon(LucideIcons.skipForward, color: Colors.white),
                onPressed: () {
                  final pos = _controller.value.position;
                  _controller.seekTo(pos + const Duration(seconds: 10));
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}
