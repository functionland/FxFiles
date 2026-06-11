import 'dart:async';
import 'dart:typed_data';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import 'package:fula_files/web/services/web_save.dart';

/// Plays decrypted bytes through the browser media stack: bytes -> Blob
/// object URL -> HTML5 <video>/<audio> (via video_player / just_audio).
/// Codec support is the browser's own; Download stays one click away.
class MediaPreviewDialog extends StatefulWidget {
  final String title;
  final Uint8List bytes;
  final String mimeType;
  final bool isVideo;

  const MediaPreviewDialog({
    super.key,
    required this.title,
    required this.bytes,
    required this.mimeType,
    required this.isVideo,
  });

  @override
  State<MediaPreviewDialog> createState() => _MediaPreviewDialogState();
}

class _MediaPreviewDialogState extends State<MediaPreviewDialog> {
  late final String _blobUrl =
      createBlobUrl(widget.bytes, mimeType: widget.mimeType);
  VideoPlayerController? _video;
  ChewieController? _chewie;
  AudioPlayer? _audio;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      if (widget.isVideo) {
        final video = VideoPlayerController.networkUrl(Uri.parse(_blobUrl));
        await video.initialize();
        _video = video;
        _chewie = ChewieController(
          videoPlayerController: video,
          autoPlay: true,
          looping: false,
        );
      } else {
        final audio = AudioPlayer();
        await audio.setUrl(_blobUrl);
        _audio = audio;
        unawaited(audio.play());
      }
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _video?.dispose();
    _audio?.dispose();
    revokeBlobUrl(_blobUrl);
    super.dispose();
  }

  String _fmtDur(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(widget.title, overflow: TextOverflow.ellipsis),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Download',
                    icon: const Icon(Icons.download),
                    onPressed: () => saveBytesAsDownload(
                      widget.title.split('/').last,
                      widget.bytes,
                      mimeType: widget.mimeType,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'This browser could not play the file '
                  '(${widget.mimeType}). Use Download instead.\n$_error',
                  textAlign: TextAlign.center,
                ),
              )
            else if (!_ready)
              const Padding(
                padding: EdgeInsets.all(48),
                child: CircularProgressIndicator(),
              )
            else if (widget.isVideo)
              Flexible(
                child: AspectRatio(
                  aspectRatio: _video!.value.aspectRatio == 0
                      ? 16 / 9
                      : _video!.value.aspectRatio,
                  child: Chewie(controller: _chewie!),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StreamBuilder<PlayerState>(
                      stream: _audio!.playerStateStream,
                      builder: (ctx, snap) {
                        final playing = snap.data?.playing ?? false;
                        return IconButton.filled(
                          iconSize: 36,
                          icon: Icon(
                              playing ? Icons.pause : Icons.play_arrow),
                          onPressed: () =>
                              playing ? _audio!.pause() : _audio!.play(),
                        );
                      },
                    ),
                    const SizedBox(width: 16),
                    StreamBuilder<Duration>(
                      stream: _audio!.positionStream,
                      builder: (ctx, snap) {
                        final pos = snap.data ?? Duration.zero;
                        final total = _audio!.duration ?? Duration.zero;
                        return Text(
                            '${_fmtDur(pos)} / ${_fmtDur(total)}');
                      },
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
