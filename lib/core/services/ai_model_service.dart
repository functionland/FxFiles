// ⚠️ HIDDEN — AI feature paused (see CreateSection's isAiEnabled gate).
// See plan: C:\Users\ehsan\.claude\plans\now-i-need-a-keen-kahan.md

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fula_files/core/services/device_memory_service.dart';
import 'package:hive_flutter/hive_flutter.dart';
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

  /// Device doesn't meet the minimum RAM requirement (<2 GB total).
  unsupported,
}

class AiModelEvent {
  final AiModelStatus status;
  final double? progressFraction;
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
/// Architecture (current, after the WorkManager attempts failed because
/// the OS pauses background HTTP IO):
///
/// **Android** uses `android.app.DownloadManager` via the platform
/// channel `land.fx.files/model_download`. DownloadManager is a system
/// service — the transfer continues in the system process even if our
/// app is killed (swipe-away, OOM kill, etc.). It's not subject to App
/// Standby or Doze the way WorkManager-based downloads are. The
/// destination is `setDestinationInExternalFilesDir(..., DIRECTORY_DOWNLOADS,
/// filename)` which lands at
/// `/storage/emulated/0/Android/data/PACKAGE/files/Download/FILENAME`.
/// We read directly from that path; no promotion-copy step is needed,
/// which avoids the disk-space gotcha (verifying + copying a 770 MB
/// file needs ~1.5 GB transient space).
///
/// **iOS** uses `URLSession` with
/// `URLSessionConfiguration.background(withIdentifier:)`. The OS daemon
/// (nsurlsessiond) runs the transfer; the app is relaunched in the
/// background on completion. (Implementation in `ios/Runner/ModelDownloadHandler.swift`.)
///
/// Integrity defenses (live in Dart so the same code runs after either
/// platform reports completion):
/// - SHA-256 pin (`_expectedSha256`) verified after download.
/// - GGUF magic-byte gate (catches corrupt-prefix bugs).
/// - Fingerprint cache: `(file size, mtime)` keyed flag in `_stateBox`
///   so the cold-start re-verify skips re-hashing 770 MB when nothing
///   has changed.
///
/// Hugging Face redirect handling: HF's `resolve/main/...` URL redirects
/// to a signed `cas-bridge.xethub.hf.co/...?X-Amz-Signature=...&X-Amz-Expires=3600`
/// URL with 1-hour expiry. DownloadManager caches the redirect target;
/// if a slow connection spans the expiry, the resume fails with HTTP
/// 403 / `ERROR_UNHANDLED_HTTP_CODE`. Detection + recovery happens in
/// the poller: on HTTP-shaped FAILED status, we `cancel()` + restart
/// from the original URL (which yields a fresh redirect). Bounded
/// retry count guards against an infinite re-enqueue loop.
class AiModelService {
  AiModelService._();
  static final AiModelService instance = AiModelService._();

  // --- Config (pinned) -------------------------------------------------

  static const String _modelFileName = 'llama-3.2-1b-instruct-q4_k_m.gguf';

  /// Source URL — bartowski's canonical Llama-3.2-1B-Instruct-Q4_K_M
  /// GGUF on Hugging Face. The `resolve/main/` path follows HF's LFS
  /// pointer to a Cloudfront-backed CDN. Pinned SHA below authoritatively
  /// validates whatever HF actually serves us.
  static const String _downloadUrl =
      'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf';

  /// SHA-256 of the canonical Q4_K_M GGUF (bartowski HF LFS pointer).
  /// Verified after every download AND re-verified on every cold start
  /// (cached via fingerprint).
  static const String _expectedSha256 =
      '6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83';

  /// Max times we'll auto-restart the download after an HTTP failure
  /// (probably HF signed-URL expiry). Beyond this we surface a hard
  /// error and let the user retry manually — three rapid restarts is
  /// likely a real server-side problem, not a transient signing issue.
  static const int _maxAutoRestart = 3;

  /// Polling interval while a download is in progress.
  static const Duration _pollInterval = Duration(seconds: 1);

  /// Platform channel — Android wraps DownloadManager, iOS wraps
  /// background URLSession. Same method names on both sides.
  static const MethodChannel _channel =
      MethodChannel('land.fx.files/model_download');

  // --- State -----------------------------------------------------------

  final _statusController = StreamController<AiModelEvent>.broadcast();
  Stream<AiModelEvent> get statusStream => _statusController.stream;

  AiModelEvent _lastEvent =
      const AiModelEvent(status: AiModelStatus.notDownloaded);
  AiModelEvent get lastEvent => _lastEvent;

  Box<dynamic>? _stateBox;
  bool _initialised = false;

  Timer? _pollTimer;
  int _autoRestartCount = 0;
  int? _activeDownloadId;

  // --- wifiOnly toggle, persisted to Hive ------------------------------

  /// User-toggleable Wi-Fi-only download mode. Persisted to `_stateBox`
  /// so the native side reads the same value the user picked in the UI.
  bool get wifiOnly => _stateBox?.get('wifiOnly', defaultValue: true) as bool;
  set wifiOnly(bool v) {
    _stateBox?.put('wifiOnly', v);
  }

  // --- Public API ------------------------------------------------------

  /// Initialise: open Hive box, reconcile any in-flight DownloadManager
  /// download that may have started/completed while the app wasn't
  /// running, and emit the current status.
  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;
    _stateBox = await Hive.openBox<dynamic>('ai_model_state');

    await DeviceMemoryService.instance.init();
    if (!DeviceMemoryService.instance.supportsOnDeviceLlm) {
      _emit(const AiModelEvent(status: AiModelStatus.unsupported));
      return;
    }

    // Reconcile native state: was a download in flight or completed
    // while we were dead?
    await _reconcileOnLaunch();
  }

  /// Returns the absolute path to the local model file. On Android this
  /// is the DownloadManager destination (in app-scoped external storage
  /// because the system download daemon can't write our internal sandbox).
  /// On other platforms, fall back to applicationSupportDirectory.
  String? _cachedModelPath;

  Future<String> modelFilePath() async {
    final cached = _cachedModelPath;
    if (cached != null) return cached;

    if (Platform.isAndroid) {
      // Round-trip to native — DownloadManager writes via
      // `setDestinationInExternalFilesDir(DIRECTORY_DOWNLOADS, filename)`
      // and only the Android side knows the absolute path that
      // resolves to. `path_provider.getExternalStorageDirectory()`
      // CAN return a different mount than the system download
      // daemon's destination on multi-user devices / external SD-card
      // setups — using it as a fallback would land us at a path
      // different from where DM actually wrote, making
      // _isModelReadyOnDisk always return false. So we fail loud
      // here instead of silently divergent.
      try {
        final path = await _channel.invokeMethod<String>('destinationPath', {
          'filename': _modelFileName,
        });
        if (path != null) {
          _cachedModelPath = path;
          return path;
        }
        throw StateError(
            'destinationPath channel returned null — native handler bug');
      } catch (e) {
        throw StateError(
            'destinationPath channel failed: $e — cannot resolve model path');
      }
    }
    // iOS + desktop: file lives in ApplicationSupport (URLSession on
    // iOS moves it there after download; desktop currently doesn't
    // have a background-download path wired).
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, _modelFileName);
    _cachedModelPath = path;
    return path;
  }

  Future<bool> isReady() => _isModelReadyOnDisk();

  /// Start the download. Idempotent: if a download is already in flight
  /// (live downloadId in the native side's persisted prefs), we just
  /// hook up the poller and emit progress. If the file is already on
  /// disk and verified, returns immediately as ready.
  ///
  /// Refuses on devices that don't meet the minimum RAM requirement.
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

    if (!Platform.isAndroid && !Platform.isIOS) {
      // Desktop platforms don't have a native background-download API
      // wired yet. Surface an error so the UI can route to a different
      // path (or just disable the feature on those builds).
      _emit(const AiModelEvent(
        status: AiModelStatus.error,
        errorMessage: 'Background download not implemented on this platform',
      ));
      return;
    }

    _autoRestartCount = 0;
    await _enqueueAndPoll();
  }

  Future<void> cancelDownload() async {
    _stopPolling();
    try {
      await _channel.invokeMethod<bool>('cancel');
    } catch (e) {
      debugPrint('AiModelService: cancel channel failed: $e');
    }
    _activeDownloadId = null;
    _emit(const AiModelEvent(status: AiModelStatus.notDownloaded));
  }

  /// Delete the model file + reset state. Useful when the user wants to
  /// reclaim disk space or after a corrupt download.
  Future<void> deleteModel() async {
    await cancelDownload();
    final f = File(await modelFilePath());
    if (await f.exists()) {
      await f.delete();
    }
    await _stateBox?.delete('downloadedBytes');
    await _stateBox?.delete('totalBytes');
    await _stateBox?.delete('validatedFingerprint');
    _emit(const AiModelEvent(status: AiModelStatus.notDownloaded));
  }

  /// Public probe used by [LocalLlmService] as a last-line defense
  /// before invoking fllama. Returns false on missing or corrupt files
  /// so the caller can degrade to the heuristic path with a clear
  /// error rather than letting the native loader SIGSEGV.
  Future<bool> isModelFileValid() async {
    final f = File(await modelFilePath());
    if (!await f.exists()) return false;
    return _hasGgufMagic(f);
  }

  /// Persisted total-bytes (last reported by native side). UI uses for
  /// "Resume from X%" labelling on cold start.
  int? get persistedTotalBytes => _stateBox?.get('totalBytes') as int?;
  int? get persistedDownloadedBytes =>
      _stateBox?.get('downloadedBytes') as int?;

  // --- Internal: enqueue + poll ----------------------------------------

  Future<void> _enqueueAndPoll() async {
    try {
      final id = await _channel.invokeMethod<dynamic>('start', {
        'url': _downloadUrl,
        'filename': _modelFileName,
        'wifiOnly': wifiOnly,
        'expectedSha': _expectedSha256,
        'title': 'Downloading AI model',
        'description': 'Llama 3.2 1B (~770 MB)',
      });
      _activeDownloadId = (id as num).toInt();
      debugPrint('AiModelService: native enqueue returned id=$_activeDownloadId');
      _startPolling();
    } catch (e, st) {
      debugPrint('AiModelService: start channel failed: $e\n$st');
      _emit(AiModelEvent(
        status: AiModelStatus.error,
        errorMessage: 'Failed to start download: $e',
      ));
    }
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollOnce());
    // Also poll immediately so the UI doesn't have a 1-second blank
    // frame between tap and first progress update.
    unawaited(_pollOnce());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollOnce() async {
    try {
      final res = await _channel.invokeMethod<dynamic>('query', {
        if (_activeDownloadId != null) 'downloadId': _activeDownloadId,
      });
      if (res is! Map) return;
      final m = Map<String, dynamic>.from(res);
      final status = m['status'] as String? ?? 'unknown';
      final downloaded = (m['bytesDownloaded'] as num?)?.toInt() ?? 0;
      final totalRaw = (m['totalBytes'] as num?)?.toInt() ?? -1;
      final total = totalRaw > 0 ? totalRaw : null;
      final localUri = m['localUri'] as String?;
      final reasonText = m['reasonText'] as String?;

      if (total != null) await _stateBox?.put('totalBytes', total);
      await _stateBox?.put('downloadedBytes', downloaded);

      switch (status) {
        case 'pending':
        case 'running':
          _emit(AiModelEvent(
            status: AiModelStatus.downloading,
            progressFraction:
                total != null && total > 0 ? downloaded / total : null,
            downloadedBytes: downloaded,
            totalBytes: total,
          ));
          break;
        case 'paused':
          // DM paused: waiting for Wi-Fi, network, or retry. Still
          // counts as in-progress from the user's perspective —
          // surface as paused so the UI can show the reason.
          _emit(AiModelEvent(
            status: AiModelStatus.paused,
            progressFraction:
                total != null && total > 0 ? downloaded / total : null,
            downloadedBytes: downloaded,
            totalBytes: total,
            errorMessage: reasonText,
          ));
          break;
        case 'successful':
          _stopPolling();
          await _onDownloadSucceeded(localUri);
          break;
        case 'failed':
          await _onDownloadFailed(reasonText, downloaded);
          break;
        case 'unknown':
        default:
          // No row in DM — could mean the user canceled, or DM evicted
          // the entry. Stop polling. Caller can re-tap to retry.
          _stopPolling();
          _activeDownloadId = null;
          break;
      }
    } catch (e) {
      debugPrint('AiModelService: poll error: $e');
    }
  }

  Future<void> _onDownloadSucceeded(String? localUri) async {
    debugPrint('AiModelService: native reports SUCCESSFUL — verifying integrity');
    // localUri is e.g. content://downloads/... — we don't need it; the
    // file is at modelFilePath() which mirrors DM's destination.
    final ok = await _isModelReadyOnDisk();
    if (ok) {
      _activeDownloadId = null;
      _autoRestartCount = 0;
      // Set the NSURLIsExcludedFromBackupKey on a freshly-downloaded
      // file. Must run once per fresh file, not on every cold-start
      // verify (the channel call there would be wasteful).
      await _excludeFromIosBackupIfApplicable();
      _emit(const AiModelEvent(status: AiModelStatus.ready));
      return;
    }
    // The file is there but failed magic / SHA. Wipe and surface
    // error — user can retry. Note: deleteModel() also calls
    // cancel() which clears native state, so the next start() is fresh.
    debugPrint('AiModelService: post-download verification failed');
    await deleteModel();
    _emit(const AiModelEvent(
      status: AiModelStatus.error,
      errorMessage:
          'Downloaded model failed integrity check. Tap Retry to fetch again.',
    ));
  }

  Future<void> _onDownloadFailed(String? reasonText, int downloaded) async {
    debugPrint('AiModelService: native reports FAILED (reason=$reasonText, '
        'downloaded=$downloaded bytes)');
    _stopPolling();
    _activeDownloadId = null;

    // Heuristic: HTTP-shaped failures are almost always Hugging Face's
    // signed-CDN URL expiring mid-download. The fix is to remove the
    // failed entry and re-enqueue with the original `resolve/main/`
    // URL, which causes HF to issue a fresh signed redirect. Bounded
    // retry count guards against an infinite loop if something more
    // permanent is wrong (server outage, bad SHA pin, etc.).
    final isHttpReason = reasonText != null &&
        (reasonText.contains('HTTP') ||
            reasonText.contains('CANNOT_RESUME') ||
            reasonText.contains('TOO_MANY_REDIRECTS'));
    if (isHttpReason && _autoRestartCount < _maxAutoRestart) {
      _autoRestartCount++;
      debugPrint('AiModelService: auto-restart $_autoRestartCount/'
          '$_maxAutoRestart after HTTP-shaped failure');
      try {
        await _channel.invokeMethod<bool>('cancel');
      } catch (_) {}
      // Brief delay so the system has time to release the cancelled
      // job before we re-enqueue.
      await Future.delayed(const Duration(seconds: 2));
      await _enqueueAndPoll();
      return;
    }

    final msg = reasonText != null
        ? 'Download failed: $reasonText'
        : 'Download failed';
    _emit(AiModelEvent(
      status: AiModelStatus.error,
      errorMessage: msg,
    ));
  }

  // --- Launch reconciliation -------------------------------------------

  /// Read native persisted state at app start: was a download in flight
  /// (or did one complete) while we were dead? Per both advisors:
  /// "broadcasts are wakeups; query state is truth" — we re-query the
  /// native side rather than trusting any single signal.
  Future<void> _reconcileOnLaunch() async {
    // First check the model file directly. If it's on disk and passes
    // the magic + SHA fingerprint, we're ready regardless of what the
    // native side says.
    if (await _isModelReadyOnDisk()) {
      _emit(const AiModelEvent(status: AiModelStatus.ready));
      return;
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      _emit(const AiModelEvent(status: AiModelStatus.notDownloaded));
      return;
    }

    // Native query without a downloadId returns whatever the native
    // side has persisted in SharedPreferences / UserDefaults.
    try {
      final res = await _channel.invokeMethod<dynamic>('query');
      if (res is Map) {
        final m = Map<String, dynamic>.from(res);
        final status = m['status'] as String? ?? 'unknown';
        switch (status) {
          case 'pending':
          case 'running':
          case 'paused':
            // A download is in flight from a previous session. Resume
            // polling — it'll keep ticking until completion or failure.
            debugPrint('AiModelService: reconciled in-flight download '
                '(status=$status)');
            _emit(AiModelEvent(
              status: status == 'paused'
                  ? AiModelStatus.paused
                  : AiModelStatus.downloading,
            ));
            _startPolling();
            return;
          case 'successful':
            // Native says done but file failed our verification above.
            // Could be: download finished but failed SHA, or the file
            // was deleted/moved. Either way, surface notDownloaded so
            // the user can re-download.
            debugPrint('AiModelService: native reports successful but file '
                'failed integrity — resetting');
            await deleteModel();
            return;
          case 'failed':
            final reasonText = m['reasonText'] as String?;
            _emit(AiModelEvent(
              status: AiModelStatus.error,
              errorMessage: reasonText != null
                  ? 'Previous download failed: $reasonText'
                  : 'Previous download failed',
            ));
            return;
        }
      }
    } catch (e) {
      debugPrint('AiModelService: launch reconcile query failed: $e');
    }

    // No native state — fresh install / never downloaded.
    _emit(const AiModelEvent(status: AiModelStatus.notDownloaded));
  }

  // --- File integrity helpers (unchanged from prior implementation) ----

  Future<bool> _isModelReadyOnDisk() async {
    final f = File(await modelFilePath());
    if (!await f.exists()) return false;
    final size = await f.length();
    // Don't trust totalBytes (it's whatever native last reported).
    // Use size > 0 + magic + SHA as the truth.
    if (size <= 0) return false;

    if (!await _hasGgufMagic(f)) {
      debugPrint('AiModelService: file present but magic bytes wrong '
          '— treating as not ready');
      return false;
    }

    if (_expectedSha256.isEmpty) {
      debugPrint('AiModelService: _expectedSha256 is empty — refusing to '
          'mark model ready without a pinned hash');
      return false;
    }
    final mtime = (await f.lastModified()).millisecondsSinceEpoch;
    final fingerprint = '$size:$mtime';
    final cached = _stateBox?.get('validatedFingerprint') as String?;
    if (cached == fingerprint) return true;

    final ok = await _verifySha256();
    if (!ok) {
      debugPrint('AiModelService: SHA-256 mismatch — file is corrupt '
          'or wrong version');
      return false;
    }
    await _stateBox?.put('validatedFingerprint', fingerprint);
    await _stateBox?.put('totalBytes', size);
    return true;
  }

  /// Returns true if the first 4 bytes of [f] are the GGUF magic
  /// (`G`, `G`, `U`, `F`). Used as a cheap integrity check before
  /// trusting a file — fllama's native loader segfaults rather than
  /// returning an error on a bad header.
  Future<bool> _hasGgufMagic(File f) async {
    try {
      final chunks = await f.openRead(0, 4).toList();
      final bytes = chunks.expand((c) => c).toList();
      return bytes.length >= 4 &&
          bytes[0] == 0x47 && // 'G'
          bytes[1] == 0x47 && // 'G'
          bytes[2] == 0x55 && // 'U'
          bytes[3] == 0x46;   // 'F'
    } catch (_) {
      return false;
    }
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
      await channel.invokeMethod<void>(
          'setExcluded', {'path': await modelFilePath()});
    } on PlatformException catch (e) {
      debugPrint(
          'AiModelService: NSURLIsExcludedFromBackupKey set failed: $e');
    } on MissingPluginException {
      debugPrint(
          'AiModelService: ios_backup_exclude channel not implemented');
    }
  }

  // --- Emitter ---------------------------------------------------------

  void _emit(AiModelEvent ev) {
    _lastEvent = ev;
    _statusController.add(ev);
  }
}
