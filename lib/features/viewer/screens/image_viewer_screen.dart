import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/face_storage_service.dart';
import 'package:fula_files/core/services/face_detection_service.dart';
import 'package:fula_files/core/models/recent_file.dart';
import 'package:fula_files/core/models/face_data.dart';
import 'package:fula_files/features/viewer/screens/image_editor_screen.dart';

class ImageViewerScreen extends StatefulWidget {
  final String filePath;
  final List<String>? imageList;
  final int? initialIndex;

  const ImageViewerScreen({
    super.key,
    required this.filePath,
    this.imageList,
    this.initialIndex,
  });

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen>
    with TickerProviderStateMixin {
  late PageController _pageController;
  late List<String> _images;
  late int _currentIndex;
  bool _imagesLoaded = false;

  bool _showControls = true;
  bool _showDetails = false;

  // Zoom state per page
  final Map<int, TransformationController> _transformControllers = {};
  final Map<int, bool> _isZoomedMap = {};

  bool get _isCurrentPageZoomed => _isZoomedMap[_currentIndex] ?? false;

  // Gesture tracking - track number of pointers to distinguish pinch from swipe
  int _pointerCount = 0;
  Offset? _swipeStartPosition;
  bool _isSwipeGesture = false;
  DateTime? _firstPointerDownTime;
  bool _wasMultiTouch = false; // Track if gesture ever had multiple fingers

  // Double-tap detection
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;


  // Face data
  List<DetectedFace> _faces = [];
  bool _facesLoaded = false;
  bool _isDetectingFaces = false;

  // File info
  FileStat? _fileStat;

  // Animation controllers
  late AnimationController _detailsAnimController;
  late Animation<double> _detailsAnimation;
  late AnimationController _controlsAnimController;
  late Animation<double> _controlsAnimation;

  @override
  void initState() {
    super.initState();
    _initializeImages();

    _detailsAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _detailsAnimation = CurvedAnimation(
      parent: _detailsAnimController,
      curve: Curves.easeOutCubic,
    );

    _controlsAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 1.0,
    );
    _controlsAnimation = CurvedAnimation(
      parent: _controlsAnimController,
      curve: Curves.easeInOut,
    );

    _trackRecentFile();
  }

  void _initializeImages() {
    if (widget.imageList != null && widget.imageList!.isNotEmpty) {
      // Use the provided image list exactly as is
      _images = List<String>.from(widget.imageList!);
      _currentIndex = widget.initialIndex ?? _images.indexOf(widget.filePath);
      if (_currentIndex < 0) _currentIndex = 0;
      _imagesLoaded = true;
      _pageController = PageController(initialPage: _currentIndex);
      _loadFileInfo();
      _loadFaces();
    } else {
      // Single image initially, load siblings from directory
      _images = [widget.filePath];
      _currentIndex = 0;
      _pageController = PageController(initialPage: 0);
      _loadImagesFromDirectory();
    }
  }

  Future<void> _loadImagesFromDirectory() async {
    final dir = Directory(p.dirname(widget.filePath));
    final imageExtensions = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'svg'];

    try {
      final entities = await dir.list().toList();
      final images = <String>[];

      for (final entity in entities) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
          if (imageExtensions.contains(ext)) {
            images.add(entity.path);
          }
        }
      }

      // Sort alphabetically for consistent ordering
      images.sort((a, b) => p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));

      if (mounted && images.isNotEmpty) {
        final newIndex = images.indexOf(widget.filePath);
        setState(() {
          _images = images;
          _currentIndex = newIndex >= 0 ? newIndex : 0;
          _imagesLoaded = true;
        });

        // Jump to correct page without animation
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageController.hasClients) {
            _pageController.jumpToPage(_currentIndex);
          }
        });

        _loadFileInfo();
        _loadFaces();
      } else {
        setState(() => _imagesLoaded = true);
        _loadFileInfo();
        _loadFaces();
      }
    } catch (e) {
      setState(() => _imagesLoaded = true);
      _loadFileInfo();
      _loadFaces();
    }
  }

  TransformationController _getTransformController(int index) {
    if (!_transformControllers.containsKey(index)) {
      final controller = TransformationController();
      controller.addListener(() => _onTransformChanged(index));
      _transformControllers[index] = controller;
    }
    return _transformControllers[index]!;
  }

  void _onTransformChanged(int index) {
    final controller = _transformControllers[index];
    if (controller == null) return;

    final scale = controller.value.getMaxScaleOnAxis();
    final wasZoomed = _isZoomedMap[index] ?? false;
    final isNowZoomed = scale > 1.05;

    if (wasZoomed != isNowZoomed) {
      setState(() {
        _isZoomedMap[index] = isNowZoomed;
      });
    }
  }

  Future<void> _loadFaces() async {
    if (_images.isEmpty) return;
    final currentPath = _images[_currentIndex];
    final faces = await FaceStorageService.instance.getFacesForImage(currentPath);
    if (mounted) {
      setState(() {
        _faces = faces;
        _facesLoaded = true;
      });
    }
  }

  Future<void> _loadFileInfo() async {
    if (_images.isEmpty) return;
    final file = File(_images[_currentIndex]);
    if (await file.exists()) {
      final stat = await file.stat();
      if (mounted) {
        setState(() => _fileStat = stat);
      }
    }
  }

  Future<void> _trackRecentFile() async {
    final file = File(widget.filePath);
    if (await file.exists()) {
      final stat = await file.stat();
      await LocalStorageService.instance.addRecentFile(RecentFile(
        path: widget.filePath,
        name: p.basename(widget.filePath),
        mimeType: 'image/*',
        size: stat.size,
        accessedAt: DateTime.now(),
      ));
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _detailsAnimController.dispose();
    _controlsAnimController.dispose();
    for (final controller in _transformControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onPageChanged(int index) {
    if (index == _currentIndex) return;

    setState(() {
      _currentIndex = index;
      _facesLoaded = false;
      _faces = [];
      _fileStat = null;
    });
    _loadFaces();
    _loadFileInfo();
  }

  void _handleDoubleTap(int index) {
    final controller = _getTransformController(index);
    final scale = controller.value.getMaxScaleOnAxis();

    if (scale > 1.05) {
      // Animate back to normal
      controller.value = Matrix4.identity();
    } else {
      // Zoom to 2.5x centered
      controller.value = Matrix4.identity()..scale(2.5);
    }
  }

  void _toggleControls() {
    if (_showDetails) {
      _hideDetailsPanel();
      return;
    }

    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _controlsAnimController.forward();
    } else {
      _controlsAnimController.reverse();
    }
  }

  void _showDetailsPanel() {
    setState(() {
      _showDetails = true;
      _showControls = false;
    });
    _controlsAnimController.reverse();
    _detailsAnimController.forward();
  }

  void _hideDetailsPanel() {
    _detailsAnimController.reverse().then((_) {
      if (mounted) {
        setState(() {
          _showDetails = false;
          _showControls = true;
        });
        _controlsAnimController.forward();
      }
    });
  }

  Future<void> _detectFaces() async {
    if (_images.isEmpty) return;
    final currentPath = _images[_currentIndex];

    setState(() => _isDetectingFaces = true);

    try {
      final faces = await FaceDetectionService.instance.processImage(currentPath);

      if (mounted) {
        setState(() {
          _faces = faces;
          _facesLoaded = true;
          _isDetectingFaces = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Found ${faces.length} face(s)')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isDetectingFaces = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Face detection failed: $e')),
        );
      }
    }
  }

  void _openEditor() async {
    if (_images.isEmpty) return;
    final currentPath = _images[_currentIndex];
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => ImageEditorScreen(filePath: currentPath),
      ),
    );

    if (result != null && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_images.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
        ),
        body: const Center(
          child: Text('No image to display', style: TextStyle(color: Colors.white54)),
        ),
      );
    }

    final currentPath = _images[_currentIndex];
    final fileName = p.basename(currentPath);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Main image viewer - positioned to fill entire screen
          Positioned.fill(
            child: _buildImageViewer(),
          ),

          // Top controls overlay (always in the same position)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildTopBar(fileName),
          ),

          // Bottom controls overlay
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildBottomBar(),
          ),

          // Swipe up indicator
          if (!_showDetails && !_isCurrentPageZoomed && _showControls)
            Positioned(
              bottom: 90,
              left: 0,
              right: 0,
              child: FadeTransition(
                opacity: _controlsAnimation,
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        LucideIcons.chevronUp,
                        color: Colors.white.withOpacity(0.4),
                        size: 20,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Swipe up for details',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.4),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Page indicators
          if (_images.length > 1 && _showControls && !_showDetails)
            Positioned(
              bottom: 75,
              left: 0,
              right: 0,
              child: FadeTransition(
                opacity: _controlsAnimation,
                child: _buildPageIndicator(),
              ),
            ),

          // Details panel (slides up from bottom)
          _buildDetailsPanel(),
        ],
      ),
    );
  }

  Widget _buildImageViewer() {
    // Always disable PageView's built-in scrolling - we handle swipes manually
    return PageView.builder(
      controller: _pageController,
      onPageChanged: _onPageChanged,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _images.length,
      itemBuilder: (context, index) {
        return _buildImagePage(index);
      },
    );
  }

  Widget _buildImagePage(int index) {
    final file = File(_images[index]);
    final controller = _getTransformController(index);
    final isZoomed = _isZoomedMap[index] ?? false;

    if (!file.existsSync()) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.imageOff, size: 64, color: Colors.white54),
            SizedBox(height: 16),
            Text('Image not found', style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }

    // Use Listener to observe pointer events WITHOUT interfering with InteractiveViewer
    return Listener(
      onPointerDown: (event) {
        _pointerCount++;
        if (_pointerCount == 1) {
          _swipeStartPosition = event.position;
          _firstPointerDownTime = DateTime.now();
          _isSwipeGesture = false;
          _wasMultiTouch = false;
        } else {
          // Second+ finger touched - this is a multi-touch gesture (zoom)
          _wasMultiTouch = true;
        }
      },
      onPointerUp: (event) {
        _pointerCount = (_pointerCount - 1).clamp(0, 10);

        // Handle gestures only for single-finger that didn't become multi-touch
        if (_pointerCount == 0 && !_wasMultiTouch && _swipeStartPosition != null) {
          final delta = event.position - _swipeStartPosition!;
          final distance = delta.distance;

          if (distance < 20) {
            // This was a tap
            final now = DateTime.now();

            // Check for double-tap
            if (_lastTapTime != null &&
                _lastTapPosition != null &&
                now.difference(_lastTapTime!).inMilliseconds < 300 &&
                (event.position - _lastTapPosition!).distance < 50) {
              _handleDoubleTap(index);
              _lastTapTime = null;
              _lastTapPosition = null;
            } else {
              _lastTapTime = now;
              _lastTapPosition = event.position;
              Future.delayed(const Duration(milliseconds: 300), () {
                if (_lastTapTime == now) {
                  _toggleControls();
                  _lastTapTime = null;
                  _lastTapPosition = null;
                }
              });
            }
          } else if (!_isSwipeGesture && !isZoomed) {
            // This was a swipe - check direction
            if (delta.dx.abs() > delta.dy.abs() && delta.dx.abs() > 50) {
              // Horizontal swipe - change page
              if (delta.dx < 0 && _currentIndex < _images.length - 1) {
                // Swipe left - next image
                _pageController.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              } else if (delta.dx > 0 && _currentIndex > 0) {
                // Swipe right - previous image
                _pageController.previousPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              }
            }
          }
        }

        // Reset when all fingers are lifted
        if (_pointerCount == 0) {
          _swipeStartPosition = null;
          _firstPointerDownTime = null;
          _wasMultiTouch = false;
          _isSwipeGesture = false;
        }
      },
      onPointerCancel: (event) {
        _pointerCount = (_pointerCount - 1).clamp(0, 10);
        if (_pointerCount == 0) {
          _swipeStartPosition = null;
          _firstPointerDownTime = null;
          _wasMultiTouch = false;
          _isSwipeGesture = false;
        }
      },
      onPointerMove: (event) {
        // Only check for vertical swipe-up (details panel) during single-finger gesture
        if (_pointerCount == 1 &&
            !_wasMultiTouch &&
            !isZoomed &&
            _swipeStartPosition != null) {

          final delta = event.position - _swipeStartPosition!;

          // Vertical swipe up - show details panel
          if (delta.dy < -80 && delta.dy.abs() > delta.dx.abs() * 2) {
            _isSwipeGesture = true;
            _showDetailsPanel();
            _swipeStartPosition = null;
          }
        }
      },
      // InteractiveViewer directly - no GestureDetector in between
      child: InteractiveViewer(
        transformationController: controller,
        minScale: 1.0,
        maxScale: 5.0,
        panEnabled: true,
        scaleEnabled: true,
        child: Center(
          child: _buildImageWidget(file, p.basename(_images[index])),
        ),
      ),
    );
  }

  Widget _buildImageWidget(File file, String fileName) {
    final extension = fileName.split('.').last.toLowerCase();

    if (extension == 'svg') {
      return SvgPicture.file(
        file,
        fit: BoxFit.contain,
        placeholderBuilder: (context) => const CircularProgressIndicator(color: Colors.white),
      );
    }

    return Image.file(
      file,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => const Icon(
        LucideIcons.imageOff,
        size: 64,
        color: Colors.white54,
      ),
    );
  }

  Widget _buildTopBar(String fileName) {
    return AnimatedBuilder(
      animation: _controlsAnimation,
      builder: (context, child) {
        return IgnorePointer(
          ignoring: !_showControls || _showDetails,
          child: Opacity(
            opacity: _showDetails ? 0.0 : _controlsAnimation.value,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.7),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(LucideIcons.arrowLeft, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              fileName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (_images.length > 1)
                              Text(
                                '${_currentIndex + 1} of ${_images.length}',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.7),
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(LucideIcons.edit, color: Colors.white),
                        onPressed: _openEditor,
                        tooltip: 'Edit',
                      ),
                      IconButton(
                        icon: const Icon(LucideIcons.share, color: Colors.white),
                        onPressed: () => Share.shareXFiles([XFile(_images[_currentIndex])]),
                        tooltip: 'Share',
                      ),
                      IconButton(
                        icon: const Icon(LucideIcons.info, color: Colors.white),
                        onPressed: _showDetailsPanel,
                        tooltip: 'Details',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomBar() {
    return AnimatedBuilder(
      animation: _controlsAnimation,
      builder: (context, child) {
        return IgnorePointer(
          ignoring: !_showControls || _showDetails,
          child: Opacity(
            opacity: _showDetails ? 0.0 : _controlsAnimation.value,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withOpacity(0.7),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16, top: 40),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildBottomButton(
                        icon: LucideIcons.rotateCcw,
                        label: 'Reset',
                        onTap: () {
                          final controller = _getTransformController(_currentIndex);
                          controller.value = Matrix4.identity();
                        },
                      ),
                      _buildBottomButton(
                        icon: LucideIcons.zoomIn,
                        label: 'Zoom in',
                        onTap: _zoomIn,
                      ),
                      _buildBottomButton(
                        icon: LucideIcons.zoomOut,
                        label: 'Zoom out',
                        onTap: _zoomOut,
                      ),
                      if (_facesLoaded && _faces.isNotEmpty)
                        _buildBottomButton(
                          icon: LucideIcons.scanFace,
                          label: '${_faces.length} faces',
                          onTap: _showDetailsPanel,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageIndicator() {
    final maxDots = 7;
    final showDots = _images.length <= maxDots;

    if (showDots) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(_images.length, (index) {
          final isActive = index == _currentIndex;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: isActive ? 8 : 6,
            height: isActive ? 8 : 6,
            decoration: BoxDecoration(
              color: isActive ? Colors.white : Colors.white.withOpacity(0.4),
              shape: BoxShape.circle,
            ),
          );
        }),
      );
    }

    // For many images, show a text indicator
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '${_currentIndex + 1} / ${_images.length}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildDetailsPanel() {
    return AnimatedBuilder(
      animation: _detailsAnimation,
      builder: (context, child) {
        if (_detailsAnimation.value == 0) {
          return const SizedBox.shrink();
        }

        final panelHeight = MediaQuery.of(context).size.height * 0.55;

        return Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Transform.translate(
            offset: Offset(0, panelHeight * (1 - _detailsAnimation.value)),
            child: GestureDetector(
              onVerticalDragEnd: (details) {
                if (details.velocity.pixelsPerSecond.dy > 300) {
                  _hideDetailsPanel();
                }
              },
              child: Container(
                height: panelHeight,
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 20,
                      offset: const Offset(0, -5),
                    ),
                  ],
                ),
                child: _buildDetailsContent(),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetailsContent() {
    if (_images.isEmpty) return const SizedBox.shrink();

    final currentPath = _images[_currentIndex];
    final fileName = p.basename(currentPath);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: GestureDetector(
              onTap: _hideDetailsPanel,
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white38 : Colors.black26,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),

          // File name
          Text(
            fileName,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),

          // File details
          _buildDetailRow(
            LucideIcons.fileType,
            'Type',
            p.extension(currentPath).toUpperCase().replaceFirst('.', '') + ' Image',
          ),
          if (_fileStat != null) ...[
            _buildDetailRow(
              LucideIcons.hardDrive,
              'Size',
              _formatSize(_fileStat!.size),
            ),
            _buildDetailRow(
              LucideIcons.calendar,
              'Modified',
              DateFormat('MMM d, yyyy • h:mm a').format(_fileStat!.modified),
            ),
          ],
          _buildDetailRow(
            LucideIcons.folderOpen,
            'Location',
            p.dirname(currentPath),
          ),

          const SizedBox(height: 20),
          Divider(color: isDark ? Colors.white24 : Colors.black12),
          const SizedBox(height: 16),

          // Faces section
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'People in this photo',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (!_isDetectingFaces)
                TextButton.icon(
                  onPressed: _detectFaces,
                  icon: const Icon(LucideIcons.scanFace, size: 16),
                  label: const Text('Detect'),
                ),
              if (_isDetectingFaces)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),

          if (_faces.isEmpty && _facesLoaded)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Icon(
                      LucideIcons.userX,
                      color: theme.colorScheme.onSurface.withOpacity(0.3),
                      size: 40,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'No faces detected',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.5),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tap "Detect" to scan for faces',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.4),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (_faces.isNotEmpty)
            SizedBox(
              height: 100,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _faces.length,
                itemBuilder: (context, index) => _buildFaceItem(_faces[index]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            icon,
            color: theme.colorScheme.onSurface.withOpacity(0.5),
            size: 18,
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showTagFaceDialog(DetectedFace face) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => _TagFaceDialog(face: face),
    );

    if (result == true) {
      // Refresh faces after tagging
      await _loadFaces();
    }
  }

  Widget _buildFaceItem(DetectedFace face) {
    final theme = Theme.of(context);

    return FutureBuilder<Person?>(
      future: face.personId != null
          ? FaceStorageService.instance.getPerson(face.personId!)
          : Future.value(null),
      builder: (context, snapshot) {
        final person = snapshot.data;
        final isUnknown = person == null;
        final thumbnailFile = face.thumbnailPath != null
            ? File(face.thumbnailPath!)
            : null;

        return GestureDetector(
          onTap: isUnknown ? () => _showTagFaceDialog(face) : null,
          child: Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Column(
              children: [
                Stack(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isUnknown
                              ? theme.colorScheme.outline
                              : theme.colorScheme.primary,
                          width: 2,
                        ),
                      ),
                      child: ClipOval(
                        child: thumbnailFile != null && thumbnailFile.existsSync()
                            ? Image.file(thumbnailFile, fit: BoxFit.cover)
                            : Container(
                                color: theme.colorScheme.surfaceContainerHighest,
                                child: Icon(
                                  LucideIcons.user,
                                  color: theme.colorScheme.onSurface.withOpacity(0.4),
                                  size: 28,
                                ),
                              ),
                      ),
                    ),
                    // Show "+" badge for unknown faces to hint tappability
                    if (isUnknown)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.colorScheme.surface,
                              width: 2,
                            ),
                          ),
                          child: Icon(
                            LucideIcons.plus,
                            size: 12,
                            color: theme.colorScheme.onPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: 70,
                  child: Text(
                    person?.name ?? 'Tap to tag',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: isUnknown
                          ? theme.colorScheme.primary
                          : theme.textTheme.bodySmall?.color,
                      fontWeight: isUnknown ? FontWeight.w500 : null,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _zoomIn() {
    final controller = _getTransformController(_currentIndex);
    final currentScale = controller.value.getMaxScaleOnAxis();
    if (currentScale < 5.0) {
      final newScale = (currentScale * 1.5).clamp(1.0, 5.0);
      controller.value = Matrix4.identity()..scale(newScale);
    }
  }

  void _zoomOut() {
    final controller = _getTransformController(_currentIndex);
    final currentScale = controller.value.getMaxScaleOnAxis();
    if (currentScale > 1.0) {
      final newScale = (currentScale / 1.5).clamp(1.0, 5.0);
      if (newScale <= 1.05) {
        controller.value = Matrix4.identity();
      } else {
        controller.value = Matrix4.identity()..scale(newScale);
      }
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Dialog for tagging an unknown face directly from the image viewer
class _TagFaceDialog extends StatefulWidget {
  final DetectedFace face;

  const _TagFaceDialog({required this.face});

  @override
  State<_TagFaceDialog> createState() => _TagFaceDialogState();
}

class _TagFaceDialogState extends State<_TagFaceDialog> {
  final _nameController = TextEditingController();
  List<Person> _allPersons = [];
  List<Person> _suggestions = [];
  Person? _selectedPerson;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadPersons();
    _nameController.addListener(_updateSuggestions);
  }

  @override
  void dispose() {
    _nameController.removeListener(_updateSuggestions);
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadPersons() async {
    final persons = await FaceStorageService.instance.getAllPersons();
    if (mounted) {
      setState(() => _allPersons = persons);
    }
  }

  void _updateSuggestions() {
    final query = _nameController.text.toLowerCase().trim();
    if (query.isEmpty) {
      setState(() {
        _suggestions = [];
        _selectedPerson = null;
      });
    } else {
      setState(() {
        _suggestions = _allPersons
            .where((p) => p.name.toLowerCase().contains(query))
            .take(5)
            .toList();
        // Clear selection if text changed
        if (_selectedPerson != null &&
            _selectedPerson!.name != _nameController.text) {
          _selectedPerson = null;
        }
      });
    }
  }

  void _selectPerson(Person person) {
    setState(() {
      _selectedPerson = person;
      _nameController.text = person.name;
      _suggestions = [];
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a name')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (_selectedPerson != null) {
        // Add to existing person (selected from autocomplete)
        await FaceStorageService.instance.assignFacesToPerson(
          [widget.face.id],
          _selectedPerson!.id,
        );
      } else {
        // Check if person with same name already exists
        final existing = _allPersons.firstWhere(
          (p) => p.name.toLowerCase() == name.toLowerCase(),
          orElse: () => Person(
            id: '',
            name: '',
            averageEmbedding: [],
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            faceCount: 0,
          ),
        );

        if (existing.id.isNotEmpty) {
          // Add to existing person with same name
          await FaceStorageService.instance.assignFacesToPerson(
            [widget.face.id],
            existing.id,
          );
        } else {
          // Create new person
          await FaceStorageService.instance.createNamedPerson(
            name,
            [widget.face.id],
          );
        }
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbnailFile = widget.face.thumbnailPath != null
        ? File(widget.face.thumbnailPath!)
        : null;

    return AlertDialog(
      title: const Text('Tag Face'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Face thumbnail preview
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.primary,
                  width: 2,
                ),
              ),
              child: ClipOval(
                child: thumbnailFile != null && thumbnailFile.existsSync()
                    ? Image.file(thumbnailFile, fit: BoxFit.cover)
                    : Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          LucideIcons.user,
                          color: theme.colorScheme.onSurface.withOpacity(0.4),
                          size: 36,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 16),

            // Name input field
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: _selectedPerson != null
                    ? 'Adding to existing person'
                    : 'Person Name',
                hintText: 'Enter name or select existing',
                filled: true,
                prefixIcon: _selectedPerson != null
                    ? const Icon(LucideIcons.userCheck, color: Colors.green)
                    : const Icon(LucideIcons.user),
                suffixIcon: _nameController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(LucideIcons.x, size: 18),
                        onPressed: () {
                          _nameController.clear();
                          setState(() {
                            _selectedPerson = null;
                            _suggestions = [];
                          });
                        },
                      )
                    : null,
              ),
              textCapitalization: TextCapitalization.words,
              autofocus: true,
              onSubmitted: (_) => _save(),
            ),

            // Autocomplete suggestions list
            if (_suggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: _suggestions.length,
                  itemBuilder: (context, index) {
                    final person = _suggestions[index];
                    final personThumbnail = person.thumbnailPath != null
                        ? File(person.thumbnailPath!)
                        : null;

                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 18,
                        backgroundImage: personThumbnail != null &&
                                personThumbnail.existsSync()
                            ? FileImage(personThumbnail)
                            : null,
                        child: personThumbnail == null ||
                                !personThumbnail.existsSync()
                            ? const Icon(LucideIcons.user, size: 18)
                            : null,
                      ),
                      title: Text(
                        person.name,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(
                        '${person.faceCount} face${person.faceCount != 1 ? 's' : ''}',
                        style: theme.textTheme.bodySmall,
                      ),
                      trailing: const Icon(LucideIcons.plus, size: 18),
                      onTap: () => _selectPerson(person),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _save,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
