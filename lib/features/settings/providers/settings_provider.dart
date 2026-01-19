import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/services/local_storage_service.dart';

class AppSettings {
  final ThemeMode themeMode;
  final bool autoSync;
  final bool wifiOnly;
  final bool thumbScrollEnabled;
  final bool tosAccepted;
  final String? orgName;

  AppSettings({
    this.themeMode = ThemeMode.system,
    this.autoSync = true,
    this.wifiOnly = true,
    this.thumbScrollEnabled = true,
    this.tosAccepted = false,
    this.orgName,
  });

  AppSettings copyWith({
    ThemeMode? themeMode,
    bool? autoSync,
    bool? wifiOnly,
    bool? thumbScrollEnabled,
    bool? tosAccepted,
    String? orgName,
    bool clearOrgName = false,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      autoSync: autoSync ?? this.autoSync,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      thumbScrollEnabled: thumbScrollEnabled ?? this.thumbScrollEnabled,
      tosAccepted: tosAccepted ?? this.tosAccepted,
      orgName: clearOrgName ? null : (orgName ?? this.orgName),
    );
  }
}

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    // Load settings synchronously - Hive reads are sync once box is open
    return _loadSettingsSync();
  }

  /// Load settings synchronously from Hive (box must already be open)
  AppSettings _loadSettingsSync() {
    final themeModeIndex = LocalStorageService.instance.getSetting<int>('themeMode');
    final autoSync = LocalStorageService.instance.getSetting<bool>('autoSync');
    final wifiOnly = LocalStorageService.instance.getSetting<bool>('wifiOnly');
    final thumbScrollEnabled = LocalStorageService.instance.getSetting<bool>('thumbScrollEnabled');
    final tosAccepted = LocalStorageService.instance.getSetting<bool>('tosAccepted');
    final storedOrgName = LocalStorageService.instance.getSetting<String>('orgName');
    final orgName = (storedOrgName != null && storedOrgName.isNotEmpty) ? storedOrgName : null;

    return AppSettings(
      themeMode: themeModeIndex != null
          ? ThemeMode.values[themeModeIndex]
          : ThemeMode.system,
      autoSync: autoSync ?? true,
      wifiOnly: wifiOnly ?? true,
      thumbScrollEnabled: thumbScrollEnabled ?? true,
      tosAccepted: tosAccepted ?? false,
      orgName: orgName,
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

  Future<void> setTosAccepted(bool value) async {
    state = state.copyWith(tosAccepted: value);
    await LocalStorageService.instance.saveSetting('tosAccepted', value);
  }

  Future<void> setOrgName(String? value) async {
    if (value == null || value.isEmpty) {
      state = state.copyWith(clearOrgName: true);
      await LocalStorageService.instance.saveSetting('orgName', '');
    } else {
      state = state.copyWith(orgName: value);
      await LocalStorageService.instance.saveSetting('orgName', value);
    }
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(() {
  return SettingsNotifier();
});
