import 'dart:io';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/models/recent_file.dart';

class ImageViewerScreen extends StatefulWidget {
  final String filePath;

  const ImageViewerScreen({super.key, required this.filePath});

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  final TransformationController _transformController = TransformationController();
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _trackRecentFile();
  }

  Future<void> _trackRecentFile() async {
    final file = File(widget.filePath);
    if (await file.exists()) {
      final stat = await file.stat();
      await LocalStorageService.instance.addRecentFile(RecentFile(
        path: widget.filePath,
        name: widget.filePath.split(Platform.pathSeparator).last,
        mimeType: 'image/*',
        size: stat.size,
        accessedAt: DateTime.now(),
      ));
    }
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final file = File(widget.filePath);
    final fileName = widget.filePath.split(Platform.pathSeparator).last;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _showControls ? AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: Text(fileName, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.share),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Sharing: ${widget.filePath.split(Platform.pathSeparator).last}')),
              );
            },
          ),
          IconButton(
            icon: const Icon(LucideIcons.info),
            onPressed: () => _showFileInfo(context, file),
          ),
        ],
      ) : null,
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        child: InteractiveViewer(
          transformationController: _transformController,
          minScale: 0.5,
          maxScale: 4.0,
          child: Center(
            child: file.existsSync()
              ? Image.file(file, fit: BoxFit.contain)
              : const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(LucideIcons.imageOff, size: 64, color: Colors.white54),
                    SizedBox(height: 16),
                    Text('Image not found', style: TextStyle(color: Colors.white54)),
                  ],
                ),
          ),
        ),
      ),
      bottomNavigationBar: _showControls ? BottomAppBar(
        color: Colors.black54,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: const Icon(LucideIcons.rotateCcw, color: Colors.white),
              onPressed: () => _transformController.value = Matrix4.identity(),
              tooltip: 'Reset zoom',
            ),
            IconButton(
              icon: const Icon(LucideIcons.zoomIn, color: Colors.white),
              onPressed: _zoomIn,
              tooltip: 'Zoom in',
            ),
            IconButton(
              icon: const Icon(LucideIcons.zoomOut, color: Colors.white),
              onPressed: _zoomOut,
              tooltip: 'Zoom out',
            ),
          ],
        ),
      ) : null,
    );
  }

  void _zoomIn() {
    final currentScale = _transformController.value.getMaxScaleOnAxis();
    if (currentScale < 4.0) {
      _transformController.value = Matrix4.diagonal3Values(currentScale * 1.5, currentScale * 1.5, 1.0);
    }
  }

  void _zoomOut() {
    final currentScale = _transformController.value.getMaxScaleOnAxis();
    if (currentScale > 0.5) {
      _transformController.value = Matrix4.diagonal3Values(currentScale / 1.5, currentScale / 1.5, 1.0);
    }
  }

  void _showFileInfo(BuildContext context, File file) async {
    final stat = await file.stat();
    if (!context.mounted) return;
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('File Info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow('Name', widget.filePath.split(Platform.pathSeparator).last),
            _infoRow('Path', widget.filePath),
            _infoRow('Size', _formatSize(stat.size)),
            _infoRow('Modified', stat.modified.toString().split('.').first),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text('$label:', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
