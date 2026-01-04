import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/services/local_storage_service.dart';

class AppSettings {
  final ThemeMode themeMode;
  final bool autoSync;
  final bool wifiOnly;
  final bool thumbScrollEnabled;

  AppSettings({
    this.themeMode = ThemeMode.system,
    this.autoSync = true,
    this.wifiOnly = true,
    this.thumbScrollEnabled = true,
  });

  AppSettings copyWith({
    ThemeMode? themeMode,
    bool? autoSync,
    bool? wifiOnly,
    bool? thumbScrollEnabled,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      autoSync: autoSync ?? this.autoSync,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      thumbScrollEnabled: thumbScrollEnabled ?? this.thumbScrollEnabled,
    );
  }
}

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    _loadSettings();
    return AppSettings();
  }

  Future<void> _loadSettings() async {
    final themeModeIndex = LocalStorageService.instance.getSetting<int>('themeMode');
    final autoSync = LocalStorageService.instance.getSetting<bool>('autoSync');
    final wifiOnly = LocalStorageService.instance.getSetting<bool>('wifiOnly');
    final thumbScrollEnabled = LocalStorageService.instance.getSetting<bool>('thumbScrollEnabled');

    state = AppSettings(
      themeMode: themeModeIndex != null
          ? ThemeMode.values[themeModeIndex]
          : ThemeMode.system,
      autoSync: autoSync ?? true,
      wifiOnly: wifiOnly ?? true,
      thumbScrollEnabled: thumbScrollEnabled ?? true,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await LocalStorageService.instance.saveSetting('themeMode', mode.index);
  }

  Future<void> setAutoSync(bool value) async {
    state = state.copyWith(autoSync: value);
    await LocalStorageService.instance.saveSetting('autoSync', value);
  }

  Future<void> setWifiOnly(bool value) async {
    state = state.copyWith(wifiOnly: value);
    await LocalStorageService.instance.saveSetting('wifiOnly', value);
  }

  Future<void> setThumbScrollEnabled(bool value) async {
    state = state.copyWith(thumbScrollEnabled: value);
    await LocalStorageService.instance.saveSetting('thumbScrollEnabled', value);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(() {
  return SettingsNotifier();
});
