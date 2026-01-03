import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/services/video_thumbnail_service.dart';

class FileThumbnail extends StatelessWidget {
  final LocalFile file;
  final double size;
  final BorderRadius? borderRadius;
  final bool showVideoThumbnail;

  const FileThumbnail({
    super.key,
    required this.file,
    this.size = 48,
    this.borderRadius,
    this.showVideoThumbnail = true,
  });

  bool get _isVideo {
    final ext = file.extension.toLowerCase();
    return ['mp4', 'mov', 'avi', 'mkv', 'webm', 'flv', '3gp', 'm4v'].contains(ext);
  }

  @override
  Widget build(BuildContext context) {
    if (file.isDirectory) {
      return _buildIconThumbnail(LucideIcons.folder, Colors.amber);
    }

    // Handle SVG files separately
    if (file.extension.toLowerCase() == 'svg') {
      return _buildSvgThumbnail();
    }

    if (file.isImage) {
      return _buildImageThumbnail();
    }

    // Handle video files with thumbnails
    if (_isVideo && showVideoThumbnail) {
      return _VideoThumbnailWidget(
        videoPath: file.path,
        size: size,
        borderRadius: borderRadius,
      );
    }

    return _buildIconThumbnail(_getFileIcon(), _getIconColor());
  }

  Widget _buildSvgThumbnail() {
    final svgFile = File(file.path);
    if (!svgFile.existsSync()) {
      return _buildIconThumbnail(LucideIcons.image, Colors.green);
    }

    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(8),
      child: Container(
        width: size,
        height: size,
        color: Colors.white,
        child: SvgPicture.file(
          svgFile,
          width: size,
          height: size,
          fit: BoxFit.contain,
          placeholderBuilder: (_) => _buildIconThumbnail(LucideIcons.image, Colors.green),
        ),
      ),
    );
  }

  Widget _buildImageThumbnail() {
    final imageFile = File(file.path);
    if (!imageFile.existsSync()) {
      return _buildIconThumbnail(LucideIcons.image, Colors.green);
    }

    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(8),
      child: Image.file(
        imageFile,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * 2).toInt(),
        errorBuilder: (_, __, ___) => _buildIconThumbnail(LucideIcons.image, Colors.green),
      ),
    );
  }

  Widget _buildIconThumbnail(IconData icon, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: borderRadius ?? BorderRadius.circular(8),
      ),
      child: Icon(icon, color: color, size: size * 0.5),
    );
  }

  IconData _getFileIcon() {
    final ext = file.extension.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'].contains(ext)) return LucideIcons.image;
    if (['mp4', 'mov', 'avi', 'mkv', 'webm', 'flv'].contains(ext)) return LucideIcons.video;
    if (['mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a'].contains(ext)) return LucideIcons.music;
    if (['pdf'].contains(ext)) return LucideIcons.fileText;
    if (['doc', 'docx'].contains(ext)) return LucideIcons.fileType;
    if (['xls', 'xlsx'].contains(ext)) return LucideIcons.sheet;
    if (['ppt', 'pptx'].contains(ext)) return LucideIcons.presentation;
    if (['txt', 'md', 'rtf'].contains(ext)) return LucideIcons.fileText;
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) return LucideIcons.archive;
    if (['apk'].contains(ext)) return LucideIcons.smartphone;
    if (['dart', 'js', 'ts', 'py', 'java', 'kt', 'swift', 'go', 'rs', 'c', 'cpp', 'h'].contains(ext)) return LucideIcons.code;
    if (['html', 'css', 'xml', 'json', 'yaml', 'yml'].contains(ext)) return LucideIcons.code;
    return LucideIcons.file;
  }

  Color _getIconColor() {
    final ext = file.extension.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'].contains(ext)) return Colors.green;
    if (['mp4', 'mov', 'avi', 'mkv', 'webm', 'flv'].contains(ext)) return Colors.red;
    if (['mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a'].contains(ext)) return Colors.orange;
    if (['pdf'].contains(ext)) return Colors.red;
    if (['doc', 'docx'].contains(ext)) return Colors.blue;
    if (['xls', 'xlsx'].contains(ext)) return Colors.green;
    if (['ppt', 'pptx'].contains(ext)) return Colors.deepOrange;
    if (['txt', 'md', 'rtf'].contains(ext)) return Colors.blueGrey;
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) return Colors.brown;
    if (['apk'].contains(ext)) return Colors.teal;
    if (['dart', 'js', 'ts', 'py', 'java', 'kt', 'swift', 'go', 'rs', 'c', 'cpp', 'h'].contains(ext)) return Colors.purple;
    if (['html', 'css', 'xml', 'json', 'yaml', 'yml'].contains(ext)) return Colors.indigo;
    return Colors.grey;
  }
}

/// Optimized video thumbnail widget that loads thumbnails asynchronously
/// and caches them for performance
class _VideoThumbnailWidget extends StatefulWidget {
  final String videoPath;
  final double size;
  final BorderRadius? borderRadius;

  const _VideoThumbnailWidget({
    required this.videoPath,
    required this.size,
    this.borderRadius,
  });

  @override
  State<_VideoThumbnailWidget> createState() => _VideoThumbnailWidgetState();
}

class _VideoThumbnailWidgetState extends State<_VideoThumbnailWidget> {
  Uint8List? _thumbnailData;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(_VideoThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      final thumbnail = await VideoThumbnailService.instance.getThumbnail(
        widget.videoPath,
        quality: 50,
        maxWidth: (widget.size * 2).toInt(),
        maxHeight: (widget.size * 2).toInt(),
      );

      if (mounted) {
        setState(() {
          _thumbnailData = thumbnail;
          _isLoading = false;
          _hasError = thumbnail == null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final borderRadius = widget.borderRadius ?? BorderRadius.circular(8);

    // Show loading or error state
    if (_isLoading || _hasError || _thumbnailData == null) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.1),
          borderRadius: borderRadius,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              LucideIcons.video,
              color: Colors.red,
              size: widget.size * 0.5,
            ),
            if (_isLoading)
              Positioned(
                bottom: 4,
                right: 4,
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.red.withValues(alpha: 0.5),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    // Show thumbnail with play icon overlay
    return ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Image.memory(
            _thumbnailData!,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: widget.size,
              height: widget.size,
              color: Colors.red.withValues(alpha: 0.1),
              child: Icon(
                LucideIcons.video,
                color: Colors.red,
                size: widget.size * 0.5,
              ),
            ),
          ),
          // Play icon overlay
          Container(
            width: widget.size * 0.4,
            height: widget.size * 0.4,
            decoration: BoxDecoration(
              color: Colors.black54,
              shape: BoxShape.circle,
            ),
            child: Icon(
              LucideIcons.play,
              color: Colors.white,
              size: widget.size * 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
