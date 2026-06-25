// Move-as-access-control for the AI workspace (1.iii).
//
// Moving a file INTO `fula-ai-workspace` re-encrypts it under the workspace
// secret + forest-indexes it (the AI gains read). Moving it OUT re-encrypts it
// under the master KEK in a normal bucket and removes the workspace copy (the AI
// loses read). The owner keeps the file either way.
//
// This is the UI-free orchestration shared by rename + move, factored out of the
// cloud-files screen so the security-critical REVOKE path is unit-testable: a
// move-out must (1) verify the re-encrypted destination decrypts under the master
// KEK BEFORE deleting the only-AI copy, then (2) verify the AI copy is actually
// gone — and report `revoke incomplete` loudly otherwise (the AI keeps exact-key
// read until the delete lands, so a silent failure would leave access un-revoked).

import 'dart:typed_data';

import 'package:fula_files/core/services/fula_api.dart';
import 'package:fula_files/core/services/fula_api_service.dart'
    show FulaApiService;

/// The outcome of [aiAwareMove], mapped to UI messaging by the caller.
enum AiMoveResult {
  /// A normal move/rename between non-AI buckets (or within one).
  moved,

  /// Moved INTO the AI bucket — the AI can now read it.
  grantedToAi,

  /// Moved OUT of the AI bucket — AI access removed, and VERIFIED removed.
  revokedFromAi,

  /// The download / re-upload failed; the source is untouched.
  copyFailed,

  /// (Revoke) the re-encrypted destination did NOT decrypt under the master KEK;
  /// the AI copy is KEPT rather than deleting the only readable copy.
  verifyFailed,

  /// The source delete failed. For a revoke this means AI access was NOT removed.
  deleteFailed,

  /// (Revoke) the delete returned OK but the AI copy still enumerates — access is
  /// NOT actually revoked.
  revokeIncomplete,
}

/// Copy → (revoke-verify) → delete → (revoke-verify-gone), routing each side to
/// the workspace client (the AI bucket) or the master-KEK client (everything
/// else). Pure over [FulaApi] (no UI / no global state), so it is unit-testable.
Future<AiMoveResult> aiAwareMove(
  FulaApi api, {
  required String srcBucket,
  required String srcKey,
  required String destBucket,
  required String destKey,
  String? contentType,
}) async {
  final ws = FulaApiService.aiWorkspaceBucket;
  final srcIsAi = srcBucket == ws;
  final destIsAi = destBucket == ws;
  final isRevoke = srcIsAi && !destIsAi; // moving OUT of the AI bucket

  // 1. COPY: download from the right client → re-upload to the right client.
  try {
    final Uint8List bytes = srcIsAi
        ? await api.downloadWorkspaceObject(srcBucket, srcKey)
        : await api.downloadObject(srcBucket, srcKey);
    if (destIsAi) {
      await api.uploadWorkspaceObject(destBucket, destKey, bytes,
          contentType: contentType);
    } else {
      await api.uploadObject(destBucket, destKey, bytes,
          contentType: contentType);
    }
  } catch (_) {
    return AiMoveResult.copyFailed;
  }

  // 2. REVOKE SAFETY: verify the re-encrypted destination is readable under the
  //    master KEK BEFORE deleting the AI copy.
  if (isRevoke) {
    try {
      await api.downloadObject(destBucket, destKey);
    } catch (_) {
      return AiMoveResult.verifyFailed;
    }
  }

  // 3. DELETE the source from the right client.
  try {
    if (srcIsAi) {
      await api.deleteWorkspaceObject(srcBucket, srcKey);
    } else {
      await api.deleteObject(srcBucket, srcKey);
    }
  } catch (_) {
    return AiMoveResult.deleteFailed;
  }

  // 4. REVOKE VERIFY: confirm the AI copy is actually gone (no longer
  //    enumerable). A lingering entry means access was NOT revoked.
  if (isRevoke) {
    try {
      final still = await api.listWorkspaceObjects(srcBucket, prefix: srcKey);
      if (still.any((x) => x.key == srcKey)) {
        return AiMoveResult.revokeIncomplete;
      }
    } catch (_) {
      // Verification read failed; the delete returned OK, so treat as done.
    }
  }

  return isRevoke
      ? AiMoveResult.revokedFromAi
      : (destIsAi ? AiMoveResult.grantedToAi : AiMoveResult.moved);
}
