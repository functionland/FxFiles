import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Service to manage battery optimization settings for background sync
class BatteryOptimizationService {
  BatteryOptimizationService._();
  static final BatteryOptimizationService instance = BatteryOptimizationService._();

  static const MethodChannel _channel = MethodChannel('land.fx.files/battery_optimization');

  /// Check if battery optimization is disabled for this app
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true; // iOS doesn't have this restriction

    try {
      final result = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return result ?? false;
    } catch (e) {
      debugPrint('Error checking battery optimization status: $e');
      return false;
    }
  }

  /// Request to disable battery optimization (opens system dialog)
  Future<bool> requestDisableBatteryOptimization() async {
    if (!Platform.isAndroid) return true;

    try {
      final result = await _channel.invokeMethod<bool>('requestDisableBatteryOptimization');
      return result ?? false;
    } catch (e) {
      debugPrint('Error requesting battery optimization disable: $e');
      return false;
    }
  }

  /// Open battery optimization settings page
  Future<void> openBatteryOptimizationSettings() async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('openBatteryOptimizationSettings');
    } catch (e) {
      debugPrint('Error opening battery optimization settings: $e');
    }
  }

  /// Show dialog explaining why battery optimization exemption is needed
  Future<bool> showBatteryOptimizationDialog(BuildContext context) async {
    if (!Platform.isAndroid) return true;

    // Check if already exempted
    final isExempted = await isIgnoringBatteryOptimizations();
    if (isExempted) return true;

    // Show explanation dialog
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Background Sync Permission'),
        content: const Text(
          'To sync your files in the background, FxFiles needs to be exempt from battery optimization.\n\n'
          'This allows the app to maintain network access when running in the background.\n\n'
          'Without this permission, sync may fail when the app is minimized.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context, true);
            },
            child: const Text('Enable'),
          ),
        ],
      ),
    );

    if (result == true) {
      return await requestDisableBatteryOptimization();
    }
    return false;
  }
}
