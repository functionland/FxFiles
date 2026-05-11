// Deterministic test fixtures.
//
// Returns the same objects on every call so scenario tests can use
// equality matchers safely. Keep this file small and predictable —
// scenarios should compose these fixtures, not invent their own.

import 'dart:typed_data';

import 'package:fula_files/core/models/fula_object.dart';

/// A small image-bucket file (~50 KB, single-block path).
FulaObject get smallImageObject => FulaObject(
      key: 'images/IMG_20260101_000000.jpg',
      size: 51200,
      lastModified: DateTime.utc(2026, 1, 1),
      etag: 'bafkr4ihtestimagepathmustcontainvalidcidstringhere',
      metadata: const {
        'storageKey': 'Qmtestimagestoragekey0000000000',
        'contentType': 'image/jpeg',
        'isEncrypted': 'true',
      },
    );

/// A chunked (>768 KB) video file.
FulaObject get chunkedVideoObject => FulaObject(
      key: 'videos/VID_20260102_120000.mp4',
      size: 2500000,
      lastModified: DateTime.utc(2026, 1, 2, 12),
      etag: 'bafkr4ihtestvideomustcontainvalidcidstringhereoke',
      metadata: const {
        'storageKey': 'Qmtestvideostoragekey0000000000',
        'contentType': 'video/mp4',
        'isEncrypted': 'true',
      },
    );

/// A second small image (so listObjects tests can assert ordering /
/// deduplication / count).
FulaObject get secondImageObject => FulaObject(
      key: 'images/IMG_20260103_140000.jpg',
      size: 80000,
      lastModified: DateTime.utc(2026, 1, 3, 14),
      etag: 'bafkr4ihsecondtestimagecidvalidstringherereallyok',
      metadata: const {
        'storageKey': 'Qmtestimage2storagekey00000000',
        'contentType': 'image/jpeg',
        'isEncrypted': 'true',
      },
    );

/// The full set of buckets FxFiles uses, in the order
/// `FulaApiService` typically reports them.
const List<String> stockBuckets = <String>[
  'images',
  'videos',
  'documents',
  'audio',
  'other',
  'apps',
  'tag-metadata',
  'website-metadata',
  'nft-metadata',
  'face-metadata',
  'fula-metadata',
];

/// Deterministic bytes for a small upload. 1 KiB of repeating
/// pattern so test assertions can re-derive it from a known input.
Uint8List get smallUploadPayload =>
    Uint8List.fromList(List<int>.generate(1024, (i) => i & 0xFF));

/// Same shape but 2 KiB so two distinct uploads can be distinguished.
Uint8List get secondUploadPayload =>
    Uint8List.fromList(List<int>.generate(2048, (i) => (i * 3) & 0xFF));
