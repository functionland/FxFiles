import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fula_files/core/services/audio_player_service.dart';

class AudioVisualizer extends StatefulWidget {
  final int barCount;
  final double barWidth;
  final double barSpacing;
  final double minHeight;
  final double maxHeight;
  final Color? color;
  final Color? inactiveColor;
  final BorderRadius? borderRadius;

  const AudioVisualizer({
    super.key,
    this.barCount = 32,
    this.barWidth = 4,
    this.barSpacing = 2,
    this.minHeight = 4,
    this.maxHeight = 100,
    this.color,
    this.inactiveColor,
    this.borderRadius,
  });

  @override
  State<AudioVisualizer> createState() => _AudioVisualizerState();
}

class _AudioVisualizerState extends State<AudioVisualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<double> _barHeights;
  late List<double> _targetHeights;
  final Random _random = Random();
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _barHeights = List.generate(widget.barCount, (_) => widget.minHeight);
    _targetHeights = List.generate(widget.barCount, (_) => widget.minHeight);

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    )..addListener(_updateBars);

    // Check initial playing state after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final isPlaying = AudioPlayerService.instance.isPlaying;
        _handlePlayingStateChange(isPlaying);
      }
    });
  }

  void _updateBars() {
    if (!mounted) return;

    setState(() {
      for (int i = 0; i < widget.barCount; i++) {
        // Smoothly interpolate towards target
        _barHeights[i] = _barHeights[i] + (_targetHeights[i] - _barHeights[i]) * 0.3;
      }
    });
  }

  void _generateNewTargets() {
    for (int i = 0; i < widget.barCount; i++) {
      // Create wave-like pattern with some randomness
      final baseHeight = widget.minHeight +
          (widget.maxHeight - widget.minHeight) *
              (0.3 + 0.7 * _random.nextDouble());

      // Add frequency-based variation (lower bars = bass, higher bars = treble)
      final frequencyFactor = sin(i / widget.barCount * pi) * 0.3 + 0.7;
      _targetHeights[i] = baseHeight * frequencyFactor;
    }
  }

  void _handlePlayingStateChange(bool isPlaying) {
    if (_isPlaying == isPlaying) return;
    _isPlaying = isPlaying;

    if (isPlaying) {
      if (!_controller.isAnimating) {
        _controller.repeat();
        _startVisualization();
      }
    } else {
      _controller.stop();
      for (int i = 0; i < widget.barCount; i++) {
        _targetHeights[i] = widget.minHeight;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = widget.color ?? theme.colorScheme.primary;
    final inactiveColor = widget.inactiveColor ??
        theme.colorScheme.surfaceContainerHighest;
    final borderRadius = widget.borderRadius ?? BorderRadius.circular(2);

    return StreamBuilder<bool>(
      stream: AudioPlayerService.instance.isPlayingStream,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data ?? false;

        // Schedule state change after build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _handlePlayingStateChange(isPlaying);
          }
        });

        return SizedBox(
          height: widget.maxHeight,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(widget.barCount, (index) {
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: widget.barSpacing / 2),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 50),
                  width: widget.barWidth,
                  height: _barHeights[index].clamp(widget.minHeight, widget.maxHeight),
                  decoration: BoxDecoration(
                    color: isPlaying ? activeColor : inactiveColor,
                    borderRadius: borderRadius,
                  ),
                ),
              );
            }),
          ),
        );
      },
    );
  }

  void _startVisualization() {
    Future.doWhile(() async {
      if (!mounted || !_controller.isAnimating) return false;

      _generateNewTargets();
      await Future.delayed(const Duration(milliseconds: 100));
      return _controller.isAnimating;
    });
  }
}

// Circular audio visualizer
class CircularAudioVisualizer extends StatefulWidget {
  final double size;
  final int barCount;
  final double barWidth;
  final double minBarLength;
  final double maxBarLength;
  final Color? color;
  final Color? inactiveColor;

  const CircularAudioVisualizer({
    super.key,
    this.size = 200,
    this.barCount = 48,
    this.barWidth = 3,
    this.minBarLength = 10,
    this.maxBarLength = 40,
    this.color,
    this.inactiveColor,
  });

  @override
  State<CircularAudioVisualizer> createState() => _CircularAudioVisualizerState();
}

class _CircularAudioVisualizerState extends State<CircularAudioVisualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<double> _barLengths;
  final Random _random = Random();
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _barLengths = List.generate(widget.barCount, (_) => widget.minBarLength);

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    )..addListener(() {
        if (mounted) setState(() {});
      });

    // Check initial playing state after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final isPlaying = AudioPlayerService.instance.isPlaying;
        _handlePlayingStateChange(isPlaying);
      }
    });
  }

  void _generateNewLengths() {
    for (int i = 0; i < widget.barCount; i++) {
      final targetLength = widget.minBarLength +
          (widget.maxBarLength - widget.minBarLength) * _random.nextDouble();
      _barLengths[i] = _barLengths[i] + (targetLength - _barLengths[i]) * 0.3;
    }
  }

  void _handlePlayingStateChange(bool isPlaying) {
    if (_isPlaying == isPlaying) return;
    _isPlaying = isPlaying;

    if (isPlaying) {
      if (!_controller.isAnimating) {
        _controller.repeat();
        _startVisualization();
      }
    } else {
      _controller.stop();
      for (int i = 0; i < widget.barCount; i++) {
        _barLengths[i] = widget.minBarLength;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = widget.color ?? theme.colorScheme.primary;
    final inactiveColor = widget.inactiveColor ??
        theme.colorScheme.surfaceContainerHighest;

    return StreamBuilder<bool>(
      stream: AudioPlayerService.instance.isPlayingStream,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data ?? false;

        // Schedule state change after build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _handlePlayingStateChange(isPlaying);
          }
        });

        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: CustomPaint(
            painter: _CircularVisualizerPainter(
              barLengths: _barLengths,
              barWidth: widget.barWidth,
              color: isPlaying ? activeColor : inactiveColor,
            ),
          ),
        );
      },
    );
  }

  void _startVisualization() {
    Future.doWhile(() async {
      if (!mounted || !_controller.isAnimating) return false;

      _generateNewLengths();
      await Future.delayed(const Duration(milliseconds: 100));
      return _controller.isAnimating;
    });
  }
}

class _CircularVisualizerPainter extends CustomPainter {
  final List<double> barLengths;
  final double barWidth;
  final Color color;

  _CircularVisualizerPainter({
    required this.barLengths,
    required this.barWidth,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2 - barWidth;
    final paint = Paint()
      ..color = color
      ..strokeWidth = barWidth
      ..strokeCap = StrokeCap.round;

    final angleStep = 2 * pi / barLengths.length;

    for (int i = 0; i < barLengths.length; i++) {
      final angle = i * angleStep - pi / 2;
      final innerRadius = radius - barLengths[i] / 2;
      final outerRadius = radius + barLengths[i] / 2;

      final start = Offset(
        center.dx + innerRadius * cos(angle),
        center.dy + innerRadius * sin(angle),
      );
      final end = Offset(
        center.dx + outerRadius * cos(angle),
        center.dy + outerRadius * sin(angle),
      );

      canvas.drawLine(start, end, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CircularVisualizerPainter oldDelegate) {
    return true;
  }
}

// Waveform visualizer that follows audio position
class WaveformVisualizer extends StatelessWidget {
  final double height;
  final Color? color;
  final Color? progressColor;
  final int barCount;

  const WaveformVisualizer({
    super.key,
    this.height = 60,
    this.color,
    this.progressColor,
    this.barCount = 50,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waveColor = color ?? theme.colorScheme.surfaceContainerHighest;
    final playedColor = progressColor ?? theme.colorScheme.primary;

    // Generate static waveform based on position/duration
    final random = Random(42); // Fixed seed for consistent waveform
    final waveData = List.generate(
      barCount,
      (_) => 0.2 + random.nextDouble() * 0.8,
    );

    return StreamBuilder<Duration>(
      stream: AudioPlayerService.instance.positionStream,
      builder: (context, positionSnapshot) {
        return StreamBuilder<Duration?>(
          stream: AudioPlayerService.instance.durationStream,
          builder: (context, durationSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final duration = durationSnapshot.data ?? Duration.zero;
            final progress = duration.inMilliseconds > 0
                ? position.inMilliseconds / duration.inMilliseconds
                : 0.0;

            return SizedBox(
              height: height,
              child: CustomPaint(
                size: Size.infinite,
                painter: _WaveformPainter(
                  waveData: waveData,
                  progress: progress,
                  waveColor: waveColor,
                  progressColor: playedColor,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> waveData;
  final double progress;
  final Color waveColor;
  final Color progressColor;

  _WaveformPainter({
    required this.waveData,
    required this.progress,
    required this.waveColor,
    required this.progressColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth = size.width / waveData.length * 0.7;
    final spacing = size.width / waveData.length * 0.3;
    final centerY = size.height / 2;

    for (int i = 0; i < waveData.length; i++) {
      final x = i * (barWidth + spacing) + barWidth / 2;
      final barProgress = i / waveData.length;
      final barHeight = waveData[i] * size.height * 0.8;

      final paint = Paint()
        ..color = barProgress < progress ? progressColor : waveColor
        ..strokeWidth = barWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(
        Offset(x, centerY - barHeight / 2),
        Offset(x, centerY + barHeight / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
