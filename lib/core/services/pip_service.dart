import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PipService {
  PipService._();
  static final PipService instance = PipService._();

  static const _channel = MethodChannel('land.fx.files/pip');
  static const _eventChannel = EventChannel('land.fx.files/pip/events');

  final _pipModeController = StreamController<bool>.broadcast();
  Stream<bool> get pipModeStream => _pipModeController.stream;

  bool _isInPipMode = false;
  bool get isInPipMode => _isInPipMode;

  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;

    if (!Platform.isAndroid) {
      _isInitialized = true;
      return;
    }

    _eventChannel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        final isInPip = event['isInPipMode'] as bool? ?? false;
        _isInPipMode = isInPip;
        _pipModeController.add(isInPip);
        debugPrint('PiP mode changed: $isInPip');
      }
    });

    _isInitialized = true;
    debugPrint('PipService initialized');
  }

  /// Check if Picture-in-Picture is supported on this device
  Future<bool> isPipSupported() async {
    if (!Platform.isAndroid) return false;

    try {
      final result = await _channel.invokeMethod<bool>('isPipSupported');
      return result ?? false;
    } catch (e) {
      debugPrint('Error checking PiP support: $e');
      return false;
    }
  }

  /// Enter Picture-in-Picture mode
  /// [aspectRatioWidth] and [aspectRatioHeight] define the aspect ratio of the PiP window
  Future<bool> enterPip({int aspectRatioWidth = 16, int aspectRatioHeight = 9}) async {
    if (!Platform.isAndroid) return false;

    try {
      final result = await _channel.invokeMethod<bool>('enterPip', {
        'width': aspectRatioWidth,
        'height': aspectRatioHeight,
      });
      return result ?? false;
    } catch (e) {
      debugPrint('Error entering PiP: $e');
      return false;
    }
  }

  /// Enable or disable automatic Picture-in-Picture when user leaves the app
  /// Only works on Android 12+ (API 31+)
  Future<bool> setAutoPip({
    required bool enabled,
    int aspectRatioWidth = 16,
    int aspectRatioHeight = 9,
  }) async {
    if (!Platform.isAndroid) return false;

    try {
      final result = await _channel.invokeMethod<bool>('setAutoPip', {
        'enabled': enabled,
        'width': aspectRatioWidth,
        'height': aspectRatioHeight,
      });
      return result ?? false;
    } catch (e) {
      debugPrint('Error setting auto PiP: $e');
      return false;
    }
  }

  /// Check if currently in Picture-in-Picture mode
  Future<bool> checkPipMode() async {
    if (!Platform.isAndroid) return false;

    try {
      final result = await _channel.invokeMethod<bool>('isInPipMode');
      _isInPipMode = result ?? false;
      return _isInPipMode;
    } catch (e) {
      debugPrint('Error checking PiP mode: $e');
      return false;
    }
  }

  void dispose() {
    _pipModeController.close();
  }
}
