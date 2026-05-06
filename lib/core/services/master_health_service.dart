import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:fula_client/fula_client.dart' as fula;

import 'package:fula_files/core/services/fula_api_service.dart';

/// Tri-state derived from `fula.MasterHealthEvent`:
///   * [online]            — master is reachable, normal operation
///   * [offline]           — master is down, SDK is serving from
///                           block-cache + public IPFS gateways
///   * [severelyDegraded]  — master AND cold-start channels (IPNS +
///                           chain) are unreachable; reads of
///                           never-seen-before files will fail
enum MasterHealthState { online, offline, severelyDegraded }

/// Singleton that polls fula-client's Phase 19 health channel and exposes
/// the current state as a [ValueNotifier] for UI banners.
///
/// Lifecycle: [start] from `AuthService` after `FulaApiService.initialize`,
/// [stop] on sign-out / endpoint switch. Polling pauses while the app is
/// backgrounded and resumes (with an immediate catch-up tick) on resume.
class MasterHealthService extends ChangeNotifier with WidgetsBindingObserver {
  MasterHealthService._();
  static final MasterHealthService instance = MasterHealthService._();

  static const Duration _pollInterval = Duration(seconds: 15);

  MasterHealthState _state = MasterHealthState.online;
  MasterHealthState get state => _state;

  Timer? _pollTimer;
  bool _isStarted = false;

  Future<void> start() async {
    // Idempotent. On a re-init (settings save / endpoint switch) the client
    // handle inside FulaApiService changes and the SDK's per-client event
    // buffer resets — we always re-seed so the banner reflects the new
    // client's last-known state instead of waiting up to a poll interval.
    if (!_isStarted) {
      _isStarted = true;
      WidgetsBinding.instance.addObserver(this);
      _resumePolling();
    }
    await _seed();
  }

  Future<void> stop() async {
    if (!_isStarted) return;
    _isStarted = false;
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _pollTimer = null;
    _setState(MasterHealthState.online);
  }

  Future<void> _seed() async {
    final client = FulaApiService.instance.client;
    if (client == null) return;
    try {
      final last = await fula.getLastMasterHealthEventEncrypted(client: client);
      _setState(_eventToState(last));
    } catch (e) {
      debugPrint('MasterHealthService: seed failed: $e');
    }
  }

  Future<void> _pollOnce() async {
    final client = FulaApiService.instance.client;
    if (client == null) return;
    try {
      final events =
          await fula.pollMasterHealthEventsEncrypted(client: client);
      if (events.isNotEmpty) {
        _setState(_eventToState(events.last));
      }
    } catch (e) {
      debugPrint('MasterHealthService: poll failed: $e');
    }
  }

  void _resumePolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollOnce());
  }

  void _setState(MasterHealthState next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
  }

  static MasterHealthState _eventToState(fula.MasterHealthEvent? event) {
    // null = no transition observed yet → treat as Online (advisor's call).
    if (event == null || event is fula.MasterHealthEvent_Online) {
      return MasterHealthState.online;
    }
    if (event is fula.MasterHealthEvent_SeverelyDegraded) {
      return MasterHealthState.severelyDegraded;
    }
    // OfflineFallbackActive (and any future variants) → offline.
    return MasterHealthState.offline;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isStarted) return;
    if (state == AppLifecycleState.resumed) {
      if (_pollTimer == null) {
        _resumePolling();
        // Catch up immediately so the banner reflects reality on focus.
        _pollOnce();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }
}
