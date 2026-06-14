import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/web/services/web_text_viewer_logic.dart';

/// Full-screen inline text/code viewer for the web app (#19), mirroring the
/// native `lib/features/viewer/screens/text_viewer_screen.dart`: line
/// numbers, a dark editor theme for code, font sizing, wrap toggle, search
/// (highlight + counter + next/prev), copy-all, download, JSON pretty-print.
///
/// Shown inside a `Dialog.fullscreen` from the bucket screen (consistent
/// with the app's other dialog-based previews), so it owns a [Scaffold] for
/// the app bar and a leading close button that pops the dialog. The bytes
/// are already downloaded + decrypted by the caller (which also records the
/// open in the Recent strip), so this widget is pure presentation.
///
/// Pure logic (extension/classification/JSON/search) lives in
/// `web_text_viewer_logic.dart` (VM-unit-tested); this half is browser-only
/// (clipboard, blob download).
class WebTextViewer extends StatefulWidget {
  final String fileName;
  final Uint8List bytes;

  /// Save the file. Passed as a callback (rather than importing web_save)
  /// so this widget has no browser-only imports and is VM widget-testable;
  /// the bucket screen wires it to `saveBytesAsDownload`.
  final VoidCallback onDownload;
  const WebTextViewer({
    super.key,
    required this.fileName,
    required this.bytes,
    required this.onDownload,
  });

  @override
  State<WebTextViewer> createState() => _WebTextViewerState();
}

class _WebTextViewerState extends State<WebTextViewer> {
  late final String _ext;
  late final bool _isCode;
  late final List<String> _lines;
  late final int _maxLineLen; // memoized once → no O(n) width scan per build
  late final int _byteSize;

  double _fontSize = kTextViewerDefaultFontSize;
  bool _wrap = true;
  bool _showLineNumbers = true;

  bool _showSearch = false;
  final TextEditingController _searchController = TextEditingController();
  // Separate vertical controllers per mode: wrap and no-wrap build different
  // ListViews, and sharing one controller across them risks a "used in
  // multiple positions" assertion on toggle (advisor: Codex).
  final ScrollController _wrapCtrl = ScrollController();
  final ScrollController _noWrapCtrl = ScrollController();
  ScrollController get _vCtrl => _wrap ? _wrapCtrl : _noWrapCtrl;
  List<int> _matches = const [];
  Set<int> _matchSet = const {}; // O(1) per-line highlight lookup
  int _matchIdx = -1;
  String _query = '';

  double get _itemHeight => _fontSize * 1.6;
  int get _totalLines => _lines.length;

  @override
  void initState() {
    super.initState();
    _byteSize = widget.bytes.length;
    _ext = fileExtension(widget.fileName);
    _isCode = isCodeName(widget.fileName);
    var content = decodeTextLenient(widget.bytes);
    content = prettyPrintJsonIfApplicable(content, _ext, byteSize: _byteSize);
    _lines = splitLines(content);
    _maxLineLen = maxLineDisplayWidth(_lines);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _wrapCtrl.dispose();
    _noWrapCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- search

  void _performSearch(String query) {
    final matches = findMatchingLineIndices(_lines, query);
    setState(() {
      _matches = matches;
      _matchSet = matches.toSet();
      _query = query;
      _matchIdx = matches.isNotEmpty ? 0 : -1;
    });
    if (matches.isNotEmpty) _scrollToLine(matches.first);
  }

  void _nextMatch() {
    if (_matches.isEmpty) return;
    setState(() => _matchIdx = (_matchIdx + 1) % _matches.length);
    _scrollToLine(_matches[_matchIdx]);
  }

  void _prevMatch() {
    if (_matches.isEmpty) return;
    setState(() => _matchIdx = (_matchIdx - 1 + _matches.length) % _matches.length);
    _scrollToLine(_matches[_matchIdx]);
  }

  void _closeSearch() {
    setState(() {
      _showSearch = false;
      _searchController.clear();
      _matches = const [];
      _matchSet = const {};
      _matchIdx = -1;
      _query = '';
    });
  }

  /// Scroll the given line into view. Exact in no-wrap mode (fixed item
  /// height); approximate in wrap mode (variable heights → proportional),
  /// same trade-off as native.
  void _scrollToLine(int lineIndex) {
    // Defer to after layout so maxScrollExtent reflects the rebuild the
    // triggering setState scheduled, not the previous frame (advisor: Codex).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _vCtrl;
      if (!c.hasClients) return;
      final maxScroll = c.position.maxScrollExtent;
      final target = _wrap
          ? (_totalLines == 0 ? 0.0 : (lineIndex / _totalLines) * maxScroll)
          : lineIndex * _itemHeight;
      c.animateTo(
        target.clamp(0.0, maxScroll),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    });
  }

  void _copyAll() {
    Clipboard.setData(ClipboardData(text: _lines.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.fileName,
                style: const TextStyle(fontSize: 16),
                overflow: TextOverflow.ellipsis),
            Text(
              '$_totalLines lines • ${_formatSize(_byteSize)}',
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_showSearch ? LucideIcons.x : LucideIcons.search),
            tooltip: _showSearch ? 'Close search' : 'Search',
            onPressed: () {
              if (_showSearch) {
                _closeSearch();
              } else {
                setState(() => _showSearch = true);
              }
            },
          ),
          IconButton(
            icon: const Icon(LucideIcons.copy),
            tooltip: 'Copy all',
            onPressed: _lines.isEmpty ? null : _copyAll,
          ),
          IconButton(
            icon: const Icon(LucideIcons.download),
            tooltip: 'Download',
            onPressed: widget.onDownload,
          ),
          PopupMenuButton<String>(
            icon: const Icon(LucideIcons.settings2),
            onSelected: (value) {
              switch (value) {
                case 'larger':
                  setState(() => _fontSize = (_fontSize + kTextViewerFontStep)
                      .clamp(kTextViewerMinFontSize, kTextViewerMaxFontSize));
                  break;
                case 'smaller':
                  setState(() => _fontSize = (_fontSize - kTextViewerFontStep)
                      .clamp(kTextViewerMinFontSize, kTextViewerMaxFontSize));
                  break;
                case 'wrap':
                  setState(() => _wrap = !_wrap);
                  break;
                case 'lines':
                  setState(() => _showLineNumbers = !_showLineNumbers);
                  break;
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'larger', child: Text('Larger text')),
              const PopupMenuItem(value: 'smaller', child: Text('Smaller text')),
              PopupMenuItem(
                value: 'wrap',
                child: Row(children: [
                  Icon(_wrap ? LucideIcons.check : null, size: 16),
                  const SizedBox(width: 8),
                  const Text('Wrap text'),
                ]),
              ),
              PopupMenuItem(
                value: 'lines',
                child: Row(children: [
                  Icon(_showLineNumbers ? LucideIcons.check : null, size: 16),
                  const SizedBox(width: 8),
                  const Text('Line numbers'),
                ]),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_showSearch) _buildSearchBar(),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border:
            Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search in file...',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
                prefixIcon: const Icon(LucideIcons.search, size: 18),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(LucideIcons.x, size: 18),
                        tooltip: 'Clear search',
                        onPressed: () {
                          _searchController.clear();
                          _performSearch('');
                        },
                      )
                    : null,
              ),
              onChanged: _performSearch,
            ),
          ),
          const SizedBox(width: 8),
          if (_matches.isNotEmpty)
            _chip(
              '${_matchIdx + 1}/${_matches.length}',
              Theme.of(context).colorScheme.primaryContainer,
              Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          if (_query.isNotEmpty && _matches.isEmpty)
            _chip(
              'No matches',
              Theme.of(context).colorScheme.errorContainer,
              Theme.of(context).colorScheme.onErrorContainer,
            ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(LucideIcons.chevronUp, size: 20),
            tooltip: 'Previous match',
            visualDensity: VisualDensity.compact,
            onPressed: _matches.isNotEmpty ? _prevMatch : null,
          ),
          IconButton(
            icon: const Icon(LucideIcons.chevronDown, size: 20),
            tooltip: 'Next match',
            visualDensity: VisualDensity.compact,
            onPressed: _matches.isNotEmpty ? _nextMatch : null,
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: TextStyle(fontSize: 12, color: fg)),
      );

  Widget _buildContent() {
    final bgColor = _isCode ? const Color(0xFF1E1E1E) : null;
    final textColor = _isCode ? Colors.white : null;
    final lineNumberWidth =
        _showLineNumbers ? (_totalLines.toString().length * 10.0 + 24) : 0.0;

    // SelectionArea makes the plain (non-Selectable) per-line Text widgets
    // selectable without the per-widget cost of SelectableText in a lazy
    // list (advisor: Gemini).
    return SelectionArea(
      child: Container(
        color: bgColor,
        child: _wrap
            ? _buildWrapped(textColor, lineNumberWidth)
            : _buildNoWrap(textColor, lineNumberWidth),
      ),
    );
  }

  Color? _lineHighlight(int index) {
    final isCurrent = _matchIdx >= 0 &&
        _matches.isNotEmpty &&
        _matches[_matchIdx] == index;
    if (isCurrent) return Colors.yellow.withValues(alpha: 0.3);
    if (_matchSet.contains(index)) return Colors.yellow.withValues(alpha: 0.15);
    return null;
  }

  Widget _buildWrapped(Color? textColor, double lineNumberWidth) {
    return ListView.builder(
      controller: _wrapCtrl,
      itemCount: _lines.length,
      itemBuilder: (context, index) => Container(
        color: _lineHighlight(index),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_showLineNumbers)
              SizedBox(
                width: lineNumberWidth,
                child: Text('${index + 1}',
                    style: TextStyle(
                        fontSize: _fontSize,
                        fontFamily: 'monospace',
                        color: Colors.grey,
                        height: 1.4)),
              ),
            Expanded(child: _highlightedLine(index, textColor, softWrap: true)),
          ],
        ),
      ),
    );
  }

  Widget _buildNoWrap(Color? textColor, double lineNumberWidth) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        // Over-estimate (0.7 char-width + generous pad) so wide glyphs / font
        // fallback under-measure into harmless scroll slack rather than
        // clipping the line tail (advisor: Codex). _maxLineLen is tab-aware.
        width: _maxLineLen * (_fontSize * 0.7) + lineNumberWidth + 96,
        child: ListView.builder(
          controller: _noWrapCtrl,
          itemCount: _lines.length,
          itemExtent: _itemHeight, // fixed → precise scroll-to-line
          itemBuilder: (context, index) => Container(
            height: _itemHeight,
            color: _lineHighlight(index),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                if (_showLineNumbers)
                  SizedBox(
                    width: lineNumberWidth,
                    child: Text('${index + 1}',
                        style: TextStyle(
                            fontSize: _fontSize,
                            fontFamily: 'monospace',
                            color: Colors.grey)),
                  ),
                _highlightedLine(index, textColor, softWrap: false),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One line, with case-insensitive search matches highlighted yellow.
  Widget _highlightedLine(int index, Color? textColor, {required bool softWrap}) {
    final text = _lines[index].isEmpty ? ' ' : _lines[index];
    final baseStyle = TextStyle(
      fontSize: _fontSize,
      fontFamily: _isCode ? 'monospace' : null,
      color: textColor,
      height: 1.4,
    );
    if (_query.isEmpty) {
      return Text(text, style: baseStyle, softWrap: softWrap);
    }
    final spans = <TextSpan>[];
    final lower = text.toLowerCase();
    final q = _query.toLowerCase();
    var start = 0;
    while (true) {
      final at = lower.indexOf(q, start);
      if (at == -1) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (at > start) spans.add(TextSpan(text: text.substring(start, at)));
      spans.add(TextSpan(
        text: text.substring(at, at + _query.length),
        style: const TextStyle(
            backgroundColor: Colors.yellow, color: Colors.black),
      ));
      start = at + _query.length;
    }
    return Text.rich(TextSpan(children: spans, style: baseStyle),
        softWrap: softWrap);
  }
}
