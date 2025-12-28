import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/face_storage_service.dart';
import 'package:fula_files/core/models/recent_file.dart';
import 'package:fula_files/core/models/face_data.dart';

class ImageViewerScreen extends StatefulWidget {
  final String filePath;

  const ImageViewerScreen({super.key, required this.filePath});

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  final TransformationController _transformController = TransformationController();
  bool _showControls = true;
  List<DetectedFace> _faces = [];
  bool _facesLoaded = false;

  @override
  void initState() {
    super.initState();
    _trackRecentFile();
    _loadFaces();
  }

  Future<void> _loadFaces() async {
    final faces = await FaceStorageService.instance.getFacesForImage(widget.filePath);
    if (mounted) {
      setState(() {
        _faces = faces;
        _facesLoaded = true;
      });
    }
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
              ? _buildImageWidget(file, fileName)
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
            if (_facesLoaded && _faces.isNotEmpty)
              IconButton(
                icon: Badge(
                  label: Text('${_faces.length}'),
                  child: const Icon(LucideIcons.scanFace, color: Colors.white),
                ),
                onPressed: _showFacesInImage,
                tooltip: 'People in this photo',
              ),
          ],
        ),
      ) : null,
    );
  }

  /// Build the appropriate image widget based on file type
  Widget _buildImageWidget(File file, String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    
    // Handle SVG files separately
    if (extension == 'svg') {
      return SvgPicture.file(
        file,
        fit: BoxFit.contain,
        placeholderBuilder: (context) => const CircularProgressIndicator(),
      );
    }
    
    // Regular image files (jpg, png, gif, webp, etc.)
    return Image.file(file, fit: BoxFit.contain);
  }

  Future<void> _showFacesInImage() async {
    // Get person info for each face
    final facePersonPairs = <(DetectedFace, Person?)>[];
    for (final face in _faces) {
      Person? person;
      if (face.personId != null) {
        person = await FaceStorageService.instance.getPerson(face.personId!);
      }
      facePersonPairs.add((face, person));
    }

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(LucideIcons.users, color: Colors.white),
                  const SizedBox(width: 8),
                  Text(
                    'People in this photo (${_faces.length})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 120,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: facePersonPairs.length,
                  itemBuilder: (ctx, index) {
                    final (face, person) = facePersonPairs[index];
                    final thumbnailFile = face.thumbnailPath != null 
                        ? File(face.thumbnailPath!) 
                        : null;
                    
                    return Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Column(
                        children: [
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: ClipOval(
                              child: thumbnailFile != null && thumbnailFile.existsSync()
                                  ? Image.file(thumbnailFile, fit: BoxFit.cover)
                                  : Container(
                                      color: Colors.grey[700],
                                      child: const Icon(LucideIcons.user, color: Colors.white54, size: 32),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: 80,
                            child: Text(
                              person?.name ?? 'Unknown',
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
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
