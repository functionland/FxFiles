import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/core/services/auth_core.dart';
import 'package:fula_files/core/services/ipfs_gateway_helper.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/services/website_prompt_builder.dart';
import 'package:fula_files/core/utils/file_type_utils.dart' as file_utils;
import 'package:fula_files/web/services/web_features.dart';
import 'package:fula_files/web/services/web_foreground_activity.dart';
import 'package:fula_files/web/services/web_streaming_file.dart';
import 'package:fula_files/web/services/web_streaming_put.dart';
import 'package:fula_files/web/services/web_tag_service.dart';
import 'package:fula_files/web/services/web_unload_guard.dart';
import 'package:fula_files/web/services/web_website_asset_upload_logic.dart';

enum WebsiteAssetUploadStatus { queued, uploading, done, failed, cancelled }

/// One eager website-asset upload. Holds a lazily-readable [WebPickedFile]
/// (a Blob reference — never the bytes); the browser streams it from disk
/// during the PUT, so even a 150MB video costs ~nothing in renderer memory.
class WebsiteAssetUploadJob {
  WebsiteAssetUploadJob({
    required this.id,
    required this.tagId,
    required this.websiteName,
    required WebPickedFile picked,
  })  : fileName = picked.name,
        size = picked.size,
        _picked = picked;

  final int id;
  final String tagId;

  /// The group's DISPLAY name (sanitized into the object-key prefix by
  /// [websiteAssetObjectKey], byte-identical to the generation pipeline).
  final String websiteName;

  final String fileName;
  final int size;

  /// Editable while uploading; folded into the screen's asset row on done.
  String note = '';

  WebsiteAssetUploadStatus status = WebsiteAssetUploadStatus.queued;

  /// 0..1 while uploading.
  double progress = 0;

  /// User-facing reason when [status] is failed.
  String? error;

  /// Set on success — the object's public IPFS CID (from the PUT ETag).
  String? cid;
  String? gatewayUrl;

  /// `URL.createObjectURL` preview for images — lets the tile (and the
  /// folded-in asset row) render a thumbnail without waiting for gateway
  /// propagation of a fresh CID. Ownership transfers via [takePreviewUrl];
  /// anything left behind is revoked on clear/cancel/reset.
  String? _previewUrl;
  String? get previewUrl => _previewUrl;

  /// Kept on FAILED jobs so a manual Retry works without re-picking;
  /// nulled on done/cancelled.
  WebPickedFile? _picked;

  StreamingPutHandle? _handle;
  int _attempt = 0;

  String get type => file_utils.classifyFileType(fileName);

  bool get isActive =>
      status == WebsiteAssetUploadStatus.queued ||
      status == WebsiteAssetUploadStatus.uploading;

  /// Transfer ownership of the preview URL to the caller (the screen's
  /// asset row). The job will no longer revoke it.
  String? takePreviewUrl() {
    final u = _previewUrl;
    _previewUrl = null;
    return u;
  }

  void _revokePreview() {
    final u = _previewUrl;
    _previewUrl = null;
    if (u != null) {
      try {
        web.URL.revokeObjectURL(u);
      } catch (_) {}
    }
  }
}

/// App-level queue for EAGER website-asset uploads (import-time streaming
/// PUTs to the public, unencrypted `website-assets` bucket).
///
/// Distinct from [WebUploadManager] by design: that queue writes ENCRYPTED
/// objects into the user's private forest via the fula_client streaming
/// handles; website assets must stay plaintext-public (the AI backend and
/// site visitors fetch them by CID), so this queue drives raw Blob-body PUTs
/// through [streamingPut] instead. On success the asset is recorded as a
/// group member via the tag manifest (`remoteKey: website-assets/…`), which
/// is what makes web-imported assets survive a reload.
class WebWebsiteAssetUploader extends ChangeNotifier {
  WebWebsiteAssetUploader._();
  static final WebWebsiteAssetUploader instance = WebWebsiteAssetUploader._();

  final List<WebsiteAssetUploadJob> _jobs = [];
  int _seq = 0;
  bool _pumping = false;

  /// Bumped by [reset] (sign-out / user-switch); the pump bails when it
  /// changes mid-drain.
  int _epoch = 0;

  List<WebsiteAssetUploadJob> jobsForTag(String tagId) => List.unmodifiable(
      _jobs.where((j) => j.tagId == tagId && j.status != WebsiteAssetUploadStatus.done));

  bool hasActiveJobs(String tagId) =>
      _jobs.any((j) => j.tagId == tagId && j.isActive);

  /// Jobs that finished successfully for [tagId] — the screen folds these
  /// into its asset rows, then calls [clearFinished].
  List<WebsiteAssetUploadJob> doneJobsForTag(String tagId) =>
      List.unmodifiable(_jobs.where(
          (j) => j.tagId == tagId && j.status == WebsiteAssetUploadStatus.done));

  /// Validate (Blob metadata only — no reads) and enqueue [files] for
  /// [tagId]. [groupKnownBytes] = sum of known sizes already in the group
  /// (ready assets + still-active jobs), for the aggregate cap. Returns
  /// per-file rejection reasons for the caller's snackbar.
  ({int accepted, List<String> rejectedReasons}) enqueue({
    required String tagId,
    required String websiteName,
    required List<WebPickedFile> files,
    required int groupKnownBytes,
  }) {
    final rejected = <String>[];
    var accepted = 0;
    var knownBytes = groupKnownBytes;
    for (final f in files) {
      final v = validateWebsiteAssetImport(
        fileName: f.name,
        sizeBytes: f.size,
        groupKnownBytes: knownBytes,
      );
      if (!v.ok) {
        rejected.add(v.reason!);
        continue;
      }
      knownBytes += f.size;
      final job = WebsiteAssetUploadJob(
        id: _seq++,
        tagId: tagId,
        websiteName: websiteName,
        picked: f,
      );
      if (job.type == 'image') {
        try {
          job._previewUrl = web.URL.createObjectURL(f.jsFile);
        } catch (_) {}
      }
      _jobs.add(job);
      accepted++;
    }
    if (accepted > 0) {
      notifyListeners();
      unawaited(_pump());
    }
    return (accepted: accepted, rejectedReasons: rejected);
  }

  /// Cancel a queued or in-flight job. Aborting the XHR mid-body leaves
  /// NOTHING server-side — the gateway only writes the object index after
  /// the full body arrives (single-PUT atomicity).
  void cancel(int jobId) {
    final job = _byId(jobId);
    if (job == null || !job.isActive) return;
    job.status = WebsiteAssetUploadStatus.cancelled;
    job.error = null;
    job._handle?.abort();
    job._handle = null;
    job._picked = null;
    job._revokePreview();
    notifyListeners();
  }

  /// Manual retry of a FAILED job (the Blob handle is kept on failure).
  void retry(int jobId) {
    final job = _byId(jobId);
    if (job == null || job.status != WebsiteAssetUploadStatus.failed) return;
    if (job._picked == null) {
      job.error = 'File handle lost — remove and import again.';
      notifyListeners();
      return;
    }
    job.status = WebsiteAssetUploadStatus.queued;
    job.error = null;
    job.progress = 0;
    job._attempt = 0;
    notifyListeners();
    unawaited(_pump());
  }

  /// Drop one finished (failed/cancelled) row.
  void dismiss(int jobId) {
    final job = _byId(jobId);
    if (job == null || job.isActive) return;
    job._revokePreview();
    _jobs.remove(job);
    notifyListeners();
  }

  /// Drop DONE rows for [tagId] after the screen folded them into its
  /// asset list. Failed/cancelled rows are deliberately kept — they carry
  /// the error text, the Retry affordance, and the retained Blob handle.
  void clearDone(String tagId) {
    for (final j in _jobs) {
      if (j.tagId == tagId && j.status == WebsiteAssetUploadStatus.done) {
        j._revokePreview(); // unclaimed previews only (take nulls it)
      }
    }
    _jobs.removeWhere((j) =>
        j.tagId == tagId && j.status == WebsiteAssetUploadStatus.done);
    notifyListeners();
  }

  /// Sign-out / user-switch: abandon everything (mirrors
  /// WebUploadManager.reset).
  void reset() {
    _epoch++;
    for (final j in _jobs) {
      j._handle?.abort();
      j._revokePreview();
    }
    _jobs.clear();
    notifyListeners();
  }

  WebsiteAssetUploadJob? _byId(int id) {
    for (final j in _jobs) {
      if (j.id == id) return j;
    }
    return null;
  }

  WebsiteAssetUploadJob? _nextQueued() {
    for (final j in _jobs) {
      if (j.status == WebsiteAssetUploadStatus.queued) return j;
    }
    return null;
  }

  Future<({String endpoint, String jwt})> _auth() async {
    var endpoint = (await SecureStorageService.instance
            .read(SecureStorageKeys.apiGatewayUrl)) ??
        AuthCore.defaultS3GatewayUrl;
    endpoint = endpoint.replaceAll(RegExp(r'/+$'), '');
    final jwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    if (jwt == null || jwt.isEmpty) {
      throw Exception('Not signed in');
    }
    return (endpoint: endpoint, jwt: jwt);
  }

  Future<void> _pump() async {
    if (_pumping) return;
    if (_nextQueued() == null) return;
    _pumping = true;
    final epoch = _epoch;

    WebForegroundActivity.instance.begin();
    WebUnloadGuard.instance.addRef();

    var bucketEnsured = false;
    try {
      while (_epoch == epoch) {
        final job = _nextQueued();
        if (job == null) break;

        job.status = WebsiteAssetUploadStatus.uploading;
        job.progress = 0;
        notifyListeners();

        final picked = job._picked;
        if (picked == null) {
          job.status = WebsiteAssetUploadStatus.failed;
          job.error = 'No file data';
          notifyListeners();
          continue;
        }

        try {
          final auth = await _auth();

          if (!bucketEnsured) {
            bucketEnsured = true;
            try {
              await http.put(
                Uri.parse('${auth.endpoint}/$kWebsiteAssetBucket'),
                headers: {'Authorization': 'Bearer ${auth.jwt}'},
              );
            } catch (e) {
              debugPrint('WebWebsiteAssetUploader: ensure-bucket note: $e');
            }
          }

          final key = websiteAssetObjectKey(job.websiteName, job.fileName);
          final contentType =
              lookupMimeType(job.fileName) ?? 'application/octet-stream';

          StreamingPutResult result;
          while (true) {
            // A cancel/sign-out during the retry backoff must not start a
            // fresh attempt for a dead job.
            if (_epoch != epoch ||
                job.status == WebsiteAssetUploadStatus.cancelled) {
              result = const StreamingPutResult(status: 0, etag: null, body: '');
              break;
            }
            job._attempt++;
            final handle = streamingPut(
              url:
                  '${auth.endpoint}/$kWebsiteAssetBucket/${encodeObjectKeyForUrl(key)}',
              headers: {
                'Authorization': 'Bearer ${auth.jwt}',
                'Content-Type': contentType,
              },
              blob: picked.jsFile,
              onProgress: (sent, total) {
                if (total > 0) {
                  job.progress = sent / total;
                  if (_epoch == epoch) notifyListeners();
                }
              },
            );
            job._handle = handle;
            result = await handle.done;
            job._handle = null;

            if (_epoch != epoch ||
                job.status == WebsiteAssetUploadStatus.cancelled) {
              break;
            }
            if (result.status == 200 || result.status == 201) break;
            if (!shouldRetryUpload(
                attempt: job._attempt, status: result.status)) {
              break;
            }
            await Future<void>.delayed(const Duration(seconds: 2));
          }

          if (_epoch != epoch) break;
          if (job.status == WebsiteAssetUploadStatus.cancelled) continue;

          if (result.status != 200 && result.status != 201) {
            job.status = WebsiteAssetUploadStatus.failed;
            job.error = switch (result.status) {
              0 => 'Network error — check your connection',
              401 || 403 => 'Authentication expired — sign in again',
              _ => 'Upload failed (HTTP ${result.status})',
            };
            notifyListeners();
            continue;
          }

          var cid = cidFromEtagHeader(result.etag);
          // ETag missing/unusable (proxy stripped it?) — recover via HEAD.
          cid ??= await WebFeatures.websiteAssetCidByHead(key);
          if (cid == null) {
            job.status = WebsiteAssetUploadStatus.failed;
            job.error = 'Upload succeeded but no CID was returned';
            notifyListeners();
            continue;
          }

          // Group membership — this is what makes the asset survive reload.
          await WebTagService.instance.tagFile(
            tagId: job.tagId,
            remoteKey: websiteAssetRemoteKey(job.websiteName, job.fileName),
            fileName: job.fileName,
          );

          if (_epoch != epoch) break;
          job.cid = cid;
          job.gatewayUrl = IpfsGatewayHelper.buildUrlForCid(cid);
          job.status = WebsiteAssetUploadStatus.done;
          job.progress = 1.0;
          job._picked = null;
          notifyListeners();
        } catch (e) {
          if (_epoch != epoch) break;
          if (job.status != WebsiteAssetUploadStatus.cancelled) {
            job.status = WebsiteAssetUploadStatus.failed;
            job.error = '$e';
          }
          notifyListeners();
        }
      }
    } finally {
      WebUnloadGuard.instance.removeRef();
      WebForegroundActivity.instance.end();
      _pumping = false;
      notifyListeners();
      if (_epoch == epoch && _nextQueued() != null) unawaited(_pump());
    }
  }
}
