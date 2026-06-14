import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'package:fula_files/web/services/web_audio_queue.dart';
import 'package:fula_files/web/services/web_save.dart';

/// One queue item for the web audio player. [download] fetches the decrypted
/// bytes (the source — a bucket object or a playlist track — is captured by
/// the closure, so the controller is source-agnostic); [cloudKey] is the
/// object key to persist when adding this track to a playlist.
class WebAudioTrack {
  final String name;
  final String mime;
  final String cloudKey;
  final Future<Uint8List> Function() download;
  const WebAudioTrack({
    required this.name,
    required this.mime,
    required this.cloudKey,
    required this.download,
  });
}

/// Drives web audio playback over a queue: download → Blob object URL →
/// just_audio `setUrl` → play, advancing per repeat / shuffle. Blob URLs are
/// revoked aggressively (a queue creates many over its life — an unrevoked
/// blob leaks and can crash mobile browsers). Pure transitions come from
/// web_audio_queue.dart; this is the browser playback glue.
class WebAudioController extends ChangeNotifier {
  WebAudioController._() {
    _player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) _onComplete();
    });
  }

  /// App-lifetime singleton so playback survives closing the full-screen
  /// player; a global mini-player keeps it controllable. The player and its
  /// stream subscription live for the app's lifetime and are never disposed
  /// (use [stopPlayback] to halt + clear).
  static final WebAudioController instance = WebAudioController._();

  final AudioPlayer _player = AudioPlayer();
  AudioPlayer get player => _player;

  List<WebAudioTrack> _queue = const [];
  List<WebAudioTrack> _originalOrder = const [];
  int _index = -1;
  WebRepeatMode _repeat = WebRepeatMode.off;
  bool _shuffle = false;

  /// True while the full-screen player is open (the mini-player hides then).
  bool _expanded = false;

  String? _currentBlobUrl;
  int _loadToken = 0; // guards against out-of-order async loads

  final Random _rng = Random();

  List<WebAudioTrack> get queue => _queue;
  int get index => _index;
  WebAudioTrack? get current =>
      (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;
  WebRepeatMode get repeatMode => _repeat;
  bool get shuffle => _shuffle;
  bool get isExpanded => _expanded;

  void setExpanded(bool v) {
    if (_expanded == v) return;
    _expanded = v;
    notifyListeners();
  }

  Future<void> playQueue(List<WebAudioTrack> tracks, int startIndex) async {
    _originalOrder = List.of(tracks);
    _queue = List.of(tracks);
    _index = (startIndex >= 0 && startIndex < _queue.length) ? startIndex : 0;
    if (_shuffle) _applyShuffle();
    notifyListeners();
    await _loadAndPlay(_index);
  }

  Future<void> jumpTo(int i) => _loadAndPlay(i);

  Future<void> _loadAndPlay(int i) async {
    if (i < 0 || i >= _queue.length) return;
    _index = i;
    notifyListeners();
    final token = ++_loadToken;
    final track = _queue[i];
    try {
      final bytes = await track.download();
      if (token != _loadToken) return; // superseded by a newer load
      _swapBlob(createBlobUrl(bytes, mimeType: track.mime));
      await _player.setUrl(_currentBlobUrl!);
      if (token != _loadToken) return;
      await _player.play();
    } catch (e) {
      debugPrint('WebAudioController._loadAndPlay($i): $e');
    }
  }

  /// Adopt [url] as the current blob and revoke the previous one immediately.
  void _swapBlob(String url) {
    final old = _currentBlobUrl;
    _currentBlobUrl = url;
    if (old != null) {
      try {
        revokeBlobUrl(old);
      } catch (_) {}
    }
  }

  void _onComplete() {
    final next = nextIndexOnComplete(_index, _queue.length, _repeat);
    if (next == null) return; // end of queue, no repeat → stop
    if (next == _index) {
      // repeat-one → replay without re-downloading the same blob.
      _player.seek(Duration.zero);
      _player.play();
    } else {
      _loadAndPlay(next);
    }
  }

  Future<void> playPause() =>
      _player.playing ? _player.pause() : _player.play();

  Future<void> next() async {
    final n = nextIndexManual(_index, _queue.length, _repeat);
    if (n != null) await _loadAndPlay(n);
  }

  Future<void> previous() async {
    // Past the first few seconds → restart the track, else go to the previous.
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    await _loadAndPlay(prevIndexManual(_index, _queue.length, _repeat));
  }

  Future<void> seek(Duration d) => _player.seek(d);

  Future<void> rewind() async {
    final p = _player.position - const Duration(seconds: 10);
    await _player.seek(p < Duration.zero ? Duration.zero : p);
  }

  Future<void> forward() async {
    final dur = _player.duration ?? Duration.zero;
    final p = _player.position + const Duration(seconds: 10);
    await _player.seek(p > dur ? dur : p);
  }

  void cycleRepeat() {
    _repeat = nextRepeatMode(_repeat);
    notifyListeners();
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    if (_shuffle) {
      _applyShuffle();
    } else {
      _restoreOrder();
    }
    notifyListeners();
  }

  /// Find a track by its stable cloudKey (more robust than identity, which
  /// would break if a caller ever rebuilt the track list — advisor: Gemini).
  int _indexOfKey(List<WebAudioTrack> list, String? key) {
    if (key == null) return -1;
    for (var i = 0; i < list.length; i++) {
      if (list[i].cloudKey == key) return i;
    }
    return -1;
  }

  /// Reorder [_queue] to a shuffle of the original order with the current
  /// track first (so playback doesn't jump), mirroring native.
  void _applyShuffle() {
    if (_originalOrder.isEmpty) return;
    final curKey = current?.cloudKey;
    final order = buildShuffleOrder(
        _originalOrder.length, _indexOfKey(_originalOrder, curKey), _rng);
    _queue = [for (final i in order) _originalOrder[i]];
    final ni = _indexOfKey(_queue, curKey);
    _index = ni < 0 ? 0 : ni;
  }

  void _restoreOrder() {
    final curKey = current?.cloudKey;
    _queue = List.of(_originalOrder);
    final ni = _indexOfKey(_queue, curKey);
    _index = ni < 0 ? 0 : ni;
  }

  /// Stop and clear playback (mini-player close / sign-out) WITHOUT disposing
  /// the singleton: cancel any in-flight load, pause, drop the queue, revoke
  /// the blob. The player stays alive for the next [playQueue].
  void stopPlayback() {
    _loadToken++; // cancel any in-flight load
    _player.pause();
    _player.seek(Duration.zero);
    final url = _currentBlobUrl;
    _currentBlobUrl = null;
    if (url != null) {
      try {
        revokeBlobUrl(url);
      } catch (_) {}
    }
    _queue = const [];
    _originalOrder = const [];
    _index = -1;
    _expanded = false;
    notifyListeners();
  }
}
