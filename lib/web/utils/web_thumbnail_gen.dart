import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'package:fula_files/web/services/web_device_class.dart';

/// Pure (browser-side) image → tiny JPEG thumbnail generator for the web grids.
///
/// Pipeline: `ui.instantiateImageCodec(targetWidth:)` does a browser-native
/// decode + downscale (fast, low memory even for big sources), then the
/// `image` package encodes a small JPEG. Aims ~10 KB so the cloud sidecar is
/// cheap to fetch. Returns null (→ caller shows an icon) on low-end devices,
/// oversized sources, or any failure — generation is always best-effort.

/// Don't decode a huge source just to thumbnail it (transient memory spike).
const int kThumbMaxSourceBytes = 10 * 1024 * 1024;

/// Target width of the downscaled thumbnail (height scales to preserve ratio).
const int kThumbTargetWidth = 128;

/// Upper bound on the encoded thumbnail; we step JPEG quality down to fit and
/// give up (icon) if even the lowest quality is over.
const int kThumbMaxBytes = 20 * 1024;

/// True for image file names the browser codec can decode for thumbnailing.
bool isThumbnailableImage(String name) {
  final i = name.lastIndexOf('.');
  if (i < 0) return false;
  final ext = name.substring(i + 1).toLowerCase();
  return const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'}.contains(ext);
}

/// Generate a small JPEG thumbnail from full-image [bytes], or null to fall
/// back to an icon.
Future<Uint8List?> generateImageThumbnail(Uint8List bytes) async {
  if (WebDeviceClass.lowEnd) return null;
  if (bytes.isEmpty || bytes.length > kThumbMaxSourceBytes) return null;
  ui.Image? image;
  ui.Codec? codec;
  try {
    codec =
        await ui.instantiateImageCodec(bytes, targetWidth: kThumbTargetWidth);
    final frame = await codec.getNextFrame();
    image = frame.image;
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) return null;
    final src = img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    // Step quality down until it fits the byte budget.
    for (final q in const [65, 50, 40]) {
      final out = img.encodeJpg(src, quality: q);
      if (out.length <= kThumbMaxBytes) return Uint8List.fromList(out);
    }
    return null; // couldn't compress small enough → icon
  } catch (e) {
    debugPrint('generateImageThumbnail: $e');
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
