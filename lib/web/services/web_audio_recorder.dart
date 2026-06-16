import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/web/services/web_camera_capture.dart' show CapturedFile;

/// Microphone recording for the web shelf via the `MediaRecorder` API.
///
/// There is no input-element shortcut for "record audio" (unlike the
/// camera's `capture` attribute), so this drives `getUserMedia` +
/// `MediaRecorder` directly. The output container/codec is whatever the
/// browser supports (Chrome → webm/opus, Safari → mp4/aac); the produced
/// [CapturedFile] carries the actual mime so the shelf classifier routes
/// it to the Audio category and playback picks the right decoder.
class WebAudioRecorder {
  web.MediaStream? _stream;
  web.MediaRecorder? _recorder;
  final List<web.Blob> _chunks = <web.Blob>[];
  String _mime = 'audio/webm';
  DateTime? _startedAt;
  Completer<CapturedFile>? _stopCompleter;

  bool get isRecording => _recorder != null;

  Duration get elapsed =>
      _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  /// First container the browser can actually record. Empty string → let
  /// MediaRecorder choose its default.
  static String _pickMime() {
    const candidates = <String>[
      'audio/webm;codecs=opus',
      'audio/webm',
      'audio/mp4',
      'audio/ogg;codecs=opus',
      'audio/ogg',
    ];
    for (final c in candidates) {
      try {
        if (web.MediaRecorder.isTypeSupported(c)) return c;
      } catch (_) {/* isTypeSupported can throw on odd inputs */}
    }
    return '';
  }

  /// Requests the mic (prompts on first use) and starts recording.
  /// Throws if permission is denied or no mic is available — the caller
  /// surfaces that to the user.
  Future<void> start() async {
    final constraints = web.MediaStreamConstraints(audio: true.toJS);
    final stream =
        await web.window.navigator.mediaDevices.getUserMedia(constraints).toDart;
    _stream = stream;

    final picked = _pickMime();
    _mime = picked.isNotEmpty ? picked : 'audio/webm';
    final recorder = picked.isNotEmpty
        ? web.MediaRecorder(stream, web.MediaRecorderOptions(mimeType: picked))
        : web.MediaRecorder(stream);
    _recorder = recorder;
    _chunks.clear();

    recorder.addEventListener(
      'dataavailable',
      (web.Event e) {
        final blob = (e as web.BlobEvent).data;
        if (blob.size > 0) _chunks.add(blob);
      }.toJS,
    );
    recorder.addEventListener(
      'stop',
      (web.Event _) {
        unawaited(_finalize());
      }.toJS,
    );

    _startedAt = DateTime.now();
    recorder.start();
  }

  /// Stops recording and resolves with the assembled audio bytes.
  Future<CapturedFile> stop() {
    final completer = Completer<CapturedFile>();
    _stopCompleter = completer;
    final recorder = _recorder;
    if (recorder == null) {
      completer.completeError(StateError('Not recording'));
      return completer.future;
    }
    try {
      recorder.stop(); // fires final `dataavailable`, then `stop` → _finalize
    } catch (e) {
      completer.completeError(e);
    }
    return completer.future;
  }

  /// Abort without producing a file (user cancelled / dialog dismissed).
  void dispose() {
    try {
      if (_recorder != null && _recorder!.state != 'inactive') {
        _recorder!.stop();
      }
    } catch (_) {/* best effort */}
    _stopTracks();
    _recorder = null;
    _startedAt = null;
    _chunks.clear();
  }

  Future<void> _finalize() async {
    final completer = _stopCompleter;
    try {
      final base = _mime.split(';').first; // strip ;codecs=… for type + ext
      final blob = web.Blob(
        _chunks.cast<JSAny>().toJS,
        web.BlobPropertyBag(type: base),
      );
      final buffer = await blob.arrayBuffer().toDart;
      final bytes = buffer.toDart.asUint8List();
      _stopTracks();
      final name = 'Recording ${_stamp()}.${_extFor(base)}';
      completer?.complete((bytes: bytes, name: name, mime: base));
    } catch (e) {
      debugPrint('WebAudioRecorder._finalize failed: $e');
      completer?.completeError(e);
    } finally {
      _recorder = null;
      _startedAt = null;
    }
  }

  void _stopTracks() {
    final stream = _stream;
    if (stream == null) return;
    for (final track in stream.getTracks().toDart) {
      try {
        track.stop();
      } catch (_) {/* best effort */}
    }
    _stream = null;
  }

  static String _extFor(String mime) {
    if (mime.contains('mp4')) return 'm4a';
    if (mime.contains('ogg')) return 'ogg';
    return 'webm';
  }

  static String _stamp() => DateTime.now()
      .toIso8601String()
      .substring(0, 19)
      .replaceFirst('T', ' ')
      .replaceAll(':', '-');
}
