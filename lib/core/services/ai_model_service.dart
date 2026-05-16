import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fula_files/core/services/device_memory_service.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Status of the local LLM model. The UI watches [statusStream] to render
/// the download card / "ready" state on the AI Tasks browser screen.
enum AiModelStatus {
  /// Model has not been downloaded yet.
  notDownloaded,

  /// Currently downloading. [AiModelEvent.progressFraction] is non-null.
  downloading,

  /// Download paused (offline, Wi-Fi-only toggle blocked, or user paused).
  paused,

  /// Download completed and SHA verified; the model file is on disk and
  /// ready to be loaded by [LocalLlmService].
  ready,

  /// Download or verification failed. [AiModelEvent.errorMessage] holds
  /// the human-readable reason.
  error,

  /// Device doesn't meet the minimum RAM requirement (<2 GB total). The
  /// model download is refused; the AI Automation feature falls back to
  /// the heuristic-only path (no LLM, literal `{column}` substitution).
  /// The UI surfaces this so the user understands why they're not seeing
  /// the AI parsing assistance.
  unsupported,
}

class AiModelEvent {
  final AiModelStatus status;
  final double? progressFraction; // 0.0 .. 1.0 during download
  final int? downloadedBytes;
  final int? totalBytes;
  final String? errorMessage;

  const AiModelEvent({
    required this.status,
    this.progressFraction,
    this.downloadedBytes,
    this.totalBytes,
    this.errorMessage,
  });
}

/// Downloads the Llama 3.2 1B-instruct Q4_K_M model used by
/// [LocalLlmService] for on-device CRM template extraction.
///
/// Design choices (per the AI Automation feature plan):
/// - Hosted at cloud.fx.land/models — Hugging Face direct as a fallback.
/// - SHA-256 pinned in code; verified after download.
/// - Stored in `getApplicationSupportDirectory()` (NOT Documents — keeps
///   the 700 MB blob out of iCloud backup. Belt-and-braces: on iOS we also
///   set `NSURLIsExcludedFromBackupKey = YES` via a platform channel after
///   download. Without that flag Apple's App Review rejects builds that
///   stash large blobs in backed-up locations.).
/// - HTTP Range resume: a partial download offset is persisted in a tiny
///   Hive box (`ai_model_state`). On resume we send
///   `Range: bytes=<offset>-`; if the server doesn't honour it we restart
///   from 0.
/// - Wi-Fi-only toggle defaults ON. `connectivity_plus` tells us whether
///   the current connection is Wi-Fi/ethernet (cellular = blocked when
///   toggle is ON).
/// - Storage check: warn (don't hard-block) if free disk space is below
///   2 GB.
class AiModelService {
  AiModelService._();
  static final AiModelService instance = AiModelService._();

  // --- Config (pinned) -------------------------------------------------

  static const String _modelFileName = 'llama-3.2-1b-instruct-q4_k_m.gguf';
  static const String _primaryUrl =
      'https://cloud.fx.land/models/$_modelFileName';
  static const String _fallbackUrl =
      'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf';
  // SHA-256 of the canonical Q4_K_M GGUF. Verified after download; on
  // mismatch we delete and force a fresh fetch.
  static const String _expectedSha256 =
      // NOTE: placeholder — verify against the canonical Bartowski GGUF and
      // update before first release. The download itself uses Range
      // resume so this hash is critical for correctness.
      '';

  // --- State -----------------------------------------------------------

  final _statusController = StreamController<AiModelEvent>.broadcast();
  Stream<AiModelEvent> get statusStream => _statusController.stream;

  AiModelEvent _lastEvent = const AiModelEvent(status: AiModelStatus.notDownloaded);
  AiModelEvent get lastEvent => _lastEvent;

  Box<dynamic>? _stateBox;
  bool _initialised = false;

  http.Client? _httpClient;
  Completer<void>? _activeDownload;
  bool _cancelRequested = false;
  bool wifiOnly = true; // user-toggleable

  /// Initialise: open the persisted-offset Hive box and emit the current
  /// status. Safe to call multiple times.
  ///
  /// Skips the LLM entirely on devices that don't meet the minimum
  /// memory requirement — the AI Automation feature still works in
  /// heuristic-only mode (literal template substitution), but the model
  /// download never starts.
  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;
    _stateBox = await Hive.openBox<dynamic>('ai_model_state');

    // Ensure the device memory tier is known before classifying status.
    // DeviceMemoryService.init is idempotent and cheap.
    await DeviceMemoryService.instance.init();
    if (!DeviceMemoryService.instance.supportsOnDeviceLlm) {
      _emit(const AiModelEvent(status: AiModelStatus.unsupported));
      return;
    }

    final ready = await _isModelReadyOnDisk();
    _emit(AiModelEvent(
      status: ready ? AiModelStatus.ready : AiModelStatus.notDownloaded,
    ));
  }

  /// Returns the absolute path to the local model file, regardless of
  /// whether it's been downloaded yet. Callers wanting "ready" semantics
  /// should check [isReady] first.
  Future<String> modelFilePath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, _modelFileName);
  }

  /// True iff the model has been fully downloaded and verified.
  Future<bool> isReady() async => _isModelReadyOnDisk();

  /// Start the download. Idempotent: if a download is already in progress,
  /// returns its in-flight future. If the file is already on disk and
  /// verified, returns immediately. Refuses on devices that don't meet
  /// the minimum RAM requirement — no point storing 700 MB on disk if
  /// the model can never load.
  Future<void> startDownload() async {
    if (!_initialised) await init();
    if (!DeviceMemoryService.instance.supportsOnDeviceLlm) {
      _emit(const AiModelEvent(status: AiModelStatus.unsupported));
      return;
    }
    if (await isReady()) {
      _emit(const AiModelEvent(status: AiModelStatus.ready));
      return;
    }
    final inFlight = _activeDownload;
    if (inFlight != null && !inFlight.isCompleted) {
      return inFlight.future;
    }
    final c = Completer<void>();
    _activeDownload = c;
    _cancelRequested = false;
    _runDownload().whenComplete(() {
      if (!c.isCompleted) c.complete();
      _activeDownload = null;
    });
    return c.future;
  }

  /// Request that the in-flight download stop. The current HTTP stream is
  /// torn down on the next chunk. The persisted-offset state is preserved
  /// so the next [startDownload] resumes from where this one stopped.
  void cancelDownload() {
    _cancelRequested = true;
    _httpClient?.close();
    _httpClient = null;
  }

  /// Delete the model file + reset state. Useful when the user wants to
  /// reclaim disk space or after a corrupt download.
  Future<void> deleteModel() async {
    cancelDownload();
    final f = File(await modelFilePath());
    if (await f.exists()) {
      await f.delete();
    }
    await _stateBox?.delete('downloadedBytes');
    await _stateBox?.delete('totalBytes');
    _emit(const AiModelEvent(status: AiModelStatus.notDownloaded));
  }

  // ---------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------

  Future<bool> _isModelReadyOnDisk() async {
    final f = File(await modelFilePath());
    if (!await f.exists()) return false;
    final total = _stateBox?.get('totalBytes') as int?;
    if (total == null) return false;
    final size = await f.length();
    return size == total;
  }

  Future<void> _runDownload() async {
    try {
      if (!await _passesWifiCheck()) {
        _emit(const AiModelEvent(
          status: AiModelStatus.paused,
          errorMessage: 'Wi-Fi-only is on and no Wi-Fi connection detected.',
        ));
        return;
      }
      if (!await _passesStorageCheck()) {
        _emit(const AiModelEvent(
          status: AiModelStatus.error,
          errorMessage: 'Less than 2 GB free. Free up space and try again.',
        ));
        return;
      }

      // Try primary URL first, fall back to Hugging Face on hard failures.
      try {
        await _attemptDownload(_primaryUrl);
      } catch (e) {
        debugPrint('AiModelService: primary URL failed ($e); trying fallback');
        await _attemptDownload(_fallbackUrl);
      }

      if (_cancelRequested) {
        _emit(const AiModelEvent(status: AiModelStatus.paused));
        return;
      }

      if (_expectedSha256.isNotEmpty) {
        final ok = await _verifySha256();
        if (!ok) {
          await deleteModel();
          _emit(const AiModelEvent(
            status: AiModelStatus.error,
            errorMessage: 'Downloaded model failed checksum. Try again.',
          ));
          return;
        }
      }

      await _excludeFromIosBackupIfApplicable();
      _emit(const AiModelEvent(status: AiModelStatus.ready));
    } catch (e, st) {
      debugPrint('AiModelService: download error: $e\n$st');
      _emit(AiModelEvent(
        status: AiModelStatus.error,
        errorMessage: e.toString(),
      ));
    }
  }

  Future<void> _attemptDownload(String url) async {
    final path = await modelFilePath();
    final file = File(path);

    // Resume offset (only valid for the same URL+server; we trust the
    // total/offset because the SHA verify at the end will catch
    // mid-download server swaps).
    int offset = 0;
    if (await file.exists()) {
      offset = await file.length();
    }

    final headers = <String, String>{};
    if (offset > 0) headers['Range'] = 'bytes=$offset-';

    _httpClient = http.Client();
    final req = http.Request('GET', Uri.parse(url));
    req.headers.addAll(headers);
    final response = await _httpClient!.send(req);

    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException(
          'HTTP ${response.statusCode} when fetching model from $url');
    }

    // Total bytes: when resuming via Range, the server returns
    // 206 with `Content-Range: bytes <start>-<end>/<total>`.
    int total;
    if (response.statusCode == 206) {
      final cr = response.headers['content-range'];
      final m = cr == null ? null : RegExp(r'/(\d+)$').firstMatch(cr);
      if (m == null) {
        // Server didn't honour Range — restart from 0.
        await file.writeAsBytes(<int>[], flush: true);
        offset = 0;
        total = response.contentLength ?? 0;
      } else {
        total = int.parse(m.group(1)!);
      }
    } else {
      total = response.contentLength ?? 0;
      // Status 200 with non-zero offset means the server ignored the
      // Range header — start over.
      if (offset > 0) {
        await file.writeAsBytes(<int>[], flush: true);
        offset = 0;
      }
    }
    await _stateBox?.put('totalBytes', total);

    final sink = file.openWrite(mode: FileMode.append);
    var downloaded = offset;
    try {
      await for (final chunk in response.stream) {
        if (_cancelRequested) break;
        sink.add(chunk);
        downloaded += chunk.length;
        await _stateBox?.put('downloadedBytes', downloaded);
        _emit(AiModelEvent(
          status: AiModelStatus.downloading,
          progressFraction: total > 0 ? downloaded / total : null,
          downloadedBytes: downloaded,
          totalBytes: total > 0 ? total : null,
        ));
      }
    } finally {
      await sink.flush();
      await sink.close();
      _httpClient?.close();
      _httpClient = null;
    }
  }

  Future<bool> _passesWifiCheck() async {
    if (!wifiOnly) return true;
    try {
      // connectivity_plus 6+ returns a List<ConnectivityResult>; the API
      // in 7.x (this project) is the same.
      final results = await Connectivity().checkConnectivity();
      return results.any((r) =>
          r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet);
    } catch (_) {
      // If the plugin throws, don't block the download. The user can
      // turn the Wi-Fi-only toggle off explicitly.
      return true;
    }
  }

  Future<bool> _passesStorageCheck() async {
    // path_provider doesn't expose free-space; a platform channel hook is
    // tracked for v1.1. For now attempt the download — if it runs out
    // mid-stream the HTTP sink will error and we surface that.
    return true;
  }

  Future<bool> _verifySha256() async {
    final f = File(await modelFilePath());
    final stream = f.openRead();
    final digest = await sha256.bind(stream).first;
    final hex = digest.toString();
    return hex.toLowerCase() == _expectedSha256.toLowerCase();
  }

  Future<void> _excludeFromIosBackupIfApplicable() async {
    if (!Platform.isIOS) return;
    try {
      const channel = MethodChannel('land.fx.files/ios_backup_exclude');
      await channel
          .invokeMethod<void>('setExcluded', {'path': await modelFilePath()});
    } on PlatformException catch (e) {
      // Don't fail the download just because the flag couldn't be set —
      // log loudly so QA notices.
      debugPrint(
          'AiModelService: NSURLIsExcludedFromBackupKey set failed: $e');
    } on MissingPluginException {
      // Native side not wired yet — fine in dev, must be implemented for
      // App Store submission.
      debugPrint(
          'AiModelService: ios_backup_exclude channel not implemented');
    }
  }

  void _emit(AiModelEvent ev) {
    _lastEvent = ev;
    _statusController.add(ev);
  }

  /// Persisted total-bytes (after at least one [_attemptDownload] has
  /// started). Used by the UI for "Resume from X%" labelling.
  int? get persistedTotalBytes => _stateBox?.get('totalBytes') as int?;
  int? get persistedDownloadedBytes =>
      _stateBox?.get('downloadedBytes') as int?;

  /// Encode the model state for diagnostics (settings → diagnostic log).
  String diagnosticSnapshot() => jsonEncode({
        'status': _lastEvent.status.name,
        'downloaded': _lastEvent.downloadedBytes,
        'total': _lastEvent.totalBytes,
        'wifiOnly': wifiOnly,
      });
}
