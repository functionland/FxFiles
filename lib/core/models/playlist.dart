import 'package:hive_flutter/hive_flutter.dart';

part 'playlist.g.dart';

@HiveType(typeId: 6)
class AudioTrack extends HiveObject {
  @HiveField(0)
  final String path;

  @HiveField(1)
  final String name;

  @HiveField(2)
  final int durationMs;

  @HiveField(3)
  final String? artist;

  @HiveField(4)
  final String? album;

  AudioTrack({
    required this.path,
    required this.name,
    this.durationMs = 0,
    this.artist,
    this.album,
  });

  AudioTrack copyWith({
    String? path,
    String? name,
    int? durationMs,
    String? artist,
    String? album,
  }) {
    return AudioTrack(
      path: path ?? this.path,
      name: name ?? this.name,
      durationMs: durationMs ?? this.durationMs,
      artist: artist ?? this.artist,
      album: album ?? this.album,
    );
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'durationMs': durationMs,
    'artist': artist,
    'album': album,
  };

  factory AudioTrack.fromJson(Map<String, dynamic> json) => AudioTrack(
    path: json['path'] as String,
    name: json['name'] as String,
    durationMs: json['durationMs'] as int? ?? 0,
    artist: json['artist'] as String?,
    album: json['album'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioTrack &&
          runtimeType == other.runtimeType &&
          path == other.path;

  @override
  int get hashCode => path.hashCode;
}

@HiveType(typeId: 7)
class Playlist extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  final List<AudioTrack> tracks;

  @HiveField(3)
  final DateTime createdAt;

  @HiveField(4)
  DateTime updatedAt;

  @HiveField(5)
  String? coverPath;

  @HiveField(6)
  bool isSyncedToCloud;

  @HiveField(7)
  String? cloudKey;

  Playlist({
    required this.id,
    required this.name,
    List<AudioTrack>? tracks,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.coverPath,
    this.isSyncedToCloud = false,
    this.cloudKey,
  })  : tracks = tracks ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  int get trackCount => tracks.length;

  Duration get totalDuration {
    final totalMs = tracks.fold<int>(0, (sum, track) => sum + track.durationMs);
    return Duration(milliseconds: totalMs);
  }

  void addTrack(AudioTrack track) {
    if (!tracks.contains(track)) {
      tracks.add(track);
      updatedAt = DateTime.now();
    }
  }

  void addTracks(List<AudioTrack> newTracks) {
    for (final track in newTracks) {
      if (!tracks.contains(track)) {
        tracks.add(track);
      }
    }
    updatedAt = DateTime.now();
  }

  void removeTrack(AudioTrack track) {
    tracks.remove(track);
    updatedAt = DateTime.now();
  }

  void removeTrackAt(int index) {
    if (index >= 0 && index < tracks.length) {
      tracks.removeAt(index);
      updatedAt = DateTime.now();
    }
  }

  void reorderTrack(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final track = tracks.removeAt(oldIndex);
    tracks.insert(newIndex, track);
    updatedAt = DateTime.now();
  }

  void clearTracks() {
    tracks.clear();
    updatedAt = DateTime.now();
  }

  Playlist copyWith({
    String? id,
    String? name,
    List<AudioTrack>? tracks,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? coverPath,
    bool? isSyncedToCloud,
    String? cloudKey,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      tracks: tracks ?? List.from(this.tracks),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      coverPath: coverPath ?? this.coverPath,
      isSyncedToCloud: isSyncedToCloud ?? this.isSyncedToCloud,
      cloudKey: cloudKey ?? this.cloudKey,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'tracks': tracks.map((t) => t.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'coverPath': coverPath,
  };

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
    id: json['id'] as String,
    name: json['name'] as String,
    tracks: (json['tracks'] as List<dynamic>?)
        ?.map((t) => AudioTrack.fromJson(t as Map<String, dynamic>))
        .toList() ?? [],
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    coverPath: json['coverPath'] as String?,
  );
}
