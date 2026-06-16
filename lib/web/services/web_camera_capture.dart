import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Captured payload from a file/camera input.
typedef CapturedFile = ({Uint8List bytes, String name, String mime});

/// Web-only camera/photo capture via a transient `<input type="file">`.
///
/// Setting `capture="environment"` makes mobile browsers (incl. iOS
/// Safari) open the rear CAMERA directly instead of a file browser — the
/// pragmatic "take a photo" that needs no `getUserMedia`/live-preview
/// plumbing. On desktop, where `capture` is ignored, it falls back to a
/// normal file picker (the dedicated "Upload file" action covers that
/// case better).
class WebCameraCapture {
  WebCameraCapture._();

  /// Opens the camera (mobile) / file picker (desktop) for a single
  /// image and returns its bytes, or `null` if the user cancels.
  ///
  /// Resolves on the input's `change` (file chosen) OR `cancel`/window
  /// re-focus (dismissed) so the caller's await never hangs.
  static Future<CapturedFile?> takePhoto() {
    final completer = Completer<CapturedFile?>();

    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = 'image/*'
      // Hidden — we drive it programmatically via click().
      ..style.display = 'none';
    // `capture` isn't on the typed interface across package:web versions;
    // the attribute is what the browser actually reads. 'environment' =
    // rear camera.
    input.setAttribute('capture', 'environment');

    void finish(CapturedFile? value) {
      if (completer.isCompleted) return;
      try {
        input.remove();
      } catch (_) {/* already detached */}
      completer.complete(value);
    }

    input.addEventListener(
      'change',
      (web.Event _) {
        final files = input.files;
        if (files == null || files.length == 0) {
          finish(null);
          return;
        }
        final file = files.item(0);
        if (file == null) {
          finish(null);
          return;
        }
        _readFile(file).then(finish).catchError((Object e) {
          debugPrint('WebCameraCapture.takePhoto read failed: $e');
          finish(null);
        });
      }.toJS,
    );

    // Modern browsers fire `cancel` when the picker is dismissed.
    input.addEventListener('cancel', (web.Event _) {
      finish(null);
    }.toJS);

    // Fallback for browsers without `cancel`: when the window regains
    // focus after the picker closes, give `change` a beat to fire first;
    // if nothing arrived, treat it as a cancel.
    void onFocus(web.Event _) {
      web.window.removeEventListener('focus', onFocus.toJS);
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (!completer.isCompleted) finish(null);
      });
    }

    web.document.body?.append(input);
    input.click();
    web.window.addEventListener('focus', onFocus.toJS);

    return completer.future;
  }

  static Future<CapturedFile> _readFile(web.File file) async {
    final buf = await file.arrayBuffer().toDart;
    final bytes = buf.toDart.asUint8List();
    final name = file.name.isNotEmpty ? file.name : 'photo.jpg';
    final mime = file.type.isNotEmpty ? file.type : 'image/jpeg';
    return (bytes: bytes, name: name, mime: mime);
  }
}
