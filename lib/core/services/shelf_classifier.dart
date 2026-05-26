import 'package:mime/mime.dart';

import 'package:fula_files/core/models/shelf_item.dart';

/// Rule-based classifier mapping shared payloads to a [ShelfCategory].
///
/// Per the Shelf plan Phase 7b (and the user's "no large LLM" constraint):
///   - text/plain that looks like a single URL → [ShelfCategory.link]
///   - text/plain otherwise → [ShelfCategory.note]
///   - image/* + filename matches the screenshot pattern → [ShelfCategory.screenshot]
///   - image/* otherwise → [ShelfCategory.image]
///   - video/* → [ShelfCategory.video]
///   - audio/* → [ShelfCategory.audio]
///   - application/pdf → [ShelfCategory.document]
///   - application/* otherwise → [ShelfCategory.file]
///   - everything else (and missing MIME) → [ShelfCategory.other]
///
/// Pure function — no I/O, safe to call from any isolate.
class ShelfClassifier {
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

  static ShelfCategory classify({
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
          ? ShelfCategory.link
          : ShelfCategory.note;
    }

    if (mime == null) return ShelfCategory.other;

    if (mime.startsWith('image/')) {
      return _screenshotRe.hasMatch(filename)
          ? ShelfCategory.screenshot
          : ShelfCategory.image;
    }
    if (mime.startsWith('video/')) return ShelfCategory.video;
    if (mime.startsWith('audio/')) return ShelfCategory.audio;
    if (mime == 'application/pdf') return ShelfCategory.document;
    if (mime.startsWith('text/')) return ShelfCategory.note;
    if (mime.startsWith('application/')) return ShelfCategory.file;
    return ShelfCategory.other;
  }
}
