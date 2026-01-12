import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:video_player/video_player.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/pip_service.dart';
import 'package:fula_files/core/models/recent_file.dart';
import 'package:fula_files/shared/utils/error_messages.dart';

class VideoViewerScreen extends StatefulWidget {
  final String filePath;

  const VideoViewerScreen({super.key, required this.filePath});

  @override
  State<VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends State<VideoViewerScreen> with WidgetsBindingObserver {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _showControls = true;
  String? _error;
  bool _isInPipMode = false;
  bool _pipSupported = false;
  StreamSubscription<bool>? _pipSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeVideo();
    _trackRecentFile();
    _initPip();
  }

  Future<void> _initPip() async {
    await PipService.instance.init();
    _pipSupported = await PipService.instance.isPipSupported();

    _pipSubscription = PipService.instance.pipModeStream.listen((isInPip) {
      if (mounted) {
        setState(() {
          _isInPipMode = isInPip;
          // Hide controls in PiP mode
          if (isInPip) {
            _showControls = false;
          }
        });
      }
    });

    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // When app goes to background while video is playing, enter PiP
    if (state == AppLifecycleState.inactive && _isInitialized && _controller.value.isPlaying) {
      _enterPipMode();
    }
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

      // Listen for play state changes to setup auto PiP
      _controller.addListener(_onVideoStateChanged);

      setState(() => _isInitialized = true);
    } catch (e) {
      setState(() => _error = ErrorMessages.getUserFriendlyMessage(e, context: 'load video'));
    }
  }

  void _onVideoStateChanged() {
    _setupAutoPip();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pipSubscription?.cancel();
    // Disable auto PiP when leaving
    PipService.instance.setAutoPip(enabled: false);
    _controller.removeListener(_onVideoStateChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _enterPipMode() async {
    if (!_pipSupported || !_isInitialized) return;

    // Calculate aspect ratio from video
    final videoWidth = _controller.value.size.width.toInt();
    final videoHeight = _controller.value.size.height.toInt();

    // Use video's aspect ratio or fallback to 16:9
    final aspectWidth = videoWidth > 0 ? videoWidth : 16;
    final aspectHeight = videoHeight > 0 ? videoHeight : 9;

    await PipService.instance.enterPip(
      aspectRatioWidth: aspectWidth,
      aspectRatioHeight: aspectHeight,
    );
  }

  void _setupAutoPip() {
    if (!_pipSupported || !_isInitialized) return;

    final videoWidth = _controller.value.size.width.toInt();
    final videoHeight = _controller.value.size.height.toInt();
    final aspectWidth = videoWidth > 0 ? videoWidth : 16;
    final aspectHeight = videoHeight > 0 ? videoHeight : 9;

    // Enable auto PiP when video is playing
    PipService.instance.setAutoPip(
      enabled: _controller.value.isPlaying,
      aspectRatioWidth: aspectWidth,
      aspectRatioHeight: aspectHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.filePath.split(Platform.pathSeparator).last;

    // In PiP mode, show simplified UI with just the video
    if (_isInPipMode) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: _isInitialized
              ? AspectRatio(
                  aspectRatio: _controller.value.aspectRatio,
                  child: VideoPlayer(_controller),
                )
              : const CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _showControls ? AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: Text(fileName, style: const TextStyle(fontSize: 16)),
        actions: [
          // PiP button
          if (_pipSupported)
            IconButton(
              icon: const Icon(LucideIcons.pictureInPicture2),
              tooltip: 'Picture-in-Picture',
              onPressed: _enterPipMode,
            ),
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
                tooltip: 'Rewind 10 seconds',
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
                    tooltip: value.isPlaying ? 'Pause' : 'Play',
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
                tooltip: 'Forward 10 seconds',
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
