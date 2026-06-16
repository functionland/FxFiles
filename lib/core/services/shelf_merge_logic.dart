/// Pure helper behind the native shelf's MERGE-BEFORE-WRITE clobber guard.
///
/// The shelf manifest is a full-snapshot, last-writer-wins blob written by
/// BOTH the native app and the web app. Before native overwrites it with
/// its local box, it must fold in any items the cloud manifest has that
/// this device doesn't — otherwise the overwrite drops items added on
/// another device (the web→native clobber bug).
///
/// This function decides WHICH cloud items to fold in. It is deliberately
/// pure (no IO) so it's unit-testable; the IO (decrypt + parse + box.put)
/// lives in `ShelfStorageService`.
library;

import 'package:fula_files/core/models/shelf_item.dart';

/// Cloud items to fold into the local box before a full-snapshot upload.
///
/// Excludes:
///   - items already present locally ([boxIds]) — nothing to add;
///   - tombstoned ids ([tombstonedIds]) — items the user deleted locally
///     whose cloud cleanup is still pending; re-adding them would
///     RESURRECT a just-deleted item.
///
/// [cloudItemsV8First] is the concatenation of the decrypted manifests in
/// priority order (v8 first, then legacy); the first occurrence of an id
/// wins (v8 over legacy), matching the read-side merge.
List<ShelfItem> shelfCloudAdditions({
  required Set<String> boxIds,
  required Set<String> tombstonedIds,
  required List<ShelfItem> cloudItemsV8First,
}) {
  final out = <ShelfItem>[];
  final seen = <String>{};
  for (final item in cloudItemsV8First) {
    if (!seen.add(item.id)) continue; // first (v8) wins a duplicate id
    if (boxIds.contains(item.id)) continue; // already have it locally
    if (tombstonedIds.contains(item.id)) continue; // locally deleted — skip
    out.add(item);
  }
  return out;
}
