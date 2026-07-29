// Pure helpers behind the web website-asset EAGER upload path (import-time
// streaming PUT to the public `website-assets` bucket). Platform-neutral and
// IO-free so every decision here is VM-testable; the uploader service and the
// XHR shim stay logic-free.
//
// Key contract: a single (non-multipart) PUT's response ETag IS the whole
// object's public IPFS CID (fula-api object handler). The gateway's S3
// multipart upload does NOT preserve that contract (its completed object
// records only the FIRST part's CID and its ETag is `{hash}-{partCount}`),
// which is why website assets are uploaded as one streaming Blob-body PUT
// and why [cidFromEtagHeader] rejects the composite multipart ETag shape.

import 'package:fula_files/core/services/website_prompt_builder.dart';
import 'package:fula_files/web/services/web_website_assets_logic.dart'
    show sanitizeWebsiteName;

/// Object key inside the `website-assets` bucket for a group asset:
/// `{sanitizedGroupName}/{fileName}` — byte-identical to the key native and
/// the generation pipeline use, so eager uploads and generation-time uploads
/// land on the SAME object (content-addressed dedupe).
String websiteAssetObjectKey(String websiteDisplayName, String fileName) =>
    '${sanitizeWebsiteName(websiteDisplayName)}/$fileName';

/// The tag-manifest remoteKey for an eagerly uploaded asset, in the same
/// 'bucket/objectKey' shape the native cloud-explorer records.
String websiteAssetRemoteKey(String websiteDisplayName, String fileName) =>
    '$kWebsiteAssetBucket/${websiteAssetObjectKey(websiteDisplayName, fileName)}';

/// Whether [remoteKey] points into the public `website-assets` bucket
/// (i.e. was recorded by the eager web import path).
bool isWebsiteAssetRemoteKey(String? remoteKey) =>
    remoteKey != null && remoteKey.startsWith('$kWebsiteAssetBucket/');

/// The bucket-relative object key of a `website-assets` remoteKey, or null
/// when [remoteKey] doesn't point into that bucket.
String? websiteAssetObjectKeyFromRemoteKey(String? remoteKey) {
  if (!isWebsiteAssetRemoteKey(remoteKey)) return null;
  final key = remoteKey!.substring('$kWebsiteAssetBucket/'.length);
  return key.isEmpty ? null : key;
}

/// Percent-encode an object key for use in a request URL, per path
/// segment (keeps '/'). Filenames legitimately contain spaces, '#', '?',
/// '&' etc. — unencoded they corrupt the URL (fragment/query truncation)
/// or throw in Uri.parse. The server decodes back to the raw key, so
/// PUT/HEAD/GET all address the same object.
String encodeObjectKeyForUrl(String objectKey) =>
    objectKey.split('/').map(Uri.encodeComponent).join('/');

String _fmtMb(int bytes) {
  final mb = bytes / (1024 * 1024);
  return mb >= 10 ? '${mb.round()}MB' : '${mb.toStringAsFixed(1)}MB';
}

/// Validate one picked file from Blob METADATA ONLY (name + size) — must be
/// callable before any byte is read or sent. [groupKnownBytes] is the sum of
/// known sizes already in the group (ready assets + queued/active jobs).
({bool ok, String? reason}) validateWebsiteAssetImport({
  required String fileName,
  required int sizeBytes,
  required int groupKnownBytes,
}) {
  final dot = fileName.lastIndexOf('.');
  final ext = dot < 0 ? '' : fileName.substring(dot);
  final cap = websiteMaxFileSizeBytesForExt(ext);
  if (cap == 0) {
    return (
      ok: false,
      reason: '$fileName: unsupported file type'
          '${ext.isEmpty ? '' : ' ($ext)'}',
    );
  }
  if (sizeBytes > cap) {
    return (
      ok: false,
      reason:
          '$fileName: too large (${_fmtMb(sizeBytes)} — max ${_fmtMb(cap)} '
          'for $ext files)',
    );
  }
  if (groupKnownBytes + sizeBytes > kWebsiteMaxTotalUploadBytes) {
    return (
      ok: false,
      reason: '$fileName: group total would exceed '
          '${_fmtMb(kWebsiteMaxTotalUploadBytes)}',
    );
  }
  return (ok: true, reason: null);
}

/// The composite S3 multipart ETag shape (`{32-hex}-{partCount}`) — NOT a
/// CID; must never be recorded as one (it would poison the manifest and the
/// generated site's asset URLs).
final RegExp _compositeEtag = RegExp(r'^[0-9a-f]{32}-\d+$');

/// De-quote a PUT/HEAD response ETag into the object's public IPFS CID.
/// Returns null for missing/empty values and for the composite multipart
/// shape, so callers fall back to HEAD (or fail loudly) instead of storing
/// a non-CID.
String? cidFromEtagHeader(String? etag) {
  if (etag == null) return null;
  final v = etag.replaceAll('"', '').trim();
  if (v.isEmpty) return null;
  if (_compositeEtag.hasMatch(v)) return null;
  return v;
}

/// Whether a failed upload attempt should be retried automatically.
/// [attempt] is the 1-based number of the attempt that just failed;
/// [status] is the HTTP status (0 = network error / stall / no response).
/// Policy: ONE automatic retry, and only for transient failures (network or
/// 5xx). Client errors (4xx — auth, missing bucket, bad request) never
/// auto-retry; the user gets a manual Retry button instead.
bool shouldRetryUpload({required int attempt, required int status}) {
  if (attempt >= 2) return false;
  return status == 0 || status >= 500;
}
