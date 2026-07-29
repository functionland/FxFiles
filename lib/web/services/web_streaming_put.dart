// Thin JS-interop shim: a single PUT whose request body is a browser `Blob`.
//
// `xhr.send(blob)` hands the Blob to the BROWSER'S network process, which
// streams it from disk — the file's bytes never materialize in the Dart/JS
// heap, so a 150MB video uploads with O(1) renderer memory. This is the
// memory-bounded upload primitive for the public (plaintext) `website-assets`
// bucket, where the PUT response ETag is the object's IPFS CID.
//
// `package:http`'s web client can't do this (it requires the body as Dart
// bytes), hence raw XHR. No logic lives here — retry/validation decisions are
// in `web_website_asset_upload_logic.dart` so they stay VM-testable.

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

class StreamingPutResult {
  const StreamingPutResult({
    required this.status,
    required this.etag,
    required this.body,
  });

  /// HTTP status; 0 = network error, abort, or stall timeout (no response).
  final int status;
  final String? etag;
  final String body;
}

class StreamingPutHandle {
  StreamingPutHandle._(this._xhr, this.done);

  final web.XMLHttpRequest _xhr;

  /// Completes with the terminal result — never throws; network errors and
  /// aborts surface as [StreamingPutResult.status] == 0.
  final Future<StreamingPutResult> done;

  void abort() => _xhr.abort();
}

/// Start a streaming PUT of [blob] to [url]. [onProgress] reports
/// `(sentBytes, totalBytes)` from the browser's upload progress events.
/// [stallTimeout]: abort if no upload progress event arrives for this long
/// (guards against silently dead connections; result status 0).
StreamingPutHandle streamingPut({
  required String url,
  required Map<String, String> headers,
  required web.Blob blob,
  void Function(int sent, int total)? onProgress,
  Duration stallTimeout = const Duration(seconds: 120),
}) {
  final xhr = web.XMLHttpRequest();
  final completer = Completer<StreamingPutResult>();
  Timer? stall;

  void finish({required int status, String? etag, String body = ''}) {
    stall?.cancel();
    if (!completer.isCompleted) {
      completer.complete(
          StreamingPutResult(status: status, etag: etag, body: body));
    }
  }

  void armStall() {
    stall?.cancel();
    stall = Timer(stallTimeout, () {
      // No progress for too long — treat as a dead connection. abort() fires
      // the 'abort' listener below, which reports status 0.
      xhr.abort();
    });
  }

  xhr.open('PUT', url);
  for (final e in headers.entries) {
    xhr.setRequestHeader(e.key, e.value);
  }

  xhr.upload.addEventListener(
    'progress',
    ((web.ProgressEvent ev) {
      armStall();
      if (onProgress != null && ev.lengthComputable) {
        onProgress(ev.loaded, ev.total);
      }
    }).toJS,
  );
  // Body fully sent: the server may legitimately take a while to compute
  // the object's CID/index before responding (large files). Swap the
  // per-progress stall watchdog for one long response deadline so a
  // healthy PUT is never aborted mid-wait.
  xhr.upload.addEventListener(
    'load',
    ((web.Event _) {
      stall?.cancel();
      stall = Timer(const Duration(minutes: 10), () => xhr.abort());
    }).toJS,
  );

  xhr.addEventListener(
    'load',
    ((web.Event _) {
      finish(
        status: xhr.status,
        etag: xhr.getResponseHeader('ETag'),
        body: xhr.responseText,
      );
    }).toJS,
  );
  xhr.addEventListener('error', ((web.Event _) => finish(status: 0)).toJS);
  xhr.addEventListener('abort', ((web.Event _) => finish(status: 0)).toJS);
  xhr.addEventListener('timeout', ((web.Event _) => finish(status: 0)).toJS);

  armStall();
  try {
    xhr.send(blob);
  } catch (_) {
    // A synchronous send failure (e.g. detached document) must still
    // complete the future — a job may never be left waiting forever.
    finish(status: 0);
  }
  return StreamingPutHandle._(xhr, completer.future);
}
