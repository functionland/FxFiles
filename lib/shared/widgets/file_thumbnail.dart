import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/local_file.dart';

class FileThumbnail extends StatelessWidget {
  final LocalFile file;
  final double size;
  final BorderRadius? borderRadius;

  const FileThumbnail({
    super.key,
    required this.file,
    this.size = 48,
    this.borderRadius,
  });

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
