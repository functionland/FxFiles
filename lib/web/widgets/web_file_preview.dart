// Shared "open this cloud object" behaviour for the web app.
//
// WHY THIS EXISTS
// ---------------
// The image dialog, the media dialog, the text viewer, the audio queue
// player and the download fallback all used to be private methods on
// `WebBucketScreen`. That made them unreachable from every other screen
// that lists cloud objects, which is why the Tags screen could only put
// up a SnackBar telling the user to go find the file in its category.
//
// This repo has already paid for hand-duplicating a widget once —
// `_GenerationCard` in `web_website_detail_screen.dart` is a hand-copied
// "mirror of the native GenerationStatusCard" and the two have drifted.
// So this is an EXTRACTION, not a copy: `WebBucketScreen` delegates here
// rather than keeping its own version.
//
// Everything here works from a `FulaObject` plus a way to resolve its
// bucket. That indirection matters for Tags, where a single tag's files
// legitimately span several buckets, so a screen-wide `widget.base`
// fallback would send half of them to the wrong place.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/web/services/web_audio_controller.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_recent_files_service.dart';
import 'package:fula_files/web/services/web_save.dart';
import 'package:fula_files/web/services/web_text_viewer_logic.dart';
import 'package:fula_files/web/services/web_thumbnail_service.dart';
import 'package:fula_files/web/widgets/media_preview_dialog.dart';
import 'package:fula_files/web/widgets/web_audio_player.dart';
import 'package:fula_files/web/widgets/web_text_viewer.dart';

/// How a screen labels an object (bucket screen strips folder prefixes,
/// tags use the stored file name).
typedef WebObjectNamer = String Function(FulaObject o);

/// How a screen resolves which bucket an object actually lives in.
typedef WebObjectBucketOf = String Function(FulaObject o);

String webDefaultName(FulaObject o) => o.name;

// ---------------------------------------------------------------------
// Type detection
// ---------------------------------------------------------------------

bool webIsVideo(FulaObject o) {
  final ct = o.metadata?['contentType'] ?? '';
  if (ct.startsWith('video/')) return true;
  final n = o.key.toLowerCase();
  return n.endsWith('.mp4') ||
      n.endsWith('.webm') ||
      n.endsWith('.mov') ||
      n.endsWith('.m4v');
}

bool webIsAudio(FulaObject o) {
  final ct = o.metadata?['contentType'] ?? '';
  if (ct.startsWith('audio/')) return true;
  final n = o.key.toLowerCase();
  return n.endsWith('.mp3') ||
      n.endsWith('.m4a') ||
      n.endsWith('.wav') ||
      n.endsWith('.ogg') ||
      n.endsWith('.flac');
}

bool webIsImage(FulaObject o) {
  final ct = o.metadata?['contentType'] ?? '';
  if (ct.startsWith('image/')) return true;
  final n = o.key.toLowerCase();
  return n.endsWith('.png') ||
      n.endsWith('.jpg') ||
      n.endsWith('.jpeg') ||
      n.endsWith('.gif') ||
      n.endsWith('.webp');
}

bool webIsText(FulaObject o) {
  final ct = o.metadata?['contentType'] ?? '';
  if (ct.startsWith('text/') ||
      ct == 'application/json' ||
      ct == 'application/xml') {
    return true;
  }
  // Native parity: the full LocalFile.isTextViewable extension set.
  return isTextViewableName(o.key);
}

String webMediaMime(FulaObject o) {
  final ct = o.metadata?['contentType'] ?? '';
  if (ct.isNotEmpty && ct != 'application/octet-stream') return ct;
  final n = o.key.toLowerCase();
  if (n.endsWith('.mp4') || n.endsWith('.m4v')) return 'video/mp4';
  if (n.endsWith('.webm')) return 'video/webm';
  if (n.endsWith('.mov')) return 'video/quicktime';
  if (n.endsWith('.mp3')) return 'audio/mpeg';
  if (n.endsWith('.m4a')) return 'audio/mp4';
  if (n.endsWith('.wav')) return 'audio/wav';
  if (n.endsWith('.ogg')) return 'audio/ogg';
  if (n.endsWith('.flac')) return 'audio/flac';
  return 'application/octet-stream';
}

/// A stable kind for the recents store (forces image/video/audio
/// classification so the strip renders the right card + thumbnail).
String webRecentMime(FulaObject o) {
  if (webIsImage(o)) return 'image/*';
  if (webIsVideo(o)) return 'video/*';
  if (webIsAudio(o)) return 'audio/*';
  final ct = o.metadata?['contentType'] ?? '';
  return ct.isNotEmpty ? ct : 'application/octet-stream';
}

/// Icon for an object when no thumbnail is available.
IconData webIconFor(FulaObject o) => webIsImage(o)
    ? Icons.image_outlined
    : webIsVideo(o)
        ? Icons.movie_outlined
        : webIsAudio(o)
            ? Icons.audiotrack_outlined
            : webIsText(o)
                ? Icons.article_outlined
                : Icons.insert_drive_file_outlined;

void _recordRecent(
  FulaObject o,
  String bucket,
  String base,
  WebObjectNamer nameOf, {
  Uint8List? imageBytes,
}) {
  WebRecentFilesService.instance.recordOpened(
    bucket: bucket,
    base: base,
    key: o.key,
    name: nameOf(o).split('/').last,
    mime: webRecentMime(o),
    size: o.size,
    imageBytes: imageBytes,
  );
}

/// Snackbar that is safe to call after an await — the guard is here so
/// every call site does not have to repeat it.
void _snack(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

// ---------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------

/// Download [object] and hand it to the browser as a file save.
Future<void> downloadWebFile({
  required BuildContext context,
  required FulaObject object,
  required String bucket,
  required String base,
  WebObjectNamer nameOf = webDefaultName,
}) async {
  _snack(context, 'Downloading "${nameOf(object)}"…');
  try {
    final bytes = await WebForegroundActivity.instance.run(
      // P14.1: route by sourceBucket so adopted AI-workspace files decrypt
      // via the workspace client (bucket already folds in sourceBucket).
      () => FulaApiService.instance
          .downloadBySourceBucket(bucket, object.key, object.sourceBucket),
    );
    saveBytesAsDownload(
      nameOf(object).split('/').last,
      bytes,
      mimeType: object.metadata?['contentType']?.isNotEmpty == true
          ? object.metadata!['contentType']!
          : 'application/octet-stream',
    );
    _recordRecent(object, bucket, base, nameOf);
  } catch (e) {
    if (!context.mounted) return;
    _snack(context, 'Download failed: $e');
  }
}

/// Open [object] in the right internal viewer, falling back to a
/// download for types with no viewer.
///
/// [audioQueue] is the surrounding list of objects so tapping one audio
/// file plays the whole screen's audio as a queue; pass an empty list to
/// play the tapped file on its own.
Future<void> openWebFilePreview({
  required BuildContext context,
  required FulaObject object,
  required WebObjectBucketOf bucketOf,
  required String base,
  WebObjectNamer nameOf = webDefaultName,
  List<FulaObject> audioQueue = const <FulaObject>[],
}) async {
  if (webIsAudio(object)) {
    await _openAudioPlayer(
      context: context,
      tapped: object,
      bucketOf: bucketOf,
      base: base,
      nameOf: nameOf,
      queue: audioQueue,
    );
    return;
  }
  if (webIsVideo(object)) {
    await _previewMedia(
      context: context,
      object: object,
      bucket: bucketOf(object),
      base: base,
      nameOf: nameOf,
    );
    return;
  }
  if (webIsText(object)) {
    // The whole file is in memory on web; decoding + splitting a huge
    // string would jank the JS thread, so cap inline viewing and fall
    // back to download (#19). Guard on the listed size pre-download.
    if (object.size > kMaxInlineTextBytes) {
      await downloadWebFile(
        context: context,
        object: object,
        bucket: bucketOf(object),
        base: base,
        nameOf: nameOf,
      );
    } else {
      await _previewText(
        context: context,
        object: object,
        bucket: bucketOf(object),
        base: base,
        nameOf: nameOf,
      );
    }
    return;
  }
  if (!webIsImage(object)) {
    await downloadWebFile(
      context: context,
      object: object,
      bucket: bucketOf(object),
      base: base,
      nameOf: nameOf,
    );
    return;
  }
  await _previewImage(
    context: context,
    object: object,
    bucket: bucketOf(object),
    base: base,
    nameOf: nameOf,
  );
}

Future<void> _previewImage({
  required BuildContext context,
  required FulaObject object,
  required String bucket,
  required String base,
  required WebObjectNamer nameOf,
}) async {
  // One download future shared with the dialog; record once when it
  // resolves (not on FutureBuilder rebuilds, not on failure).
  final future = FulaApiService.instance
      .downloadBySourceBucket(bucket, object.key, object.sourceBucket);
  unawaited(future.then((bytes) {
    _recordRecent(object, bucket, base, nameOf, imageBytes: bytes);
    WebThumbnailService.instance
        .backfillFromBytes(bucket, object.key, object.name, bytes);
  }).catchError((_) {}));

  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
        child: FutureBuilder<Uint8List>(
          future: future,
          builder: (ctx, snap) {
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Preview failed: ${snap.error}'),
              );
            }
            if (!snap.hasData) {
              return const SizedBox(
                width: 320,
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final bytes = snap.data!;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(
                    nameOf(object),
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Download',
                        icon: const Icon(Icons.download),
                        onPressed: () => saveBytesAsDownload(
                            nameOf(object).split('/').last, bytes),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: InteractiveViewer(
                    maxScale: 8,
                    child: Image.memory(bytes, fit: BoxFit.contain),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    ),
  );
}

/// Full-screen inline text/code viewer (#19).
Future<void> _previewText({
  required BuildContext context,
  required FulaObject object,
  required String bucket,
  required String base,
  required WebObjectNamer nameOf,
}) async {
  _snack(context, 'Loading "${nameOf(object)}"…');
  try {
    final bytes = await FulaApiService.instance
        .downloadBySourceBucket(bucket, object.key, object.sourceBucket);
    if (!context.mounted) return;
    final name = nameOf(object).split('/').last;
    _recordRecent(object, bucket, base, nameOf);
    // Backstop the size cap: if the listing size was 0/unset a truly
    // large file would jank the viewer's decode/split, so download it.
    if (bytes.length > kMaxInlineTextBytes) {
      saveBytesAsDownload(name, bytes);
      return;
    }
    await showDialog<void>(
      context: context,
      useSafeArea: false,
      builder: (ctx) => Dialog.fullscreen(
        child: WebTextViewer(
          fileName: name,
          bytes: bytes,
          onDownload: () => saveBytesAsDownload(name, bytes),
        ),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    _snack(context, 'Preview failed: $e');
  }
}

/// Download + decrypt, then play via a blob URL fed to the HTML5 media
/// element. Best-effort: codec support depends on the browser; the
/// dialog offers Download as the fallback.
Future<void> _previewMedia({
  required BuildContext context,
  required FulaObject object,
  required String bucket,
  required String base,
  required WebObjectNamer nameOf,
}) async {
  _snack(context, 'Loading "${nameOf(object)}"…');
  try {
    final bytes = await FulaApiService.instance
        .downloadBySourceBucket(bucket, object.key, object.sourceBucket);
    _recordRecent(object, bucket, base, nameOf);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => MediaPreviewDialog(
        title: nameOf(object),
        bytes: bytes,
        mimeType: webMediaMime(object),
        isVideo: true,
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    _snack(context, 'Playback failed: $e');
  }
}

WebAudioTrack _audioTrackFor(
  FulaObject o,
  WebObjectBucketOf bucketOf,
  WebObjectNamer nameOf,
) {
  final bucket = bucketOf(o);
  return WebAudioTrack(
    name: nameOf(o).split('/').last,
    mime: webMediaMime(o),
    cloudKey: o.key,
    download: () => FulaApiService.instance
        .downloadBySourceBucket(bucket, o.key, o.sourceBucket),
  );
}

/// Open the full-screen audio player with a queue of every audio file in
/// the caller's listing, starting at [tapped] (#21).
Future<void> _openAudioPlayer({
  required BuildContext context,
  required FulaObject tapped,
  required WebObjectBucketOf bucketOf,
  required String base,
  required WebObjectNamer nameOf,
  required List<FulaObject> queue,
}) async {
  final audio = queue.where(webIsAudio).toList();
  final tappedBucket = bucketOf(tapped);
  var start = audio.indexWhere(
      (o) => o.key == tapped.key && bucketOf(o) == tappedBucket);
  if (start < 0) {
    // Not in the caller's listing (e.g. a deep-open) — play it alone.
    audio.insert(0, tapped);
    start = 0;
  }
  _recordRecent(tapped, tappedBucket, base, nameOf);
  if (!context.mounted) return;
  // Start playback on the singleton, then open the (parameterless)
  // player — closing it just minimizes to the mini-player (s2).
  // setExpanded is done here (event context), not in the dialog's
  // initState, to avoid notifying the mini-player mid-build.
  final c = WebAudioController.instance;
  c.playQueue(
      [for (final o in audio) _audioTrackFor(o, bucketOf, nameOf)], start);
  c.setExpanded(true);
  await showDialog<void>(
    context: context,
    useSafeArea: false,
    builder: (ctx) => const Dialog.fullscreen(child: WebAudioPlayer()),
  );
  c.setExpanded(false);
}
