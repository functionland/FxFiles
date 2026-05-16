import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Coarse classification of the device's physical RAM. Drives whether the
/// AI Automation feature loads the on-device LLM at all, and which
/// llama.cpp parameters to use when it does.
///
/// The thresholds are chosen for **Llama 3.2 1B-instruct Q4_K_M** (~770 MB
/// on disk, ~1.0–1.3 GB peak RSS during a 256-token inference with the KV
/// cache + compute buffer + Flutter runtime + OS):
///
/// - `<2 GB` total RAM cannot host this model reliably — even with
///   `useMmap=true` and aggressive paging, peak RSS exceeds what the OS
///   leaves available to the app.
/// - `2–3 GB` works but only with reduced parameters; the headroom is
///   thin enough that an incoming notification can tip it over.
/// - `>4 GB` runs comfortably with the defaults.
enum MemoryTier {
  /// `<2 GB` total RAM. The LLM is not loaded; the CRM Automation feature
  /// degrades to the heuristic-fallback path (deterministic
  /// `{column}` substitution with user-written literal templates).
  insufficient,

  /// `2–3 GB` total RAM. LLM is loaded with `nCtx=512`, `nBatch=128`,
  /// `nPredict=192`, `nThreads=2`. Context is released after each
  /// inference to free RAM for the rest of the app.
  low,

  /// `3–4 GB` total RAM. Moderate parameters: `nCtx=1024`, `nBatch=256`.
  /// Context is released after each inference.
  medium,

  /// `>4 GB` total RAM. Full parameters. Context kept warm between tasks.
  high,

  /// Tier could not be determined (platform channel unavailable, native
  /// side missing). Treated as [high] for desktop fallback; surfaced
  /// separately so the UI can avoid claiming RAM numbers it doesn't have.
  unknown,
}

/// llama.cpp tuning profile selected per [MemoryTier]. The values are
/// passed verbatim to `Fllama.initContext` and `Fllama.completion`.
@immutable
class LlmTuningProfile {
  /// KV-cache size in tokens. Caps the longest prompt+output combined.
  final int nCtx;

  /// llama.cpp batch size (compute-buffer width). The compute buffer
  /// scales with `nCtx * nBatch`, so lowering this is what actually
  /// saves RAM on low-end devices.
  final int nBatch;

  /// Max tokens generated per completion. We only need ~150 tokens for
  /// the JSON template object; clamping nPredict is a defence in depth.
  final int nPredict;

  /// CPU thread count. 0 = let llama.cpp pick (defaults to all cores,
  /// which can spike thermals on low-end phones).
  final int nThreads;

  /// Whether to keep the context loaded between tasks (saves the 3–5 s
  /// load cost on warm runs). On low/medium tiers we release after each
  /// task to free the ~1 GB working set.
  final bool keepWarm;

  const LlmTuningProfile({
    required this.nCtx,
    required this.nBatch,
    required this.nPredict,
    required this.nThreads,
    required this.keepWarm,
  });

  /// For [MemoryTier.low]: 2–3 GB devices. Squeezes the compute buffer
  /// hard and releases context aggressively.
  static const low = LlmTuningProfile(
    nCtx: 512,
    nBatch: 128,
    nPredict: 192,
    nThreads: 2,
    keepWarm: false,
  );

  /// For [MemoryTier.medium]: 3–4 GB devices.
  static const medium = LlmTuningProfile(
    nCtx: 1024,
    nBatch: 256,
    nPredict: 256,
    nThreads: 4,
    keepWarm: false,
  );

  /// For [MemoryTier.high] / [MemoryTier.unknown]: 4+ GB devices and
  /// desktop. Full parameters; context stays warm.
  static const high = LlmTuningProfile(
    nCtx: 2048,
    nBatch: 512,
    nPredict: 256,
    nThreads: 0,
    keepWarm: true,
  );
}

/// Probes the device's physical RAM at startup and exposes the result
/// as a [MemoryTier] used by the AI Automation feature to decide whether
/// to load the on-device LLM and which parameters to use.
///
/// The check runs once at app start (total RAM doesn't change). A second
/// method, [headroomBytes], is called just before LLM context init to
/// catch the case where the device has enough total RAM but other apps
/// have eaten the available headroom.
class DeviceMemoryService {
  DeviceMemoryService._();
  static final DeviceMemoryService instance = DeviceMemoryService._();

  static const _channel = MethodChannel('land.fx.files/device_memory');

  /// Minimum total RAM required to load the LLM at all. Below this we
  /// skip the download entirely and only ever use the heuristic-fallback
  /// path in the CRM Automation flow.
  static const int _minTotalRamBytes = 2 * 1024 * 1024 * 1024; // 2 GB

  /// Below 3 GB total: [MemoryTier.low] (reduced parameters).
  static const int _comfortableRamBytes = 3 * 1024 * 1024 * 1024; // 3 GB

  /// Below 4 GB total: [MemoryTier.medium]. At or above: [MemoryTier.high].
  static const int _highRamBytes = 4 * 1024 * 1024 * 1024; // 4 GB

  /// Minimum runtime headroom before LLM context init. Tuned per-platform:
  /// Android `MemoryInfo.availMem` overstates what the app actually gets
  /// (the OS kills background apps to free it on demand), so 400 MB is
  /// safer there. iOS `os_proc_available_memory()` is honest — 200 MB is
  /// enough.
  static const int _minHeadroomAndroidBytes = 400 * 1024 * 1024;
  static const int _minHeadroomIosBytes = 200 * 1024 * 1024;

  Completer<void>? _initCompleter;
  int? _totalRamBytes;
  MemoryTier _tier = MemoryTier.unknown;

  /// True after [init] has run successfully.
  bool get isInitialised => _initCompleter?.isCompleted ?? false;

  /// Total physical RAM in bytes. `null` when the native side couldn't
  /// answer (e.g. desktop where we don't have a handler wired yet).
  int? get totalRamBytes => _totalRamBytes;

  /// The classification used to drive LLM gating and parameter choice.
  MemoryTier get tier => _tier;

  /// LLM parameters for the current tier. Returns `null` for
  /// [MemoryTier.insufficient] (no LLM at all). [MemoryTier.unknown]
  /// falls through to the [high]/desktop profile.
  LlmTuningProfile? get tuningProfile {
    switch (_tier) {
      case MemoryTier.insufficient:
        return null;
      case MemoryTier.low:
        return LlmTuningProfile.low;
      case MemoryTier.medium:
        return LlmTuningProfile.medium;
      case MemoryTier.high:
      case MemoryTier.unknown:
        return LlmTuningProfile.high;
    }
  }

  /// Whether the device meets the minimum RAM requirement to even
  /// download the LLM.
  bool get supportsOnDeviceLlm => _tier != MemoryTier.insufficient;

  /// Probe total RAM and classify the tier. Safe (and necessary) to call
  /// from multiple sites — concurrent callers all share the same
  /// in-flight probe. Resolves only AFTER the platform channel responds,
  /// so callers can rely on [tier] / [supportsOnDeviceLlm] being correct
  /// once their `await init()` returns.
  ///
  /// The native side may be unimplemented (Windows/Linux/macOS, dev
  /// builds before the native handlers are wired) — in that case we
  /// default to [MemoryTier.unknown] which the rest of the app treats as
  /// "trusted host, use full parameters".
  Future<void> init() async {
    final existing = _initCompleter;
    if (existing != null) return existing.future;
    final c = Completer<void>();
    _initCompleter = c;
    try {
      if (!Platform.isAndroid && !Platform.isIOS) {
        // Desktop platforms typically have plenty of RAM and don't
        // expose the same APIs. Assume `unknown` (→ high-tier profile)
        // so the existing desktop flow keeps working.
        _tier = MemoryTier.unknown;
        return;
      }
      try {
        final res = await _channel.invokeMethod<int>('totalRamBytes');
        if (res == null || res <= 0) {
          _tier = MemoryTier.unknown;
          return;
        }
        _totalRamBytes = res;
        if (res < _minTotalRamBytes) {
          _tier = MemoryTier.insufficient;
        } else if (res < _comfortableRamBytes) {
          _tier = MemoryTier.low;
        } else if (res < _highRamBytes) {
          _tier = MemoryTier.medium;
        } else {
          _tier = MemoryTier.high;
        }
      } on MissingPluginException {
        // Native handler not registered yet — fail open so the feature
        // keeps working in dev builds.
        _tier = MemoryTier.unknown;
      } catch (e) {
        debugPrint('DeviceMemoryService: totalRamBytes probe failed: $e');
        _tier = MemoryTier.unknown;
      }
    } finally {
      c.complete();
    }
  }

  /// How many bytes of headroom the OS will let the app allocate before
  /// it gets killed. On iOS this is `os_proc_available_memory()` which
  /// accounts for the per-process jetsam limit. On Android this is
  /// `MemoryInfo.availMem` (a coarse approximation — it overstates what
  /// the foreground app will actually get).
  ///
  /// Returns `null` when the native side can't answer. Callers treat
  /// `null` as "permissive — proceed".
  Future<int?> headroomBytes() async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    try {
      final method = Platform.isIOS
          ? 'availableProcMemory'
          : 'availableMemoryBytes';
      return await _channel.invokeMethod<int>(method);
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('DeviceMemoryService: headroomBytes probe failed: $e');
      return null;
    }
  }

  /// Returns `true` when the current headroom is comfortably above the
  /// per-platform minimum for loading the LLM. `null` (probe failed) is
  /// permissive — we'd rather attempt a load that might OOM than block a
  /// user whose device is actually fine.
  Future<bool> hasEnoughHeadroomForLlm() async {
    return isHeadroomEnoughForLlm(await headroomBytes());
  }

  /// Stateless version of [hasEnoughHeadroomForLlm] that takes a
  /// pre-fetched headroom value. Callers that need to keep the headroom
  /// number around (e.g. for an error message) probe once and pass the
  /// value to both this and the [LowMemoryException] constructor —
  /// otherwise the two reads can drift apart between calls.
  static bool isHeadroomEnoughForLlm(int? headroomBytes) {
    if (headroomBytes == null) return true;
    final min = Platform.isIOS ? _minHeadroomIosBytes : _minHeadroomAndroidBytes;
    return headroomBytes >= min;
  }

  /// Human-readable RAM label for the UI: "2.0 GB", "3.5 GB", etc.
  /// Returns `null` when total RAM is unknown.
  String? formattedTotalRam() {
    final b = _totalRamBytes;
    if (b == null) return null;
    final gb = b / (1024 * 1024 * 1024);
    if (gb >= 10) return '${gb.toStringAsFixed(0)} GB';
    return '${gb.toStringAsFixed(1)} GB';
  }
}
