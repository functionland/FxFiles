import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'package:fula_files/web/services/web_audio_controller.dart';
import 'package:fula_files/web/services/web_listing_cache.dart';
import 'package:fula_files/web/services/web_prefetch_scheduler.dart';
import 'package:fula_files/web/services/web_recent_files_service.dart';

/// Cross-tab cache coherence (plan §8 multi-tab): a delete in tab A
/// must not survive in tab B, and a sign-out anywhere must drop every
/// tab's in-memory state.
///
/// Shares the 'fxfiles-cache' BroadcastChannel NAME with the prefetch
/// scheduler's dedup protocol but uses its OWN channel instance —
/// same-origin instances all receive each other's posts, and each
/// handler ignores the other's message kinds. Message wire format is
/// plain strings: `inv-listing:<bucket>`, `inv-manifest:<bucket>|<key>`,
/// `signed-out`.
class WebCacheSync {
  WebCacheSync._();
  static final WebCacheSync instance = WebCacheSync._();

  web.BroadcastChannel? _channel;

  /// Wired by WebSession at boot: a remote tab signed out — drop this
  /// tab's session state (storage was already cleared by the
  /// originator; receivers must stop trusting in-memory copies).
  static void Function()? onRemoteSignOut;

  void ensureStarted() {
    if (_channel != null) return;
    try {
      final ch = web.BroadcastChannel('fxfiles-cache');
      _channel = ch;
      ch.onmessage = ((web.MessageEvent e) {
        final data = e.data;
        if (data == null) return;
        final s = (data.dartify() ?? '').toString();
        if (s.startsWith('inv-listing:')) {
          final bucket = s.substring(12);
          debugPrint('WebCacheSync: remote invalidate listing $bucket');
          WebListingCache.instance.dropListing(bucket);
        } else if (s.startsWith('inv-manifest:')) {
          final rest = s.substring(13);
          final sep = rest.indexOf('|');
          if (sep > 0) {
            final bucket = rest.substring(0, sep);
            final key = rest.substring(sep + 1);
            debugPrint(
                'WebCacheSync: remote invalidate manifest $bucket/$key');
            WebListingCache.instance.dropManifest(bucket, key);
          }
        } else if (s == 'signed-out') {
          debugPrint('WebCacheSync: remote sign-out');
          // deactivate (not just clearL1): closes this tab's box
          // handle so the originator's deleteFromDisk isn't blocked
          // and no in-flight write can leak into the deleted box.
          WebListingCache.instance.deactivate();
          WebRecentFilesService.instance.deactivate();
          WebPrefetchScheduler.instance.reset();
          WebAudioController.instance.stopPlayback();
          onRemoteSignOut?.call();
        }
        // 'prefetch-*' messages belong to the scheduler's instance.
      }).toJS;
    } catch (e) {
      debugPrint('WebCacheSync: BroadcastChannel unavailable: $e');
    }
  }

  void _post(String message) {
    ensureStarted();
    try {
      _channel?.postMessage(message.toJS);
    } catch (e) {
      debugPrint('WebCacheSync: post failed: $e');
    }
  }

  /// A listing-changing mutation happened in THIS tab (upload/delete).
  void sendInvalidateListing(String bucket) => _post('inv-listing:$bucket');

  /// A manifest was uploaded from THIS tab (write-through already
  /// updated the local cache).
  void sendInvalidateManifest(String bucket, String key) =>
      _post('inv-manifest:$bucket|$key');

  void sendSignedOut() => _post('signed-out');
}
