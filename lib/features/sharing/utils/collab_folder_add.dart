/// Pure planning step for REQ2 "add a folder to a collaboration group".
///
/// Extracted from `CollaborationService.addFolderToGroup` so the decision logic
/// — which listed objects become group files — is unit-testable without the
/// network / FFI. The service then loops `addFileToGroup` over [PlanResult.toAdd]
/// (preserving each object's `pathScope`).
library;

import 'package:fula_files/core/models/fula_object.dart';

/// The objects to add plus how many listed items were skipped because they are
/// already in the group.
typedef PlanResult = ({List<FulaObject> toAdd, int skipped});

/// Decide which [objects] (a `listObjects(prefix)` result) to add to a group.
///
/// Excludes directories and the hidden `.fula_keep` folder markers entirely
/// (they are not user files). An object whose key is already in
/// [existingPathScopes] is counted as `skipped` (idempotent re-add). Everything
/// else goes into `toAdd`, preserving listing order.
PlanResult planCollabFolderAdd(
  List<FulaObject> objects,
  Set<String> existingPathScopes,
) {
  final toAdd = <FulaObject>[];
  var skipped = 0;
  for (final o in objects) {
    if (o.isDirectory || o.key.endsWith('.fula_keep')) continue;
    if (existingPathScopes.contains(o.key)) {
      skipped++;
      continue;
    }
    toAdd.add(o);
  }
  return (toAdd: toAdd, skipped: skipped);
}
