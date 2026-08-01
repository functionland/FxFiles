import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:fula_files/web/services/web_thumbnail_service.dart';

/// A small image thumbnail for the file grids at ([bucket],[objectKey]).
///
/// Shows the cached thumbnail instantly if present; otherwise — after a short
/// debounce so a fast-scrolled-past row never triggers a fetch — lazily pulls
/// the ~10 KB sidecar via [WebThumbnailService] (which is concurrency-capped
/// and de-duped). Falls back to [fallback] (a type icon) while loading or when
/// no thumbnail exists. The full file is never downloaded here.
class WebThumb extends StatefulWidget {
  final String bucket;
  final String objectKey;
  final double size;
  final Widget fallback;

  /// Fill the parent instead of painting at [size] — grid tiles size the
  /// thumbnail from their cell, list rows keep the fixed 40px leading
  /// slot. When true [size] is ignored and the corners are square (the
  /// grid tile does its own clipping).
  final bool fill;

  const WebThumb({
    super.key,
    required this.bucket,
    required this.objectKey,
    required this.fallback,
    this.size = 40,
    this.fill = false,
  });

  @override
  State<WebThumb> createState() => _WebThumbState();
}

class _WebThumbState extends State<WebThumb> {
  static const Duration _debounceDelay = Duration(milliseconds: 250);
  Uint8List? _bytes;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _bytes = WebThumbnailService.instance.peek(widget.bucket, widget.objectKey);
    if (_bytes == null) _schedule();
  }

  @override
  void didUpdateWidget(WebThumb old) {
    super.didUpdateWidget(old);
    // A virtualized list row was recycled for a different file.
    if (old.bucket != widget.bucket || old.objectKey != widget.objectKey) {
      _timer?.cancel();
      _bytes =
          WebThumbnailService.instance.peek(widget.bucket, widget.objectKey);
      if (_bytes == null) _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(_debounceDelay, () async {
      // Capture the identity this fetch was issued for: cancelling the
      // timer in didUpdateWidget can't cancel a fetch already awaiting,
      // so a recycled row would otherwise paint the PREVIOUS file's
      // thumbnail. A grid recycles far more aggressively than a list,
      // which makes this reachable in normal scrolling.
      final bucket = widget.bucket;
      final objectKey = widget.objectKey;
      final b = await WebThumbnailService.instance.get(bucket, objectKey);
      if (!mounted || b == null) return;
      if (bucket != widget.bucket || objectKey != widget.objectKey) return;
      setState(() => _bytes = b);
    });
  }

  @override
  void dispose() {
    _timer?.cancel(); // scrolled away before the debounce fired → never fetch
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b == null) return widget.fallback;
    if (widget.fill) {
      // Grid cell: the tile clips and sizes us. SizedBox.expand keeps the
      // image from laying out at its intrinsic size first (which would
      // shift the tile on every thumbnail arrival).
      return SizedBox.expand(
        child: Image.memory(
          b,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => widget.fallback,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.memory(
        b,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => widget.fallback,
      ),
    );
  }
}
