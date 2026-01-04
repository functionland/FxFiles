import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Sorting mode for determining section headers
enum ThumbScrollSortMode {
  /// Sort by name - headers are first letters (A, B, C...)
  name,
  /// Sort by date - headers are month-year (Jan 2024, Feb 2024...)
  date,
}

/// Data model for items in the thumbscroll list
class ThumbScrollItem {
  final String name;
  final DateTime date;

  const ThumbScrollItem({
    required this.name,
    required this.date,
  });
}

/// A high-performance thumbscroll widget with section headers
/// Similar to Google Files app's fast scroller
class ThumbScroll extends StatefulWidget {
  /// The scrollable child widget
  final Widget child;

  /// The scroll controller attached to the child
  final ScrollController controller;

  /// List of items for computing section headers
  final List<ThumbScrollItem> items;

  /// Current sort mode determines header format
  final ThumbScrollSortMode sortMode;

  /// Whether sorting is ascending
  final bool ascending;

  /// Whether thumbscroll is enabled
  final bool enabled;

  /// Background color of the thumb indicator
  final Color? thumbColor;

  /// Text color of the section header
  final Color? headerTextColor;

  /// How long to wait before hiding the scroller after scroll stops
  final Duration hideDelay;

  const ThumbScroll({
    super.key,
    required this.child,
    required this.controller,
    required this.items,
    this.sortMode = ThumbScrollSortMode.date,
    this.ascending = false,
    this.enabled = true,
    this.thumbColor,
    this.headerTextColor,
    this.hideDelay = const Duration(milliseconds: 1500),
  });

  @override
  State<ThumbScroll> createState() => _ThumbScrollState();
}

class _ThumbScrollState extends State<ThumbScroll>
    with SingleTickerProviderStateMixin {
  // Visibility state
  bool _isVisible = false;
  bool _isDragging = false;
  Timer? _hideTimer;

  // Animation
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  // Cached section data for performance
  List<_SectionInfo> _sections = [];
  Map<int, int> _itemToSectionIndex = {};

  // Current scroll position
  double _scrollPosition = 0;
  double _maxScrollExtent = 0;

  // Thumb position
  double _thumbPosition = 0;

  // Current section being displayed
  String _currentSection = '';

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );

    widget.controller.addListener(_onScroll);

    // Build initial sections
    _buildSections();
  }

  @override
  void didUpdateWidget(ThumbScroll oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Rebuild sections if items or sort mode changed
    if (oldWidget.items != widget.items ||
        oldWidget.sortMode != widget.sortMode ||
        oldWidget.ascending != widget.ascending) {
      _buildSections();
    }

    // Update controller listener if changed
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_onScroll);
    _animationController.dispose();
    super.dispose();
  }

  /// Build section data from items for quick lookup
  void _buildSections() {
    if (widget.items.isEmpty) {
      _sections = [];
      _itemToSectionIndex = {};
      return;
    }

    final sections = <_SectionInfo>[];
    final itemToSection = <int, int>{};
    String? lastHeader;

    for (int i = 0; i < widget.items.length; i++) {
      final header = _getHeaderForItem(widget.items[i]);

      if (header != lastHeader) {
        sections.add(_SectionInfo(
          header: header,
          startIndex: i,
        ));
        lastHeader = header;
      }

      itemToSection[i] = sections.length - 1;
    }

    // Calculate end indices
    for (int i = 0; i < sections.length; i++) {
      final endIndex = i < sections.length - 1
          ? sections[i + 1].startIndex - 1
          : widget.items.length - 1;
      sections[i] = sections[i].copyWith(endIndex: endIndex);
    }

    setState(() {
      _sections = sections;
      _itemToSectionIndex = itemToSection;
    });
  }

  /// Get section header for an item based on sort mode
  String _getHeaderForItem(ThumbScrollItem item) {
    switch (widget.sortMode) {
      case ThumbScrollSortMode.name:
        final firstChar = item.name.isNotEmpty
            ? item.name[0].toUpperCase()
            : '#';
        // Group non-alphabetic characters under '#'
        if (RegExp(r'[A-Z]').hasMatch(firstChar)) {
          return firstChar;
        }
        return '#';

      case ThumbScrollSortMode.date:
        return DateFormat('MMM yyyy').format(item.date);
    }
  }

  /// Handle scroll events
  void _onScroll() {
    if (!widget.enabled || !widget.controller.hasClients) return;

    final position = widget.controller.position;
    _scrollPosition = position.pixels;
    _maxScrollExtent = position.maxScrollExtent;

    if (_maxScrollExtent <= 0) return;

    // Calculate thumb position
    final scrollFraction = (_scrollPosition / _maxScrollExtent).clamp(0.0, 1.0);

    // Update current section based on visible items
    _updateCurrentSection();

    setState(() {
      _thumbPosition = scrollFraction;
    });

    // Show the thumb
    _showThumb();

    // Schedule hide if not dragging
    if (!_isDragging) {
      _scheduleHide();
    }
  }

  /// Update the current section header based on scroll position
  void _updateCurrentSection() {
    if (_sections.isEmpty || widget.items.isEmpty) {
      _currentSection = '';
      return;
    }

    // Estimate which item is at the current scroll position
    final itemCount = widget.items.length;
    if (itemCount == 0 || _maxScrollExtent <= 0) return;

    // Calculate approximate item index based on scroll position
    final scrollFraction = (_scrollPosition / _maxScrollExtent).clamp(0.0, 1.0);
    final estimatedIndex = (scrollFraction * (itemCount - 1)).round();
    final clampedIndex = estimatedIndex.clamp(0, itemCount - 1);

    // Get section for this index
    final sectionIndex = _itemToSectionIndex[clampedIndex];
    if (sectionIndex != null && sectionIndex < _sections.length) {
      final newSection = _sections[sectionIndex].header;
      if (_currentSection != newSection) {
        setState(() {
          _currentSection = newSection;
        });
      }
    }
  }

  /// Show the thumb with animation
  void _showThumb() {
    if (!_isVisible) {
      setState(() => _isVisible = true);
      _animationController.forward();
    }
  }

  /// Schedule hiding the thumb after delay
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(widget.hideDelay, () {
      if (!_isDragging && mounted) {
        _animationController.reverse().then((_) {
          if (mounted) {
            setState(() => _isVisible = false);
          }
        });
      }
    });
  }

  /// Handle drag on the thumb
  void _onVerticalDragStart(DragStartDetails details) {
    _hideTimer?.cancel();
    setState(() => _isDragging = true);
    _showThumb();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!widget.controller.hasClients) return;

    final renderBox = context.findRenderObject() as RenderBox;
    final height = renderBox.size.height;
    final thumbTrackHeight = height - _kThumbHeight - _kTrackPadding * 2;

    if (thumbTrackHeight <= 0) return;

    // Calculate new position
    final localY = details.localPosition.dy - _kTrackPadding - _kThumbHeight / 2;
    final fraction = (localY / thumbTrackHeight).clamp(0.0, 1.0);

    // Update scroll position
    final newScrollPosition = fraction * _maxScrollExtent;
    widget.controller.jumpTo(newScrollPosition.clamp(0.0, _maxScrollExtent));
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    setState(() => _isDragging = false);
    _scheduleHide();
  }

  /// Handle tap on the track to jump to position
  void _onTrackTap(TapUpDetails details) {
    if (!widget.controller.hasClients) return;

    final renderBox = context.findRenderObject() as RenderBox;
    final height = renderBox.size.height;
    final thumbTrackHeight = height - _kThumbHeight - _kTrackPadding * 2;

    if (thumbTrackHeight <= 0) return;

    final localY = details.localPosition.dy - _kTrackPadding - _kThumbHeight / 2;
    final fraction = (localY / thumbTrackHeight).clamp(0.0, 1.0);

    final newScrollPosition = fraction * _maxScrollExtent;
    widget.controller.animateTo(
      newScrollPosition.clamp(0.0, _maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );

    _showThumb();
    _scheduleHide();
  }

  // Constants
  static const double _kThumbWidth = 56.0;
  static const double _kThumbHeight = 52.0;
  static const double _kTrackWidth = 32.0;
  static const double _kTrackPadding = 8.0;
  static const double _kHeaderBubbleWidth = 72.0;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.items.isEmpty) {
      return widget.child;
    }

    final theme = Theme.of(context);
    final thumbColor = widget.thumbColor ?? theme.colorScheme.primary;
    final headerTextColor = widget.headerTextColor ?? theme.colorScheme.onPrimary;

    return Stack(
      children: [
        // Main scrollable content
        widget.child,

        // Thumb scroll track and indicator
        if (_isVisible || _isDragging)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: GestureDetector(
                onTapUp: _onTrackTap,
                onVerticalDragStart: _onVerticalDragStart,
                onVerticalDragUpdate: _onVerticalDragUpdate,
                onVerticalDragEnd: _onVerticalDragEnd,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: _kTrackWidth + _kHeaderBubbleWidth,
                  padding: const EdgeInsets.symmetric(vertical: _kTrackPadding),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final trackHeight = constraints.maxHeight - _kThumbHeight;
                      final thumbTop = trackHeight * _thumbPosition;

                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // Track background
                          Positioned(
                            right: 0,
                            top: 0,
                            bottom: 0,
                            width: _kTrackWidth,
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest
                                    .withOpacity(0.3),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),

                          // Section header bubble (shows when dragging)
                          if (_isDragging && _currentSection.isNotEmpty)
                            Positioned(
                              right: _kTrackWidth,
                              top: thumbTop,
                              child: Container(
                                height: _kThumbHeight,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: thumbColor.withOpacity(0.95),
                                  borderRadius: const BorderRadius.horizontal(
                                    left: Radius.circular(24),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black26,
                                      blurRadius: 8,
                                      offset: const Offset(-2, 2),
                                    ),
                                  ],
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  _currentSection,
                                  style: TextStyle(
                                    color: headerTextColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),

                          // Thumb indicator
                          Positioned(
                            right: 4,
                            top: thumbTop,
                            child: Container(
                              width: _kTrackWidth - 8,
                              height: _kThumbHeight,
                              decoration: BoxDecoration(
                                color: _isDragging
                                    ? thumbColor
                                    : thumbColor.withOpacity(0.8),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                  if (_isDragging)
                                    BoxShadow(
                                      color: thumbColor.withOpacity(0.3),
                                      blurRadius: 8,
                                      spreadRadius: 2,
                                    ),
                                ],
                              ),
                              child: Icon(
                                Icons.drag_handle,
                                color: headerTextColor.withOpacity(0.9),
                                size: 18,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Internal section info for quick lookup
class _SectionInfo {
  final String header;
  final int startIndex;
  final int endIndex;

  _SectionInfo({
    required this.header,
    required this.startIndex,
    this.endIndex = 0,
  });

  _SectionInfo copyWith({int? endIndex}) {
    return _SectionInfo(
      header: header,
      startIndex: startIndex,
      endIndex: endIndex ?? this.endIndex,
    );
  }
}
