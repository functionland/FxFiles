import 'package:mime/mime.dart';

import 'package:fula_files/core/models/dump_item.dart';

/// Rule-based classifier mapping shared payloads to a [DumpCategory].
///
/// Per the Dump plan Phase 7b (and the user's "no large LLM" constraint):
///   - text/plain that looks like a single URL → [DumpCategory.link]
///   - text/plain otherwise → [DumpCategory.note]
///   - image/* + filename matches the screenshot pattern → [DumpCategory.screenshot]
///   - image/* otherwise → [DumpCategory.image]
///   - video/* → [DumpCategory.video]
///   - audio/* → [DumpCategory.audio]
///   - application/pdf → [DumpCategory.document]
///   - application/* otherwise → [DumpCategory.file]
///   - everything else (and missing MIME) → [DumpCategory.other]
///
/// Pure function — no I/O, safe to call from any isolate.
class DumpClassifier {
  // Matches "screenshot" anywhere in the filename, plus the common
  // Android pattern "Screenshot_YYYY-MM-DD..." and the iOS pattern
  // "IMG_<n>" (which is NOT a screenshot — we deliberately leave IMG_ as
  // a regular image). Case-insensitive.
  static final RegExp _screenshotRe = RegExp(
    r'screenshot',
    caseSensitive: false,
  );

  // Conservative URL detector: scheme http/https, no whitespace.
  // Anchored to start + optional trailing whitespace so single-URL
  // text payloads classify as Link; longer notes with embedded URLs
  // remain Note.
  static final RegExp _urlRe = RegExp(r'^https?://\S+\s*$');

  static DumpCategory classify({
    required String? mimeType,
    required String filename,
    String? textPayload,
  }) {
    final mime = (mimeType?.isNotEmpty ?? false)
        ? mimeType!.toLowerCase()
        : lookupMimeType(filename)?.toLowerCase();

    // Text payload short-circuit: Link if a single URL, else Note.
    if (textPayload != null &&
        textPayload.isNotEmpty &&
        (mime == 'text/plain' || mime == null)) {
      return _urlRe.hasMatch(textPayload.trim())
          ? DumpCategory.link
          : DumpCategory.note;
    }

    if (mime == null) return DumpCategory.other;

    if (mime.startsWith('image/')) {
      return _screenshotRe.hasMatch(filename)
          ? DumpCategory.screenshot
          : DumpCategory.image;
    }
    if (mime.startsWith('video/')) return DumpCategory.video;
    if (mime.startsWith('audio/')) return DumpCategory.audio;
    if (mime == 'application/pdf') return DumpCategory.document;
    if (mime.startsWith('text/')) return DumpCategory.note;
    if (mime.startsWith('application/')) return DumpCategory.file;
    return DumpCategory.other;
  }
}
