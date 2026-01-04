import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:rxdart/rxdart.dart';
import 'package:fula_files/core/models/playlist.dart';

enum RepeatMode { off, one, all }

/// Status of notification permission
enum NotificationPermissionStatus {
  /// Permission granted - notifications will show
  granted,
  /// Permission denied but can be requested again
  denied,
  /// Permission permanently denied - must open settings
  permanentlyDenied,
  /// Not applicable (Android < 13 or non-Android platform)
  notRequired,
}

class AudioPlayerService {
  AudioPlayerService._();
  static final AudioPlayerService instance = AudioPlayerService._();

  static const _notificationChannel = MethodChannel('land.fx.files/notification');

  late AudioPlayer _player;
  AudioHandler? _audioHandler;
  bool _isInitialized = false;
  bool _isInitializing = false;

  // Notification permission state
  final _notificationPermissionSubject = BehaviorSubject<NotificationPermissionStatus>.seeded(
    NotificationPermissionStatus.notRequired,
  );

  /// Stream of notification permission status changes
  Stream<NotificationPermissionStatus> get notificationPermissionStream =>
      _notificationPermissionSubject.stream;

  /// Current notification permission status
  NotificationPermissionStatus get notificationPermissionStatus =>
      _notificationPermissionSubject.value;

  // Current playback state
  final _currentTrackSubject = BehaviorSubject<AudioTrack?>.seeded(null);
  final _playlistSubject = BehaviorSubject<List<AudioTrack>>.seeded([]);
  final _currentIndexSubject = BehaviorSubject<int>.seeded(-1);
  final _isPlayingSubject = BehaviorSubject<bool>.seeded(false);
  final _repeatModeSubject = BehaviorSubject<RepeatMode>.seeded(RepeatMode.off);
  final _shuffleModeSubject = BehaviorSubject<bool>.seeded(false);
  final _positionSubject = BehaviorSubject<Duration>.seeded(Duration.zero);
  final _durationSubject = BehaviorSubject<Duration?>.seeded(null);
  final _bufferingSubject = BehaviorSubject<bool>.seeded(false);
  final _playlistNameSubject = BehaviorSubject<String?>.seeded(null);

  // Original playlist order (for unshuffle)
  List<AudioTrack> _originalOrder = [];
  List<int> _shuffledIndices = [];

  // Equalizer state
  final _equalizerEnabledSubject = BehaviorSubject<bool>.seeded(false);
  final _bassSubject = BehaviorSubject<double>.seeded(0.0);
  final _midSubject = BehaviorSubject<double>.seeded(0.0);
  final _trebleSubject = BehaviorSubject<double>.seeded(0.0);

  // Public streams
  Stream<AudioTrack?> get currentTrackStream => _currentTrackSubject.stream;
  Stream<List<AudioTrack>> get playlistStream => _playlistSubject.stream;
  Stream<int> get currentIndexStream => _currentIndexSubject.stream;
  Stream<bool> get isPlayingStream => _isPlayingSubject.stream;
  Stream<RepeatMode> get repeatModeStream => _repeatModeSubject.stream;
  Stream<bool> get shuffleModeStream => _shuffleModeSubject.stream;
  Stream<Duration> get positionStream => _positionSubject.stream;
  Stream<Duration?> get durationStream => _durationSubject.stream;
  Stream<bool> get bufferingStream => _bufferingSubject.stream;
  Stream<String?> get playlistNameStream => _playlistNameSubject.stream;
  Stream<bool> get equalizerEnabledStream => _equalizerEnabledSubject.stream;
  Stream<double> get bassStream => _bassSubject.stream;
  Stream<double> get midStream => _midSubject.stream;
  Stream<double> get trebleStream => _trebleSubject.stream;

  // Current values
  AudioTrack? get currentTrack => _currentTrackSubject.value;
  List<AudioTrack> get playlist => _playlistSubject.value;
  int get currentIndex => _currentIndexSubject.value;
  bool get isPlaying => _isPlayingSubject.value;
  RepeatMode get repeatMode => _repeatModeSubject.value;
  bool get shuffleMode => _shuffleModeSubject.value;
  Duration get position => _positionSubject.value;
  Duration? get duration => _durationSubject.value;
  bool get hasNext => currentIndex < playlist.length - 1 || repeatMode == RepeatMode.all;
  bool get hasPrevious => currentIndex > 0 || repeatMode == RepeatMode.all;
  bool get hasActiveTrack => currentTrack != null;
  String? get playlistName => _playlistNameSubject.value;

  AudioPlayer get player => _player;

  Future<void> init() async {
    if (_isInitialized) return;
    if (_isInitializing) return;
    _isInitializing = true;

    try {
      _player = AudioPlayer();

      // Initialize audio session
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      // Request notification permission for Android 13+ (API 33+)
      // This is required for media playback notification to appear
      await _requestNotificationPermission();

      // Initialize audio handler for background playback
      try {
        _audioHandler = await AudioService.init(
          builder: () => _AudioPlayerHandler(_player, this),
          config: const AudioServiceConfig(
            androidNotificationChannelId: 'land.fx.files.audio',
            androidNotificationChannelName: 'FxFiles Audio',
            androidNotificationOngoing: true,
            androidStopForegroundOnPause: true,
          ),
        );
      } catch (e) {
        // AudioService may fail on some devices, continue without it
        debugPrint('AudioService.init failed (background playback disabled): $e');
      }

      // Listen to player state changes
      _player.playerStateStream.listen((state) {
        _isPlayingSubject.add(state.playing);
        _bufferingSubject.add(
          state.processingState == ProcessingState.buffering ||
          state.processingState == ProcessingState.loading
        );

        // Handle track completion
        if (state.processingState == ProcessingState.completed) {
          _handleTrackComplete();
        }
      });

      _player.positionStream.listen((position) {
        _positionSubject.add(position);
      });

      _player.durationStream.listen((duration) {
        _durationSubject.add(duration);
        // Update MediaItem with actual duration for lock screen progress bar
        if (duration != null && _audioHandler != null && _currentTrackSubject.value != null) {
          final track = _currentTrackSubject.value!;
          _audioHandler!.updateMediaItem(MediaItem(
            id: track.path,
            title: track.name,
            artist: track.artist ?? 'Unknown Artist',
            album: track.album ?? 'Unknown Album',
            duration: duration,
          ));
        }
      });

      _isInitialized = true;
      debugPrint('AudioPlayerService initialized');
    } catch (e) {
      debugPrint('AudioPlayerService.init error: $e');
    } finally {
      _isInitializing = false;
    }
  }

  /// Request notification permission for Android 13+ (API 33+)
  /// This is required for media playback notification to appear in status bar and lock screen
  /// Returns the permission status after the request
  Future<NotificationPermissionStatus> _requestNotificationPermission() async {
    if (!Platform.isAndroid) {
      _notificationPermissionSubject.add(NotificationPermissionStatus.notRequired);
      return NotificationPermissionStatus.notRequired;
    }

    try {
      // Check if Android 13+ (API 33+)
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt < 33) {
        debugPrint('Android < 13, notification permission not required');
        _notificationPermissionSubject.add(NotificationPermissionStatus.notRequired);
        return NotificationPermissionStatus.notRequired;
      }

      // Check current permission status
      final status = await Permission.notification.status;
      debugPrint('Notification permission status: $status');

      if (status.isGranted) {
        debugPrint('Notification permission already granted');
        _notificationPermissionSubject.add(NotificationPermissionStatus.granted);
        return NotificationPermissionStatus.granted;
      }

      if (status.isPermanentlyDenied) {
        debugPrint('Notification permission permanently denied - user must enable in settings');
        _notificationPermissionSubject.add(NotificationPermissionStatus.permanentlyDenied);
        return NotificationPermissionStatus.permanentlyDenied;
      }

      // Request the permission
      final result = await Permission.notification.request();
      debugPrint('Notification permission request result: $result');

      if (result.isGranted) {
        _notificationPermissionSubject.add(NotificationPermissionStatus.granted);
        return NotificationPermissionStatus.granted;
      } else if (result.isPermanentlyDenied) {
        _notificationPermissionSubject.add(NotificationPermissionStatus.permanentlyDenied);
        return NotificationPermissionStatus.permanentlyDenied;
      } else {
        _notificationPermissionSubject.add(NotificationPermissionStatus.denied);
        return NotificationPermissionStatus.denied;
      }
    } catch (e) {
      debugPrint('Error requesting notification permission: $e');
      _notificationPermissionSubject.add(NotificationPermissionStatus.denied);
      return NotificationPermissionStatus.denied;
    }
  }

  /// Check the current notification permission status without requesting
  Future<NotificationPermissionStatus> checkNotificationPermission() async {
    if (!Platform.isAndroid) {
      return NotificationPermissionStatus.notRequired;
    }

    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt < 33) {
        return NotificationPermissionStatus.notRequired;
      }

      final status = await Permission.notification.status;
      if (status.isGranted) {
        return NotificationPermissionStatus.granted;
      } else if (status.isPermanentlyDenied) {
        return NotificationPermissionStatus.permanentlyDenied;
      } else {
        return NotificationPermissionStatus.denied;
      }
    } catch (e) {
      debugPrint('Error checking notification permission: $e');
      return NotificationPermissionStatus.denied;
    }
  }

  /// Open the system notification settings for this app
  /// Use this when permission is permanently denied
  Future<bool> openNotificationSettings() async {
    if (!Platform.isAndroid) return false;

    try {
      final result = await _notificationChannel.invokeMethod<bool>('openNotificationSettings');
      return result ?? false;
    } catch (e) {
      debugPrint('Error opening notification settings: $e');
      // Fallback to general app settings
      await openAppSettings();
      return true;
    }
  }

  void _handleTrackComplete() {
    switch (repeatMode) {
      case RepeatMode.one:
        _player.seek(Duration.zero);
        _player.play();
        break;
      case RepeatMode.all:
        if (currentIndex >= playlist.length - 1) {
          skipToIndex(0);
        } else {
          skipToNext();
        }
        break;
      case RepeatMode.off:
        if (currentIndex < playlist.length - 1) {
          skipToNext();
        }
        break;
    }
  }

  Future<void> playTrack(AudioTrack track, {List<AudioTrack>? playlist, String? playlistName}) async {
    await init();

    if (playlist != null && playlist.isNotEmpty) {
      _originalOrder = List.from(playlist);
      _playlistSubject.add(List.from(playlist));
      _playlistNameSubject.add(playlistName);

      final index = playlist.indexOf(track);
      _currentIndexSubject.add(index >= 0 ? index : 0);

      if (shuffleMode) {
        _shufflePlaylist(keepCurrent: true);
      }
    } else {
      _originalOrder = [track];
      _playlistSubject.add([track]);
      _currentIndexSubject.add(0);
      _playlistNameSubject.add(null);
    }

    await _loadAndPlayTrack(track);
  }

  Future<void> playPlaylist(Playlist playlist, {int startIndex = 0}) async {
    await init();

    final tracks = playlist.tracks;
    if (tracks.isEmpty) return;

    _originalOrder = List.from(tracks);
    _playlistSubject.add(List.from(tracks));
    _playlistNameSubject.add(playlist.name);

    if (shuffleMode) {
      _shufflePlaylist(keepCurrent: true);
      _currentIndexSubject.add(0);
    } else {
      _currentIndexSubject.add(startIndex.clamp(0, tracks.length - 1));
    }

    await _loadAndPlayTrack(_playlistSubject.value[_currentIndexSubject.value]);
  }

  Future<void> _loadAndPlayTrack(AudioTrack track) async {
    _currentTrackSubject.add(track);

    try {
      await _player.setFilePath(track.path);
      await _player.play();

      // Get the actual duration from the player
      final actualDuration = _player.duration;

      // Update media item for notification (if audio service is available)
      if (_audioHandler != null) {
        await _audioHandler!.updateMediaItem(MediaItem(
          id: track.path,
          title: track.name,
          artist: track.artist ?? 'Unknown Artist',
          album: track.album ?? 'Unknown Album',
          duration: actualDuration ?? Duration(milliseconds: track.durationMs),
        ));
      }
    } catch (e) {
      debugPrint('Error loading track: $e');
    }
  }

  Future<void> play() async {
    await _player.play();
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> playPause() async {
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> stop() async {
    await _player.stop();
    _currentTrackSubject.add(null);
    _playlistSubject.add([]);
    _currentIndexSubject.add(-1);
    _playlistNameSubject.add(null);
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> seekForward([Duration amount = const Duration(seconds: 10)]) async {
    final newPos = _player.position + amount;
    final duration = _player.duration ?? Duration.zero;
    await _player.seek(newPos > duration ? duration : newPos);
  }

  Future<void> seekBackward([Duration amount = const Duration(seconds: 10)]) async {
    final newPos = _player.position - amount;
    await _player.seek(newPos < Duration.zero ? Duration.zero : newPos);
  }

  Future<void> skipToNext() async {
    if (playlist.isEmpty) return;

    int nextIndex;
    if (currentIndex >= playlist.length - 1) {
      if (repeatMode == RepeatMode.all) {
        nextIndex = 0;
      } else {
        return;
      }
    } else {
      nextIndex = currentIndex + 1;
    }

    await skipToIndex(nextIndex);
  }

  Future<void> skipToPrevious() async {
    if (playlist.isEmpty) return;

    // If we're more than 3 seconds into the track, restart it
    if (_player.position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }

    int prevIndex;
    if (currentIndex <= 0) {
      if (repeatMode == RepeatMode.all) {
        prevIndex = playlist.length - 1;
      } else {
        await seek(Duration.zero);
        return;
      }
    } else {
      prevIndex = currentIndex - 1;
    }

    await skipToIndex(prevIndex);
  }

  Future<void> skipToIndex(int index) async {
    if (index < 0 || index >= playlist.length) return;

    _currentIndexSubject.add(index);
    await _loadAndPlayTrack(playlist[index]);
  }

  void toggleRepeatMode() {
    final modes = RepeatMode.values;
    final nextIndex = (modes.indexOf(repeatMode) + 1) % modes.length;
    _repeatModeSubject.add(modes[nextIndex]);
  }

  void setRepeatMode(RepeatMode mode) {
    _repeatModeSubject.add(mode);
  }

  void toggleShuffle() {
    final newShuffleMode = !shuffleMode;
    _shuffleModeSubject.add(newShuffleMode);

    if (newShuffleMode) {
      _shufflePlaylist(keepCurrent: true);
    } else {
      _unshufflePlaylist();
    }
  }

  void _shufflePlaylist({bool keepCurrent = false}) {
    if (playlist.isEmpty) return;

    final current = currentTrack;
    final tracks = List<AudioTrack>.from(playlist);

    // Create shuffled indices
    _shuffledIndices = List.generate(tracks.length, (i) => i);
    _shuffledIndices.shuffle(Random());

    if (keepCurrent && current != null) {
      // Move current track to the front
      final currentOriginalIndex = _originalOrder.indexOf(current);
      _shuffledIndices.remove(currentOriginalIndex);
      _shuffledIndices.insert(0, currentOriginalIndex);
    }

    // Reorder tracks based on shuffled indices
    final shuffledTracks = _shuffledIndices.map((i) => _originalOrder[i]).toList();
    _playlistSubject.add(shuffledTracks);

    // Update current index
    if (current != null) {
      _currentIndexSubject.add(shuffledTracks.indexOf(current));
    }
  }

  void _unshufflePlaylist() {
    if (_originalOrder.isEmpty) return;

    final current = currentTrack;
    _playlistSubject.add(List.from(_originalOrder));
    _shuffledIndices.clear();

    // Update current index
    if (current != null) {
      _currentIndexSubject.add(_originalOrder.indexOf(current));
    }
  }

  // Equalizer controls
  void setEqualizerEnabled(bool enabled) {
    _equalizerEnabledSubject.add(enabled);
    _applyEqualizer();
  }

  void setBass(double value) {
    _bassSubject.add(value.clamp(-10.0, 10.0));
    _applyEqualizer();
  }

  void setMid(double value) {
    _midSubject.add(value.clamp(-10.0, 10.0));
    _applyEqualizer();
  }

  void setTreble(double value) {
    _trebleSubject.add(value.clamp(-10.0, 10.0));
    _applyEqualizer();
  }

  void setEqualizerPreset(String preset) {
    switch (preset) {
      case 'flat':
        _bassSubject.add(0.0);
        _midSubject.add(0.0);
        _trebleSubject.add(0.0);
        break;
      case 'bass_boost':
        _bassSubject.add(6.0);
        _midSubject.add(0.0);
        _trebleSubject.add(-2.0);
        break;
      case 'treble_boost':
        _bassSubject.add(-2.0);
        _midSubject.add(0.0);
        _trebleSubject.add(6.0);
        break;
      case 'vocal':
        _bassSubject.add(-2.0);
        _midSubject.add(4.0);
        _trebleSubject.add(2.0);
        break;
      case 'rock':
        _bassSubject.add(4.0);
        _midSubject.add(-2.0);
        _trebleSubject.add(4.0);
        break;
      case 'pop':
        _bassSubject.add(2.0);
        _midSubject.add(2.0);
        _trebleSubject.add(4.0);
        break;
      case 'jazz':
        _bassSubject.add(3.0);
        _midSubject.add(-2.0);
        _trebleSubject.add(2.0);
        break;
      case 'classical':
        _bassSubject.add(0.0);
        _midSubject.add(0.0);
        _trebleSubject.add(-2.0);
        break;
    }
    _applyEqualizer();
  }

  void _applyEqualizer() {
    // Note: just_audio doesn't have built-in equalizer support.
    // This is a placeholder for platform-specific equalizer implementation.
    // The actual equalizer would need platform channels or a native plugin.
    // For now, we store the values and they can be used when such support is added.
    debugPrint('Equalizer: enabled=${_equalizerEnabledSubject.value}, '
        'bass=${_bassSubject.value}, mid=${_midSubject.value}, treble=${_trebleSubject.value}');
  }

  // Queue management
  void addToQueue(AudioTrack track) {
    final tracks = List<AudioTrack>.from(playlist);
    tracks.add(track);
    _playlistSubject.add(tracks);
    _originalOrder.add(track);
  }

  void addToQueueNext(AudioTrack track) {
    if (playlist.isEmpty) {
      addToQueue(track);
      return;
    }
    final tracks = List<AudioTrack>.from(playlist);
    tracks.insert(currentIndex + 1, track);
    _playlistSubject.add(tracks);
    _originalOrder.insert(currentIndex + 1, track);
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= playlist.length) return;

    final tracks = List<AudioTrack>.from(playlist);
    final removedTrack = tracks.removeAt(index);
    _playlistSubject.add(tracks);
    _originalOrder.remove(removedTrack);

    if (index == currentIndex) {
      if (tracks.isNotEmpty) {
        final newIndex = index.clamp(0, tracks.length - 1);
        skipToIndex(newIndex);
      } else {
        stop();
      }
    } else if (index < currentIndex) {
      _currentIndexSubject.add(currentIndex - 1);
    }
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final tracks = List<AudioTrack>.from(playlist);
    final track = tracks.removeAt(oldIndex);
    tracks.insert(newIndex, track);
    _playlistSubject.add(tracks);

    // Update current index if needed
    if (oldIndex == currentIndex) {
      _currentIndexSubject.add(newIndex);
    } else if (oldIndex < currentIndex && newIndex >= currentIndex) {
      _currentIndexSubject.add(currentIndex - 1);
    } else if (oldIndex > currentIndex && newIndex <= currentIndex) {
      _currentIndexSubject.add(currentIndex + 1);
    }
  }

  void clearQueue() {
    final current = currentTrack;
    if (current != null) {
      _playlistSubject.add([current]);
      _originalOrder = [current];
      _currentIndexSubject.add(0);
    } else {
      _playlistSubject.add([]);
      _originalOrder = [];
      _currentIndexSubject.add(-1);
    }
  }

  // Combined stream for UI
  Stream<AudioPlayerState> get playerStateStream => Rx.combineLatest8(
    currentTrackStream,
    isPlayingStream,
    positionStream,
    durationStream,
    repeatModeStream,
    shuffleModeStream,
    bufferingStream,
    playlistStream,
    (track, playing, position, duration, repeat, shuffle, buffering, playlist) =>
        AudioPlayerState(
          currentTrack: track,
          isPlaying: playing,
          position: position,
          duration: duration,
          repeatMode: repeat,
          shuffleMode: shuffle,
          isBuffering: buffering,
          playlist: playlist,
          currentIndex: currentIndex,
        ),
  );

  void dispose() {
    _player.dispose();
    _currentTrackSubject.close();
    _playlistSubject.close();
    _currentIndexSubject.close();
    _isPlayingSubject.close();
    _repeatModeSubject.close();
    _shuffleModeSubject.close();
    _positionSubject.close();
    _durationSubject.close();
    _bufferingSubject.close();
    _playlistNameSubject.close();
    _equalizerEnabledSubject.close();
    _bassSubject.close();
    _midSubject.close();
    _trebleSubject.close();
    _notificationPermissionSubject.close();
  }
}

class AudioPlayerState {
  final AudioTrack? currentTrack;
  final bool isPlaying;
  final Duration position;
  final Duration? duration;
  final RepeatMode repeatMode;
  final bool shuffleMode;
  final bool isBuffering;
  final List<AudioTrack> playlist;
  final int currentIndex;

  AudioPlayerState({
    this.currentTrack,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration,
    this.repeatMode = RepeatMode.off,
    this.shuffleMode = false,
    this.isBuffering = false,
    this.playlist = const [],
    this.currentIndex = -1,
  });

  bool get hasTrack => currentTrack != null;
  bool get hasNext => currentIndex < playlist.length - 1 || repeatMode == RepeatMode.all;
  bool get hasPrevious => currentIndex > 0 || repeatMode == RepeatMode.all;

  double get progress {
    if (duration == null || duration!.inMilliseconds == 0) return 0.0;
    return position.inMilliseconds / duration!.inMilliseconds;
  }
}

// Audio handler for background playback and media controls
class _AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player;
  final AudioPlayerService _service;

  _AudioPlayerHandler(this._player, this._service) {
    // Broadcast playback state
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);
  }

  @override
  Future<void> updateMediaItem(MediaItem item) async {
    mediaItem.add(item);
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        // Custom rewind 10s button
        MediaControl.custom(
          androidIcon: 'drawable/ic_replay_10',
          label: 'Rewind 10s',
          name: 'rewind10',
        ),
        if (_player.playing) MediaControl.pause else MediaControl.play,
        // Custom forward 10s button
        MediaControl.custom(
          androidIcon: 'drawable/ic_forward_10',
          label: 'Forward 10s',
          name: 'forward10',
        ),
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
        MediaAction.fastForward,
        MediaAction.rewind,
        MediaAction.setSpeed,
      },
      androidCompactActionIndices: const [1, 2, 3],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _service.currentIndex,
    );
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'rewind10':
        await _service.seekBackward();
        break;
      case 'forward10':
        await _service.seekForward();
        break;
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> fastForward() => _service.seekForward();

  @override
  Future<void> rewind() => _service.seekBackward();

  @override
  Future<void> skipToNext() => _service.skipToNext();

  @override
  Future<void> skipToPrevious() => _service.skipToPrevious();

  @override
  Future<void> skipToQueueItem(int index) => _service.skipToIndex(index);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    switch (repeatMode) {
      case AudioServiceRepeatMode.none:
        _service.setRepeatMode(RepeatMode.off);
        break;
      case AudioServiceRepeatMode.one:
        _service.setRepeatMode(RepeatMode.one);
        break;
      case AudioServiceRepeatMode.all:
      case AudioServiceRepeatMode.group:
        _service.setRepeatMode(RepeatMode.all);
        break;
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode != AudioServiceShuffleMode.none;
    if (enabled != _service.shuffleMode) {
      _service.toggleShuffle();
    }
  }
}

// Helper to create AudioTrack from file path
AudioTrack audioTrackFromPath(String path) {
  return AudioTrack(
    path: path,
    name: p.basenameWithoutExtension(path),
  );
}
