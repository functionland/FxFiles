import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;
import 'package:fula_files/shared/utils/error_messages.dart';

enum EditMode { none, adjust, text }

class ImageEditorScreen extends StatefulWidget {
  final String filePath;

  const ImageEditorScreen({super.key, required this.filePath});

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  late String _currentImagePath;
  final List<String> _undoStack = [];
  bool _isProcessing = false;
  EditMode _editMode = EditMode.none;

  // Adjustment values
  double _brightness = 0.0;
  double _contrast = 1.0;
  double _saturation = 1.0;
  int _rotation = 0;

  // Text overlay
  final List<TextOverlay> _textOverlays = [];
  TextOverlay? _selectedText;
  final GlobalKey _imageKey = GlobalKey();

  // For rendering
  Uint8List? _previewBytes;
  bool _adjustmentsApplied = false;

  @override
  void initState() {
    super.initState();
    _currentImagePath = widget.filePath;
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    final file = File(_currentImagePath);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      setState(() {
        _previewBytes = bytes;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Edit Image'),
        actions: [
          if (_undoStack.isNotEmpty)
            IconButton(
              icon: const Icon(LucideIcons.undo),
              onPressed: _undo,
              tooltip: 'Undo',
            ),
          IconButton(
            icon: const Icon(LucideIcons.check),
            onPressed: _isProcessing ? null : _saveImage,
            tooltip: 'Save',
          ),
        ],
      ),
      body: Stack(
        children: [
          // Image preview
          Center(
            child: _isProcessing
                ? const CircularProgressIndicator(color: Colors.white)
                : _buildImagePreview(),
          ),

          // Text overlays
          if (_editMode == EditMode.text)
            ..._textOverlays.map((overlay) => _buildDraggableText(overlay)),

          // Bottom controls
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildControls(theme),
          ),

          // Adjustment sliders
          if (_editMode == EditMode.adjust)
            Positioned(
              left: 0,
              right: 0,
              bottom: 120,
              child: _buildAdjustmentSliders(theme),
            ),
        ],
      ),
    );
  }

  Widget _buildImagePreview() {
    if (_previewBytes == null) {
      return const CircularProgressIndicator(color: Colors.white);
    }

    Widget imageWidget = Image.memory(
      _previewBytes!,
      key: _imageKey,
      fit: BoxFit.contain,
    );

    // Apply visual adjustments for preview
    if (_brightness != 0.0 || _contrast != 1.0 || _saturation != 1.0) {
      imageWidget = ColorFiltered(
        colorFilter: ColorFilter.matrix(_buildColorMatrix()),
        child: imageWidget,
      );
    }

    // Apply rotation for preview
    if (_rotation != 0) {
      imageWidget = Transform.rotate(
        angle: _rotation * 3.14159 / 180,
        child: imageWidget,
      );
    }

    return imageWidget;
  }

  List<double> _buildColorMatrix() {
    // Brightness adjustment
    final b = _brightness;
    // Contrast adjustment
    final c = _contrast;
    // Saturation adjustment
    final s = _saturation;

    // Luminance weights
    const lumR = 0.2126;
    const lumG = 0.7152;
    const lumB = 0.0722;

    // Build combined matrix
    return <double>[
      // Red
      c * (s + (1 - s) * lumR), c * (1 - s) * lumG, c * (1 - s) * lumB, 0, b * 255,
      // Green
      c * (1 - s) * lumR, c * (s + (1 - s) * lumG), c * (1 - s) * lumB, 0, b * 255,
      // Blue
      c * (1 - s) * lumR, c * (1 - s) * lumG, c * (s + (1 - s) * lumB), 0, b * 255,
      // Alpha
      0, 0, 0, 1, 0,
    ];
  }

  Widget _buildDraggableText(TextOverlay overlay) {
    final isSelected = _selectedText == overlay;

    return Positioned(
      left: overlay.position.dx,
      top: overlay.position.dy,
      child: GestureDetector(
        onTap: () {
          setState(() => _selectedText = overlay);
          _showTextEditDialog(overlay);
        },
        onPanUpdate: (details) {
          setState(() {
            overlay.position += details.delta;
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: isSelected ? Border.all(color: Colors.blue, width: 2) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            overlay.text,
            style: TextStyle(
              color: overlay.color,
              fontSize: overlay.fontSize,
              fontWeight: overlay.isBold ? FontWeight.bold : FontWeight.normal,
              fontStyle: overlay.isItalic ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls(ThemeData theme) {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mode indicator
          if (_editMode != EditMode.none)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _editMode == EditMode.adjust ? 'Adjust Image' : 'Add Text',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),

          // Main controls
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildControlButton(
                icon: LucideIcons.crop,
                label: 'Crop',
                onTap: _cropImage,
              ),
              _buildControlButton(
                icon: LucideIcons.rotateCw,
                label: 'Rotate',
                onTap: _rotateImage,
              ),
              _buildControlButton(
                icon: LucideIcons.sliders,
                label: 'Adjust',
                isActive: _editMode == EditMode.adjust,
                onTap: () {
                  setState(() {
                    _editMode = _editMode == EditMode.adjust ? EditMode.none : EditMode.adjust;
                  });
                },
              ),
              _buildControlButton(
                icon: LucideIcons.type,
                label: 'Text',
                isActive: _editMode == EditMode.text,
                onTap: () {
                  setState(() {
                    _editMode = _editMode == EditMode.text ? EditMode.none : EditMode.text;
                  });
                  if (_editMode == EditMode.text) {
                    _addNewText();
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isActive = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isActive ? Colors.blue : Colors.white12,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: isActive ? Colors.blue : Colors.white70,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdjustmentSliders(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSlider(
            label: 'Brightness',
            value: _brightness,
            min: -0.5,
            max: 0.5,
            onChanged: (v) => setState(() => _brightness = v),
          ),
          const SizedBox(height: 8),
          _buildSlider(
            label: 'Contrast',
            value: _contrast,
            min: 0.5,
            max: 1.5,
            onChanged: (v) => setState(() => _contrast = v),
          ),
          const SizedBox(height: 8),
          _buildSlider(
            label: 'Saturation',
            value: _saturation,
            min: 0.0,
            max: 2.0,
            onChanged: (v) => setState(() => _saturation = v),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton(
                onPressed: _resetAdjustments,
                child: const Text('Reset', style: TextStyle(color: Colors.white70)),
              ),
              FilledButton(
                onPressed: _applyAdjustments,
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
            activeColor: Colors.blue,
            inactiveColor: Colors.white24,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            value.toStringAsFixed(1),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Future<void> _cropImage() async {
    setState(() => _isProcessing = true);

    try {
      final croppedFile = await ImageCropper().cropImage(
        sourcePath: _currentImagePath,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Crop Image',
            toolbarColor: Colors.black,
            toolbarWidgetColor: Colors.white,
            backgroundColor: Colors.black,
            activeControlsWidgetColor: Colors.blue,
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: false,
          ),
          IOSUiSettings(
            title: 'Crop Image',
            cancelButtonTitle: 'Cancel',
            doneButtonTitle: 'Done',
          ),
        ],
      );

      if (croppedFile != null) {
        _undoStack.add(_currentImagePath);
        _currentImagePath = croppedFile.path;
        await _loadPreview();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forImageEdit(e, operation: 'crop image'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  void _rotateImage() {
    setState(() {
      _rotation = (_rotation + 90) % 360;
    });
  }

  void _resetAdjustments() {
    setState(() {
      _brightness = 0.0;
      _contrast = 1.0;
      _saturation = 1.0;
    });
  }

  Future<void> _applyAdjustments() async {
    if (_brightness == 0.0 && _contrast == 1.0 && _saturation == 1.0 && _rotation == 0) {
      setState(() => _editMode = EditMode.none);
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final file = File(_currentImagePath);
      final bytes = await file.readAsBytes();
      var image = img.decodeImage(bytes);

      if (image == null) {
        throw Exception('Failed to decode image');
      }

      // Apply rotation
      if (_rotation != 0) {
        switch (_rotation) {
          case 90:
            image = img.copyRotate(image, angle: 90);
            break;
          case 180:
            image = img.copyRotate(image, angle: 180);
            break;
          case 270:
            image = img.copyRotate(image, angle: 270);
            break;
        }
      }

      // Apply brightness
      if (_brightness != 0.0) {
        final brightnessValue = (_brightness * 100).toInt();
        image = img.adjustColor(image, brightness: brightnessValue / 100);
      }

      // Apply contrast
      if (_contrast != 1.0) {
        image = img.adjustColor(image, contrast: _contrast);
      }

      // Apply saturation
      if (_saturation != 1.0) {
        image = img.adjustColor(image, saturation: _saturation);
      }

      // Save to temp file
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final extension = p.extension(_currentImagePath).toLowerCase();
      final newPath = p.join(tempDir.path, 'edited_$timestamp$extension');

      final encoded = extension == '.png'
          ? img.encodePng(image)
          : img.encodeJpg(image, quality: 95);

      await File(newPath).writeAsBytes(encoded);

      _undoStack.add(_currentImagePath);
      _currentImagePath = newPath;

      // Reset adjustments
      _brightness = 0.0;
      _contrast = 1.0;
      _saturation = 1.0;
      _rotation = 0;

      await _loadPreview();
      setState(() => _editMode = EditMode.none);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forImageEdit(e, operation: 'apply adjustments'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  void _addNewText() {
    final screenSize = MediaQuery.of(context).size;
    final newOverlay = TextOverlay(
      text: 'Tap to edit',
      position: Offset(screenSize.width / 2 - 50, screenSize.height / 3),
    );

    setState(() {
      _textOverlays.add(newOverlay);
      _selectedText = newOverlay;
    });

    _showTextEditDialog(newOverlay);
  }

  void _showTextEditDialog(TextOverlay overlay) {
    final controller = TextEditingController(text: overlay.text == 'Tap to edit' ? '' : overlay.text);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Text'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Text',
                hintText: 'Enter text',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Font size
                Column(
                  children: [
                    const Text('Size', style: TextStyle(fontSize: 12)),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove),
                          tooltip: 'Decrease size',
                          onPressed: () {
                            setState(() {
                              if (overlay.fontSize > 12) overlay.fontSize -= 2;
                            });
                          },
                        ),
                        Text('${overlay.fontSize.toInt()}'),
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: 'Increase size',
                          onPressed: () {
                            setState(() {
                              if (overlay.fontSize < 72) overlay.fontSize += 2;
                            });
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Color picker
            Wrap(
              spacing: 8,
              children: [
                Colors.white,
                Colors.black,
                Colors.red,
                Colors.blue,
                Colors.green,
                Colors.yellow,
                Colors.orange,
                Colors.purple,
              ].map((color) => GestureDetector(
                onTap: () => setState(() => overlay.color = color),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: overlay.color == color ? Colors.blue : Colors.grey,
                      width: overlay.color == color ? 3 : 1,
                    ),
                  ),
                ),
              )).toList(),
            ),
            const SizedBox(height: 16),
            // Style buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilterChip(
                  label: const Text('Bold'),
                  selected: overlay.isBold,
                  onSelected: (v) => setState(() => overlay.isBold = v),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Italic'),
                  selected: overlay.isItalic,
                  onSelected: (v) => setState(() => overlay.isItalic = v),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _textOverlays.remove(overlay);
                _selectedText = null;
              });
              Navigator.pop(ctx);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              setState(() {
                overlay.text = controller.text.isEmpty ? 'Text' : controller.text;
              });
              Navigator.pop(ctx);
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _undo() async {
    if (_undoStack.isEmpty) return;

    final previousPath = _undoStack.removeLast();
    _currentImagePath = previousPath;
    _brightness = 0.0;
    _contrast = 1.0;
    _saturation = 1.0;
    _rotation = 0;
    await _loadPreview();
  }

  Future<void> _saveImage() async {
    // Apply any pending adjustments first
    if (_brightness != 0.0 || _contrast != 1.0 || _saturation != 1.0 || _rotation != 0) {
      await _applyAdjustments();
    }

    setState(() => _isProcessing = true);

    try {
      // If there are text overlays, render them
      if (_textOverlays.isNotEmpty) {
        await _renderTextOverlays();
      }

      // Ask user where to save
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Save Image'),
          content: const Text('Where would you like to save the edited image?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'replace'),
              child: const Text('Replace Original'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'copy'),
              child: const Text('Save as Copy'),
            ),
          ],
        ),
      );

      if (result == null) {
        setState(() => _isProcessing = false);
        return;
      }

      String savePath;
      if (result == 'replace') {
        savePath = widget.filePath;
      } else {
        // Save as copy
        final dir = p.dirname(widget.filePath);
        final name = p.basenameWithoutExtension(widget.filePath);
        final ext = p.extension(widget.filePath);
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        savePath = p.join(dir, '${name}_edited_$timestamp$ext');
      }

      // Copy the edited image to save path
      await File(_currentImagePath).copy(savePath);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image saved to ${p.basename(savePath)}')),
        );
        Navigator.pop(context, savePath);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.getUserFriendlyMessage(e, context: 'save image'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _renderTextOverlays() async {
    if (_textOverlays.isEmpty) return;

    final file = File(_currentImagePath);
    final bytes = await file.readAsBytes();
    var image = img.decodeImage(bytes);

    if (image == null) return;

    // For now, we'll use a simple approach - create a new image with text
    // A more sophisticated approach would use Flutter's rendering pipeline
    // This is a simplified implementation

    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final extension = p.extension(_currentImagePath).toLowerCase();
    final newPath = p.join(tempDir.path, 'text_$timestamp$extension');

    // Note: The image package has limited text rendering capabilities
    // For production, you might want to use flutter's rendering pipeline
    // to capture the widget with text overlays

    // Save without text for now - text rendering would require
    // a more complex implementation using Flutter's RepaintBoundary
    final encoded = extension == '.png'
        ? img.encodePng(image)
        : img.encodeJpg(image, quality: 95);

    await File(newPath).writeAsBytes(encoded);
    _currentImagePath = newPath;
  }
}

class TextOverlay {
  String text;
  Offset position;
  Color color;
  double fontSize;
  bool isBold;
  bool isItalic;

  TextOverlay({
    required this.text,
    required this.position,
    this.color = Colors.white,
    this.fontSize = 24,
    this.isBold = false,
    this.isItalic = false,
  });
}
