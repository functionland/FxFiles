import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/providers/fula_api_provider.dart';
import 'package:fula_files/features/ai_connections/services/ai_activity_service.dart';

/// Immutable UI state for the "AI activity" screen (P16).
@immutable
class AiActivityState {
  /// The shared AI-workspace objects (newest first). Empty when there is no AI
  /// connection OR when an AI connection exists but nothing has been stored yet
  /// — disambiguate with [hasConnection].
  final List<FulaObject> objects;

  /// True while a load is in flight.
  final bool isBusy;

  /// Last error message, if any (cleared on the next load).
  final String? error;

  /// Whether the user has at least one AI connection. The gate: when false the
  /// screen shows a "no AI connections" state and never reads the workspace, so
  /// non-AI users see nothing.
  final bool hasConnection;

  const AiActivityState({
    this.objects = const [],
    this.isBusy = false,
    this.error,
    this.hasConnection = false,
  });

  AiActivityState copyWith({
    List<FulaObject>? objects,
    bool? isBusy,
    Object? error = _sentinel,
    bool? hasConnection,
  }) {
    return AiActivityState(
      objects: objects ?? this.objects,
      isBusy: isBusy ?? this.isBusy,
      error: identical(error, _sentinel) ? this.error : error as String?,
      hasConnection: hasConnection ?? this.hasConnection,
    );
  }

  static const Object _sentinel = Object();
}

/// Riverpod notifier backing the "AI activity" screen. Mirrors
/// [AiConnectionsNotifier]'s `Notifier<State>` + `NotifierProvider` shape.
///
/// COLLECTIVE: the listed files are the SHARED AI workspace across ALL the
/// user's AI connections — there is no per-connection attribution (every
/// connection derives the same workspace secret). The screen says so plainly.
///
/// Reads the cloud surface via [fulaApiProvider] (overridable in tests). The
/// actual listing/sort is the standalone, FFI-free [listAiActivity] so it is
/// unit-testable without a Riverpod container.
class AiActivityNotifier extends Notifier<AiActivityState> {
  @override
  AiActivityState build() {
    // Kick off an initial load; state updates when it completes. (Tests that
    // assert synchronously should `await notifier.load()` rather than rely on
    // this microtask having flushed.)
    Future.microtask(load);
    return const AiActivityState();
  }

  /// (Re)load the shared AI-workspace contents.
  ///
  /// GATED: checks [FulaApi.hasAiConnection] first; when there is no connection
  /// it records `hasConnection=false` with an empty list and does NOT read the
  /// workspace. Otherwise it lists via [listAiActivity] (tolerant — that returns
  /// `[]` rather than throwing on an AI-side read error).
  Future<void> load() async {
    final api = ref.read(fulaApiProvider);
    state = state.copyWith(isBusy: true, error: null);
    try {
      final connected = await api.hasAiConnection();
      if (!connected) {
        state = state.copyWith(
          objects: const [],
          hasConnection: false,
          isBusy: false,
        );
        return;
      }
      final objects = await listAiActivity(api);
      state = state.copyWith(
        objects: objects,
        hasConnection: true,
        isBusy: false,
      );
    } catch (e) {
      // listAiActivity is tolerant, but hasAiConnection() (or an unexpected
      // error) could still throw — surface it rather than crash the screen.
      state = state.copyWith(isBusy: false, error: e.toString());
    }
  }
}

final aiActivityProvider =
    NotifierProvider<AiActivityNotifier, AiActivityState>(
  AiActivityNotifier.new,
);
