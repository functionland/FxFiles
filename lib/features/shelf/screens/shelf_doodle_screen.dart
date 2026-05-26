import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/services/shelf_service.dart';
import 'package:fula_files/features/shelf/painters/shelf_doodle_painter.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/features/tags/widgets/tag_chip.dart';

/// Camera-capture annotation editor. Receives the path of a freshly
/// captured photo (from `image_picker`) and lets the user overlay
/// strokes (single pen, 6 colors, undo/redo). On Save composites the
/// drawing into a PNG and pushes it through the standard ingest
/// pipeline.
///
/// Hardening (per Shelf plan Session 3b):
///   - H2: EXIF orientation is baked into the working copy so the
///     captured composite matches the on-screen rendering.
///   - H3: A `FittedBox` + fixed-size canvas ensures pointer offsets
///     and painter coordinates share the same space — strokes land
///     exactly where the user drew them in the saved composite.
///   - H4: `toImage(pixelRatio: MediaQuery.devicePixelRatio)` keeps
///     captured fidelity on high-DPI screens.
///   - H5: Source images larger than 2048 px on the long edge are
///     pre-downscaled to bound memory + keep the saved PNG modest.
class ShelfDoodleScreen extends ConsumerStatefulWidget {
  /// File path of the captured photo (e.g. from `image_picker`).
  final String capturedPath;

  const ShelfDoodleScreen({super.key, required this.capturedPath});

  @override
  ConsumerState<ShelfDoodleScreen> createState() => _ShelfDoodleScreenState();
}

class _ShelfDoodleScreenState extends ConsumerState<ShelfDoodleScreen> {
  static const int _kMaxLongEdge = 2048;

  /// Path of the EXIF-baked + optionally downscaled working copy. Set
  /// after [_prepareWorkingImage] completes. Read by the on-screen
  /// `Image.file` AND used as the size source for the gesture overlay.
  String? _workingImagePath;
  int? _workingWidth;
  int? _workingHeight;

  String? _prepError;

  final GlobalKey _boundaryKey = GlobalKey();

  final List<Stroke> _strokes = <Stroke>[];
  final List<Stroke> _redoStack = <Stroke>[];
  List<Offset> _currentPoints = <Offset>[];

  // Tool state.
  Color _color = const Color(0xFFE53935); // red default
  double _width = 6;

  bool _saving = false;
  final Set<String> _selectedTagIds = <String>{};

  static const List<Color> _palette = <Color>[
    Color(0xFFE53935), // red
    Color(0xFFFDD835), // yellow
    Color(0xFF43A047), // green
    Color(0xFF1E88E5), // blue
    Color(0xFFFFFFFF), // white
    Color(0xFF000000), // black
  ];

  @override
  void initState() {
    super.initState();
    _prepareWorkingImage();
  }

  Future<void> _prepareWorkingImage() async {
    try {
      final source = File(widget.capturedPath);
      if (!await source.exists()) {
        setState(() => _prepError = 'Captured image file is missing.');
        return;
      }
      final bytes = await source.readAsBytes();
      img.Image? decoded;
      try {
        decoded = img.decodeImage(bytes);
      } catch (e) {
        debugPrint('ShelfDoodleScreen: decode failed: $e');
      }
      if (decoded == null) {
        setState(() => _prepError = 'Could not decode the captured image.');
        return;
      }
      // H2 — bake EXIF orientation into pixels.
      decoded = img.bakeOrientation(decoded);

      // H5 — pre-downscale to ≤2048 px on the long edge.
      final longEdge =
          decoded.width >= decoded.height ? decoded.width : decoded.height;
      if (longEdge > _kMaxLongEdge) {
        final scale = _kMaxLongEdge / longEdge;
        decoded = img.copyResize(
          decoded,
          width: (decoded.width * scale).round(),
          height: (decoded.height * scale).round(),
        );
      }

      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'dump_pending'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final workingFile = File(p.join(
        dir.path,
        'doodle-source-${const Uuid().v4()}.jpg',
      ));
      await workingFile.writeAsBytes(img.encodeJpg(decoded, quality: 92));

      if (!mounted) return;
      setState(() {
        _workingImagePath = workingFile.path;
        _workingWidth = decoded!.width;
        _workingHeight = decoded.height;
      });
    } catch (e, st) {
      debugPrint('ShelfDoodleScreen prep failed: $e\n$st');
      if (!mounted) return;
      setState(() => _prepError = 'Could not prepare the image: $e');
    }
  }

  void _onPanStart(DragStartDetails d) {
    _currentPoints = <Offset>[d.localPosition];
    setState(() {
      _strokes.add(Stroke(
        color: _color,
        width: _width,
        points: _currentPoints,
      ));
      _redoStack.clear();
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    _currentPoints.add(d.localPosition);
    // Replace the last stroke with a fresh instance so the painter's
    // `identical` shouldRepaint trips.
    setState(() {
      _strokes[_strokes.length - 1] = Stroke(
        color: _color,
        width: _width,
        points: List<Offset>.unmodifiable(_currentPoints),
      );
    });
  }

  void _onPanEnd(DragEndDetails _) {
    _currentPoints = <Offset>[];
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    setState(() {
      final last = _strokes.removeLast();
      _redoStack.add(last);
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    setState(() {
      final last = _redoStack.removeLast();
      _strokes.add(last);
    });
  }

  Future<Uint8List?> _captureComposite() async {
    final renderObject =
        _boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (renderObject == null) return null;
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    final image = await renderObject.toImage(pixelRatio: pixelRatio);
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  Future<void> _openTagPicker() async {
    final state = ref.read(tagProvider);
    final allTags = state.tags;
    if (allTags.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No tags yet — create one from the Tags screen first.'),
        ),
      );
      return;
    }
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _DoodleTagPickerSheet(
        allTags: allTags,
        initialSelected: _selectedTagIds,
      ),
    );
    if (result != null) {
      setState(() {
        _selectedTagIds
          ..clear()
          ..addAll(result);
      });
    }
  }

  Future<void> _save() async {
    if (_workingImagePath == null) return;
    setState(() => _saving = true);

    try {
      Uint8List? pngBytes;
      // H5 — toImage can OOM on giant composites; on failure we fall
      // back to saving the underlying working photo without strokes.
      try {
        pngBytes = await _captureComposite();
      } catch (e) {
        debugPrint('ShelfDoodleScreen: toImage failed: $e');
      }

      final docs = await getApplicationDocumentsDirectory();
      final stagingDir = Directory(p.join(docs.path, 'dump_pending'));
      if (!await stagingDir.exists()) {
        await stagingDir.create(recursive: true);
      }

      final id = const Uuid().v4();
      final ts = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now());
      String filePath;
      String mime;
      String originalName;
      if (pngBytes != null && pngBytes.isNotEmpty) {
        filePath = p.join(stagingDir.path, '$id-photo.png');
        await File(filePath).writeAsBytes(pngBytes, flush: true);
        mime = 'image/png';
        originalName = 'Photo $ts.png';
      } else {
        // Degraded path — save the underlying working JPEG without
        // strokes baked in.
        final sourceBytes = await File(_workingImagePath!).readAsBytes();
        filePath = p.join(stagingDir.path, '$id-photo.jpg');
        await File(filePath).writeAsBytes(sourceBytes, flush: true);
        mime = 'image/jpeg';
        originalName = 'Photo $ts.jpg';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "Couldn't save annotations — original photo saved.",
              ),
            ),
          );
        }
      }

      final created = await ShelfService.instance.ingestAndSchedule(
        cachedPaths: [filePath],
        mimeTypes: [mime],
        originalNames: [originalName],
        sourcePackage: 'fxfiles-add-photo',
      );

      if (created.isNotEmpty && _selectedTagIds.isNotEmpty) {
        final item = created.first;
        final syntheticUri = 'dump://${item.id}';
        for (final tagId in _selectedTagIds) {
          await ref.tagFile(
            tagId: tagId,
            localPath: syntheticUri,
            fileName: originalName,
          );
        }
      }

      // Best-effort cleanup of the original camera capture.
      try {
        final captured = File(widget.capturedPath);
        if (await captured.exists()) await captured.delete();
      } catch (_) {}

      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/shelf');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save photo: $e')),
      );
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tagState = ref.watch(tagProvider);
    final selectedTags = tagState.tags
        .where((t) => _selectedTagIds.contains(t.id))
        .toList(growable: false);

    if (_prepError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Annotate')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_prepError!, style: theme.textTheme.bodyMedium),
          ),
        ),
      );
    }
    if (_workingImagePath == null ||
        _workingWidth == null ||
        _workingHeight == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Annotate')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Annotate'),
        leading: IconButton(
          icon: const Icon(LucideIcons.x),
          onPressed: _saving ? null : () => context.pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.undo2),
            tooltip: 'Undo',
            onPressed: _strokes.isEmpty || _saving ? null : _undo,
          ),
          IconButton(
            icon: const Icon(LucideIcons.redo2),
            tooltip: 'Redo',
            onPressed: _redoStack.isEmpty || _saving ? null : _redo,
          ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildCanvas()),
          _Toolbar(
            palette: _palette,
            currentColor: _color,
            width: _width,
            onColor: (c) => setState(() => _color = c),
            onWidth: (w) => setState(() => _width = w),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: _TagRow(
              tags: selectedTags,
              onAdd: _openTagPicker,
              onClear: _selectedTagIds.isEmpty
                  ? null
                  : () => setState(_selectedTagIds.clear),
            ),
          ),
        ],
      ),
    );
  }

  /// H3: the photo + gesture overlay live inside a fixed-aspect
  /// `SizedBox` wrapped in `FittedBox(BoxFit.contain)`. The FittedBox
  /// scales the whole subtree uniformly to fit the available space, so
  /// pointer offsets reported by the GestureDetector are already in
  /// image-coordinate space, and the painter renders strokes in the
  /// same space as the underlying image. The `RepaintBoundary` capture
  /// then composites them aligned to the image bytes.
  Widget _buildCanvas() {
    final w = _workingWidth!.toDouble();
    final h = _workingHeight!.toDouble();
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: w,
          height: h,
          child: RepaintBoundary(
            key: _boundaryKey,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.file(File(_workingImagePath!), fit: BoxFit.fill),
                GestureDetector(
                  onPanStart: _onPanStart,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
                  child: CustomPaint(
                    painter: ShelfDoodlePainter(
                      strokes: List<Stroke>.unmodifiable(_strokes),
                    ),
                    size: Size(w, h),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final List<Color> palette;
  final Color currentColor;
  final double width;
  final ValueChanged<Color> onColor;
  final ValueChanged<double> onWidth;

  const _Toolbar({
    required this.palette,
    required this.currentColor,
    required this.width,
    required this.onColor,
    required this.onWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (final c in palette) ...[
                _ColorDot(
                  color: c,
                  selected: c == currentColor,
                  onTap: () => onColor(c),
                ),
                if (c != palette.last) const SizedBox(width: 8),
              ],
            ],
          ),
          Slider(
            min: 2,
            max: 16,
            value: width,
            label: '${width.round()} px',
            divisions: 14,
            onChanged: onWidth,
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Pen color',
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.black26,
              width: selected ? 3 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _TagRow extends StatelessWidget {
  final List<FileTag> tags;
  final VoidCallback onAdd;
  final VoidCallback? onClear;

  const _TagRow({
    required this.tags,
    required this.onAdd,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ActionChip(
          avatar: const Icon(LucideIcons.plus, size: 16),
          label: Text(tags.isEmpty ? 'Add tags' : 'Edit tags'),
          onPressed: onAdd,
        ),
        for (final t in tags) TagChip(tag: t),
        if (onClear != null)
          TextButton(
            onPressed: onClear,
            child: const Text('Clear'),
          ),
      ],
    );
  }
}

class _DoodleTagPickerSheet extends StatefulWidget {
  final List<FileTag> allTags;
  final Set<String> initialSelected;

  const _DoodleTagPickerSheet({
    required this.allTags,
    required this.initialSelected,
  });

  @override
  State<_DoodleTagPickerSheet> createState() => _DoodleTagPickerSheetState();
}

class _DoodleTagPickerSheetState extends State<_DoodleTagPickerSheet> {
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.initialSelected);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Select tags',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in widget.allTags)
                  TagChip(
                    tag: t,
                    selected: _selected.contains(t.id),
                    onTap: () => setState(() {
                      if (!_selected.add(t.id)) _selected.remove(t.id);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_selected),
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
