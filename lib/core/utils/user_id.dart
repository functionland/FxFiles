// Shared per-user id derivation (v8 migration — used as the LegacyListingCache
// key so one user can't read another's cached listing).
//
// Mirrors the `_getUserId()` pattern already duplicated across services
// (cloud_sync_mapping, folder_watch, shelf_storage, nft, …): the first 16 hex
// chars of sha256(publicKey). Returns null when signed out.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:fula_files/core/services/auth_service.dart';

Future<String?> deriveUserId() async {
  final publicKey = await AuthService.instance.getPublicKeyString();
  if (publicKey == null) return null;
  return sha256.convert(utf8.encode(publicKey)).toString().substring(0, 16);
}
