import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fula_files/features/ai_connections/models/ai_connection.dart';
import 'package:fula_files/features/ai_connections/services/ai_connection_service.dart';

/// Immutable UI state for the AI Connections screen.
@immutable
class AiConnectionsState {
  /// Saved (persisted) connection records. Never contains bundle secrets.
  final List<AiConnection> connections;

  /// True while a create / load operation is in flight.
  final bool isBusy;

  /// Last error message, if any (cleared on the next operation).
  final String? error;

  const AiConnectionsState({
    this.connections = const [],
    this.isBusy = false,
    this.error,
  });

  AiConnectionsState copyWith({
    List<AiConnection>? connections,
    bool? isBusy,
    Object? error = _sentinel,
  }) {
    return AiConnectionsState(
      connections: connections ?? this.connections,
      isBusy: isBusy ?? this.isBusy,
      error: identical(error, _sentinel) ? this.error : error as String?,
    );
  }

  static const Object _sentinel = Object();
}

/// Riverpod notifier backing the AI Connections screen. Mirrors the `nft`
/// feature's `Notifier<State>` + `NotifierProvider` pattern.
class AiConnectionsNotifier extends Notifier<AiConnectionsState> {
  AiConnectionService get _service => AiConnectionService.instance;

  @override
  AiConnectionsState build() {
    // Kick off an initial load; state updates when it completes.
    Future.microtask(load);
    return const AiConnectionsState();
  }

  /// Load the persisted connection records.
  Future<void> load() async {
    state = state.copyWith(isBusy: true, error: null);
    try {
      final connections = await _service.listConnections();
      state = state.copyWith(connections: connections, isBusy: false);
    } catch (e) {
      state = state.copyWith(isBusy: false, error: e.toString());
    }
  }

  /// Create a new connection. Persists the record and returns the one-time
  /// bundle JSON string for the UI to show. Returns null on failure (error is
  /// surfaced in [AiConnectionsState.error]).
  Future<String?> createConnection({required String label}) async {
    state = state.copyWith(isBusy: true, error: null);
    try {
      final bundle = await _service.createConnection(label: label);
      final connections = await _service.listConnections();
      state = state.copyWith(connections: connections, isBusy: false);
      return bundle;
    } catch (e) {
      state = state.copyWith(isBusy: false, error: e.toString());
      return null;
    }
  }

  /// Disconnect a saved connection: the service revokes it server-side (L1d)
  /// when the record has a connectionId, then deletes the local record.
  ///
  /// HARD-FAIL: the service only removes the record when the server revoke
  /// actually succeeds. If it fails (offline / signed out / server error) the
  /// record is KEPT; we re-list so the connection stays visible and set a
  /// friendly error so the user knows the AI may still have access — a failed
  /// disconnect is never presented as success.
  ///
  /// Returns true when the connection was disconnected (and removed), false on a
  /// hard-fail (the connection remains and [AiConnectionsState.error] is set).
  Future<bool> deleteConnection(String id) async {
    state = state.copyWith(isBusy: true, error: null);
    try {
      await _service.deleteConnection(id);
      final connections = await _service.listConnections();
      state = state.copyWith(connections: connections, isBusy: false);
      return true;
    } catch (_) {
      // Re-list so the still-revocable connection stays in the UI, and surface a
      // truthful, user-facing message (not the raw exception).
      final connections = await _service.listConnections();
      state = state.copyWith(
        connections: connections,
        isBusy: false,
        error:
            "Couldn't disconnect — the AI may still have access. Check your connection and try again.",
      );
      return false;
    }
  }
}

final aiConnectionsProvider =
    NotifierProvider<AiConnectionsNotifier, AiConnectionsState>(
  AiConnectionsNotifier.new,
);
