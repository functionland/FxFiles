import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Trigger a browser download of [bytes] as [filename] (decrypted data
/// → Blob → temporary object URL → synthetic anchor click). The web
/// counterpart of the native save-to-Downloads path.
void saveBytesAsDownload(String filename, Uint8List bytes,
    {String mimeType = 'application/octet-stream'}) {
  final blob = web.Blob(
    <JSUint8Array>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
