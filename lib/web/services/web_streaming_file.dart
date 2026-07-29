import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// A file the user picked for upload, kept as a lazily-readable browser `Blob`
/// reference — NOT loaded into memory. Slices are read on demand via
/// [readSlice], so a multi-GB file never has to fit in the tab's heap. This is
/// what makes the streaming upload genuinely memory-bounded on the web (the old
/// `file_picker` `withData: true` path read the whole file up front, which OOM'd
/// the tab on low-RAM phones).
class WebPickedFile {
  WebPickedFile(this._file);

  final web.File _file;

  String get name => _file.name;
  int get size => _file.size;

  /// The underlying browser `File` — for handing to a Blob-body XHR (the
  /// browser's network process streams it from disk; this never reads the
  /// file into the Dart/JS heap).
  web.File get jsFile => _file;

  /// Read bytes `[start, end)` from the underlying file. The browser reads the
  /// slice from disk on demand; only this slice is materialized in memory.
  Future<Uint8List> readSlice(int start, int end) async {
    final web.Blob slice = _file.slice(start, end);
    final JSArrayBuffer buf = await slice.arrayBuffer().toDart;
    return buf.toDart.asUint8List();
  }
}

/// Open the browser file picker (a raw `<input type=file>`) WITHOUT reading the
/// selected files into memory — returns lazily-readable [WebPickedFile] handles.
///
/// Unlike `file_picker`'s `withData: true`, this never loads the whole file, so
/// large files don't exhaust the tab's memory budget on a low-RAM device. MUST
/// be called synchronously from within a user gesture: `input.click()` runs
/// before the first `await`, which preserves the gesture activation iOS Safari
/// requires for file pickers.
Future<List<WebPickedFile>> pickFilesForUpload({
  String? accept,
  bool allowMultiple = true,
}) {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = allowMultiple;
  if (accept != null && accept.isNotEmpty) {
    input.accept = accept;
  }
  // Some browsers only fire the change event for an input attached to the DOM;
  // keep it out of layout.
  input.style.display = 'none';
  web.document.body?.append(input);

  final completer = Completer<List<WebPickedFile>>();
  void finish(List<WebPickedFile> files) {
    if (!completer.isCompleted) completer.complete(files);
    input.remove();
  }

  input.addEventListener(
    'change',
    ((web.Event _) {
      final files = input.files;
      final out = <WebPickedFile>[];
      if (files != null) {
        for (var i = 0; i < files.length; i++) {
          final f = files.item(i);
          if (f != null) out.add(WebPickedFile(f));
        }
      }
      finish(out);
    }).toJS,
  );
  // Modern browsers fire 'cancel' when the dialog is dismissed — complete empty
  // so the caller's Future never hangs (and the input is removed).
  input.addEventListener(
    'cancel',
    ((web.Event _) => finish(const [])).toJS,
  );

  input.click(); // synchronous → preserves the user gesture (iOS Safari)
  return completer.future;
}

/// Wrap the files from a drag-and-drop `DataTransfer` (a `drop` event) in
/// [WebPickedFile]s — the same lazily-readable Blob wrapper the picker uses, so
/// dropped files ride the identical memory-bounded chunked-upload path (no
/// whole-file read, no OOM).
List<WebPickedFile> filesFromDataTransfer(web.DataTransfer? dt) {
  final out = <WebPickedFile>[];
  final files = dt?.files;
  if (files != null) {
    for (var i = 0; i < files.length; i++) {
      final f = files.item(i);
      if (f != null) out.add(WebPickedFile(f));
    }
  }
  return out;
}
