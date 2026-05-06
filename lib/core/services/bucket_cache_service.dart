import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:fula_files/core/services/secure_storage_service.dart';

/// Persists the most recent successful bucket-name list per signed-in user
/// so the Cloud Files screen can fall back to a stale list when
/// `fula.encListBuckets` fails (no DNS / master down / privacy invariant
/// blocks offline enumeration).
///
/// Keyed by a hash of [SecureStorageKeys.derivationEmail] — the same
/// identity that scopes the encryption forest. Sign-out clears the entry
/// via [clear]; signing in as a different user is a hash mismatch and
/// transparently treated as a cache miss.
class BucketCacheService {
  BucketCacheService._();

  static const String _kCacheKey = 'cached_buckets_v1';
  static const String _fOwner = 'owner';
  static const String _fBuckets = 'buckets';
  static const String _fFetchedAt = 'fetched_at';

  /// Persist the current bucket list. No-op if no derivation email is
  /// available yet (pre-sign-in), and skips the secure-storage write when
  /// the snapshot already matches what's cached — saves a Keychain write
  /// per Cloud Files mount in the steady-state.
  static Future<void> persist(List<String> buckets) async {
    final ownerHash = await _ownerHash();
    if (ownerHash == null) return;
    try {
      final existing = await SecureStorageService.instance.readJson(_kCacheKey);
      if (existing != null &&
          existing[_fOwner] == ownerHash &&
          _bucketListsEqual(existing[_fBuckets], buckets)) {
        return;
      }
      await SecureStorageService.instance.writeJson(_kCacheKey, {
        _fOwner: ownerHash,
        _fBuckets: buckets,
        _fFetchedAt: DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('BucketCacheService: persist failed: $e');
    }
  }

  static bool _bucketListsEqual(dynamic existing, List<String> fresh) {
    if (existing is! List) return false;
    if (existing.length != fresh.length) return false;
    for (var i = 0; i < fresh.length; i++) {
      if (existing[i] != fresh[i]) return false;
    }
    return true;
  }

  /// Read the cached list for the current user. Returns null on miss,
  /// owner mismatch, or malformed payload.
  static Future<({List<String> buckets, DateTime fetchedAt})?>
      readCache() async {
    final ownerHash = await _ownerHash();
    if (ownerHash == null) return null;
    try {
      final json = await SecureStorageService.instance.readJson(_kCacheKey);
      if (json == null) return null;
      if (json[_fOwner] != ownerHash) return null;
      final raw = json[_fBuckets];
      if (raw is! List) return null;
      final buckets = raw.whereType<String>().toList(growable: false);
      final fetchedAt =
          DateTime.tryParse(json[_fFetchedAt] as String? ?? '');
      if (fetchedAt == null) return null;
      return (buckets: buckets, fetchedAt: fetchedAt);
    } catch (e) {
      debugPrint('BucketCacheService: readCache failed: $e');
      return null;
    }
  }

  /// Drop the cache. Call from sign-out and any flow that invalidates the
  /// signed-in identity.
  static Future<void> clear() async {
    try {
      await SecureStorageService.instance.delete(_kCacheKey);
    } catch (e) {
      debugPrint('BucketCacheService: clear failed: $e');
    }
  }

  static Future<String?> _ownerHash() async {
    final email = await SecureStorageService.instance
        .read(SecureStorageKeys.derivationEmail);
    if (email == null || email.isEmpty) return null;
    final digest = sha256.convert(utf8.encode(email)).bytes;
    return base64UrlEncode(digest).substring(0, 16);
  }
}
