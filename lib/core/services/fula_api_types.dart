// Shared data types for the FulaApi surface.
//
// Lives in its own file so both the abstract `FulaApi` interface
// (`fula_api.dart`) and the concrete `FulaApiService` implementation
// (`fula_api_service.dart`) can import them without a cycle.
//
// **Public stability:** these types are part of the test surface.
// Renaming a field here will ripple through every fake + scenario
// test, so the policy is "add carefully, remove almost never". When
// fula-client changes its types (e.g. `FileMetadata.size` becomes
// `BigInt`), translate at the boundary in `FulaApiService` and keep
// these stable.

import 'dart:typed_data';

class UploadResult {
  final String etag;
  final String? contentCid;

  UploadResult({required this.etag, this.contentCid});
}

class UploadProgress {
  final int bytesUploaded;
  final int totalBytes;

  UploadProgress({
    required this.bytesUploaded,
    required this.totalBytes,
  });

  double get percentage =>
      totalBytes > 0 ? (bytesUploaded / totalBytes) * 100 : 0;
}

class BatchUploadItem {
  final String path;
  final Uint8List data;
  final String? contentType;

  BatchUploadItem({
    required this.path,
    required this.data,
    this.contentType,
  });
}

class IncompleteUploadInfo {
  final String? key;
  final String? uploadId;
  final DateTime? initiated;

  IncompleteUploadInfo({
    this.key,
    this.uploadId,
    this.initiated,
  });
}

class FulaApiException implements Exception {
  final String message;
  FulaApiException(this.message);

  @override
  String toString() => 'FulaApiException: $message';
}
