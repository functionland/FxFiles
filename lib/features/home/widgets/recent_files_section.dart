import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/recent_file.dart';
import 'package:fula_files/core/services/local_storage_service.dart';

final recentFilesProvider = FutureProvider<List<RecentFile>>((ref) async {
  return LocalStorageService.instance.getRecentFiles(limit: 10);
});

class RecentFilesSection extends ConsumerWidget {
  const RecentFilesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recentFilesAsync = ref.watch(recentFilesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            'Recent',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        SizedBox(
          height: 120,
          child: recentFilesAsync.when(
            data: (files) {
              if (files.isEmpty) {
                return Center(
                  child: Text(
                    'No recent files',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                );
              }
              return ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: files.length,
                itemBuilder: (context, index) {
                  return _RecentFileCard(file: files[index]);
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
          ),
        ),
      ],
    );
  }
}

class _RecentFileCard extends StatelessWidget {
  final RecentFile file;

  const _RecentFileCard({required this.file});

  bool get _isMediaFile => file.isImage || file.isVideo;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openFile(context),
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: _isMediaFile ? 80 : 100,
          child: _isMediaFile ? _buildMediaCard() : _buildDocumentCard(),
        ),
      ),
    );
  }

  Widget _buildMediaCard() {
    // Taller aspect ratio for images/videos
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildMediaThumbnail(),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: Text(
              file.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.white),
            ),
          ),
        ),
        if (file.isVideo)
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(LucideIcons.play, size: 14, color: Colors.white),
            ),
          ),
      ],
    );
  }

  Widget _buildMediaThumbnail() {
    final imageFile = File(file.path);
    if (file.isImage && imageFile.existsSync()) {
      return Image.file(
        imageFile,
        fit: BoxFit.cover,
        cacheWidth: 160,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) {
            return child;
          }
          return _buildPlaceholder();
        },
        errorBuilder: (_, __, ___) => _buildPlaceholder(),
      );
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      color: _getIconColor().withValues(alpha: 0.2),
      child: Center(
        child: Icon(_getIcon(), color: _getIconColor(), size: 32),
      ),
    );
  }

  Widget _buildDocumentCard() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _getIconColor().withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_getIcon(), color: _getIconColor(), size: 24),
          ),
          const SizedBox(height: 8),
          Text(
            file.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }

  IconData _getIcon() {
    if (file.isImage) return LucideIcons.image;
    if (file.isVideo) return LucideIcons.video;
    if (file.isAudio) return LucideIcons.music;
    if (file.isDocument) return LucideIcons.fileText;
    return LucideIcons.file;
  }

  Color _getIconColor() {
    if (file.isImage) return Colors.green;
    if (file.isVideo) return Colors.red;
    if (file.isAudio) return Colors.orange;
    if (file.isDocument) return Colors.blue;
    return Colors.grey;
  }

  void _openFile(BuildContext context) {
    if (file.isImage) {
      context.push('/viewer/image', extra: file.path);
    } else if (file.isVideo) {
      context.push('/viewer/video', extra: file.path);
    } else if (file.extension == 'txt' || file.extension == 'md' || file.extension == 'json') {
      context.push('/viewer/text', extra: file.path);
    }
  }
}
