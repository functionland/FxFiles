import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Tracks upload speeds and estimates duration for new uploads.
/// Uses a rolling average of recent uploads to provide accurate estimates.
class UploadSpeedTracker {
  UploadSpeedTracker._();
  static final UploadSpeedTracker instance = UploadSpeedTracker._();

  /// Speed samples: bytes per second
  final List<_SpeedSample> _samples = [];

  /// Maximum number of samples to keep
  static const int maxSamples = 20;

  /// Maximum age of samples (30 minutes)
  static const Duration maxSampleAge = Duration(minutes: 30);

  /// Default assumed speed for first upload (500 KB/s)
  static const double defaultSpeedBytesPerSecond = 500 * 1024;

  /// Minimum speed to prevent division by zero (10 KB/s)
  static const double minSpeedBytesPerSecond = 10 * 1024;

  /// Current network type for detecting changes
  String? _currentNetworkType;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  /// Initialize the tracker and listen for network changes
  void initialize() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);
    _updateCurrentNetwork();
  }

  /// Dispose of resources
  void dispose() {
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }

  Future<void> _updateCurrentNetwork() async {
    try {
      final results = await Connectivity().checkConnectivity();
      _currentNetworkType = _getNetworkType(results);
    } catch (e) {
      debugPrint('UploadSpeedTracker: Failed to check connectivity: $e');
    }
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final newType = _getNetworkType(results);
    if (_currentNetworkType != null && _currentNetworkType != newType) {
      // Network type changed - clear samples as speed will be different
      debugPrint('UploadSpeedTracker: Network changed from $_currentNetworkType to $newType, clearing samples');
      _samples.clear();
    }
    _currentNetworkType = newType;
  }

  String _getNetworkType(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi)) return 'wifi';
    if (results.contains(ConnectivityResult.ethernet)) return 'ethernet';
    if (results.contains(ConnectivityResult.mobile)) return 'mobile';
    if (results.contains(ConnectivityResult.vpn)) return 'vpn';
    return 'none';
  }

  /// Record a completed upload for speed calculation.
  /// [bytes] - total bytes uploaded
  /// [duration] - time taken for the upload
  void recordUpload(int bytes, Duration duration) {
    if (bytes <= 0 || duration.inMilliseconds <= 0) return;

    // Calculate speed in bytes per second
    final speed = bytes / (duration.inMilliseconds / 1000.0);

    // Ignore unrealistically high speeds (likely from cache or small file anomaly)
    // Cap at 100 MB/s
    if (speed > 100 * 1024 * 1024) {
      debugPrint('UploadSpeedTracker: Ignoring unrealistic speed: ${_formatSpeed(speed)}');
      return;
    }

    _samples.add(_SpeedSample(
      speed: speed,
      timestamp: DateTime.now(),
      bytes: bytes,
    ));

    // Remove old samples
    _pruneOldSamples();

    // Trim to max size (remove oldest)
    while (_samples.length > maxSamples) {
      _samples.removeAt(0);
    }

    debugPrint('UploadSpeedTracker: Recorded ${_formatBytes(bytes)} in ${duration.inSeconds}s = ${_formatSpeed(speed)} (${_samples.length} samples)');
  }

  void _pruneOldSamples() {
    final cutoff = DateTime.now().subtract(maxSampleAge);
    _samples.removeWhere((s) => s.timestamp.isBefore(cutoff));
  }

  /// Get the current average upload speed in bytes per second.
  double getAverageSpeed() {
    _pruneOldSamples();

    if (_samples.isEmpty) {
      return defaultSpeedBytesPerSecond;
    }

    // Weight recent samples more heavily
    double weightedSum = 0;
    double totalWeight = 0;

    for (int i = 0; i < _samples.length; i++) {
      // Newer samples get higher weight (1.0 to 2.0)
      final weight = 1.0 + (i / _samples.length);
      weightedSum += _samples[i].speed * weight;
      totalWeight += weight;
    }

    final avgSpeed = weightedSum / totalWeight;
    return avgSpeed.clamp(minSpeedBytesPerSecond, double.infinity);
  }

  /// Estimate how long an upload of [bytes] will take.
  Duration estimateDuration(int bytes) {
    final speed = getAverageSpeed();
    final seconds = bytes / speed;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// Check if we have enough data for reliable estimates.
  bool get hasReliableData => _samples.length >= 3;

  /// Get the number of samples we have.
  int get sampleCount => _samples.length;

  /// Clear all samples (e.g., when user logs out).
  void clear() {
    _samples.clear();
    debugPrint('UploadSpeedTracker: Cleared all samples');
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
}

class _SpeedSample {
  final double speed; // bytes per second
  final DateTime timestamp;
  final int bytes;

  _SpeedSample({
    required this.speed,
    required this.timestamp,
    required this.bytes,
  });
}
