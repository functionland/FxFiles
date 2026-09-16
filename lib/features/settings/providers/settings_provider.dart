import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/shared/legal/terms_content.dart';

class AppSettings {
  final ThemeMode themeMode;
  final bool autoSync;
  final bool wifiOnly;
  final bool thumbScrollEnabled;

  /// The CURRENT Terms version ([kTermsVersion]) has been accepted.
  final bool tosAccepted;

  /// Some earlier version was accepted — the gate then presents the Terms as
  /// an update rather than as a first-time request.
  final bool tosAcceptedBefore;
  final String? orgName;

  AppSettings({
    this.themeMode = ThemeMode.system,
    this.autoSync = true,
    this.wifiOnly = true,
    this.thumbScrollEnabled = true,
    this.tosAccepted = false,
    this.tosAcceptedBefore = false,
    this.orgName,
  });

  AppSettings copyWith({
    ThemeMode? themeMode,
    bool? autoSync,
    bool? wifiOnly,
    bool? thumbScrollEnabled,
    bool? tosAccepted,
    bool? tosAcceptedBefore,
    String? orgName,
    bool clearOrgName = false,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      autoSync: autoSync ?? this.autoSync,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      thumbScrollEnabled: thumbScrollEnabled ?? this.thumbScrollEnabled,
      tosAccepted: tosAccepted ?? this.tosAccepted,
      tosAcceptedBefore: tosAcceptedBefore ?? this.tosAcceptedBefore,
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
    final legacyTosAccepted =
        LocalStorageService.instance.getSetting<bool>('tosAccepted') ?? false;
    final tosAcceptedVersion =
        LocalStorageService.instance.getSetting<int>('tosAcceptedVersion');
    final storedOrgName = LocalStorageService.instance.getSetting<String>('orgName');
    final orgName = (storedOrgName != null && storedOrgName.isNotEmpty) ? storedOrgName : null;

    return AppSettings(
      themeMode: themeModeIndex != null
          ? ThemeMode.values[themeModeIndex]
          : ThemeMode.system,
      autoSync: autoSync ?? true,
      wifiOnly: wifiOnly ?? true,
      thumbScrollEnabled: thumbScrollEnabled ?? true,
      tosAccepted: !termsAcceptanceRequired(
        acceptedVersion: tosAcceptedVersion,
        legacyAccepted: legacyTosAccepted,
      ),
      tosAcceptedBefore: legacyTosAccepted || tosAcceptedVersion != null,
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

  /// Record acceptance of the CURRENT Terms: which version, and when (UTC).
  /// The legacy boolean is kept for older builds reading the same box.
  Future<void> setTosAccepted(bool value) async {
    state = state.copyWith(
      tosAccepted: value,
      tosAcceptedBefore: value ? true : null,
    );
    await LocalStorageService.instance.saveSetting('tosAccepted', value);
    if (value) {
      await LocalStorageService.instance
          .saveSetting('tosAcceptedVersion', kTermsVersion);
      await LocalStorageService.instance.saveSetting(
          'tosAcceptedAt', DateTime.now().toUtc().toIso8601String());
    }
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
