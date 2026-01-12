import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/models/recent_file.dart';
import 'package:fula_files/shared/utils/error_messages.dart';

class TextViewerScreen extends StatefulWidget {
  final String filePath;

  const TextViewerScreen({super.key, required this.filePath});

  @override
  State<TextViewerScreen> createState() => _TextViewerScreenState();
}

class _TextViewerScreenState extends State<TextViewerScreen> {
  // Content state
  List<String> _lines = [];
  String? _error;
  bool _isLoading = true;
  int _totalLines = 0;
  int _fileSize = 0;

  // View settings
  double _fontSize = 14;
  bool _wrapText = true;
  bool _showLineNumbers = true;

  // Search state
  bool _showSearch = false;
  final TextEditingController _searchController = TextEditingController();
  List<int> _searchMatches = []; // Line indices with matches
  int _currentMatchIndex = -1;
  String _searchQuery = '';

  // Scroll controller for goto line and search navigation
  final ScrollController _scrollController = ScrollController();
  final ItemScrollController _itemScrollController = ItemScrollController();

  // Large file threshold (1MB)
  static const int _largeFileThreshold = 1024 * 1024;

  // Fixed line height for precise scrolling (fontSize * lineHeight factor)
  double get _itemHeight => _fontSize * 1.6;

  @override
  void initState() {
    super.initState();
    _loadFile();
    _trackRecentFile();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _trackRecentFile() async {
    final file = File(widget.filePath);
    if (await file.exists()) {
      final stat = await file.stat();
      await LocalStorageService.instance.addRecentFile(RecentFile(
        path: widget.filePath,
        name: widget.filePath.split(Platform.pathSeparator).last,
        mimeType: 'text/plain',
        size: stat.size,
        accessedAt: DateTime.now(),
      ));
    }
  }

  Future<void> _loadFile() async {
    try {
      final file = File(widget.filePath);
      final stat = await file.stat();
      _fileSize = stat.size;

      final ext = widget.filePath.split('.').last.toLowerCase();

      // For large files, load in chunks using stream
      if (_fileSize > _largeFileThreshold) {
        await _loadLargeFile(file, ext);
      } else {
        await _loadSmallFile(file, ext);
      }
    } catch (e) {
      setState(() {
        _error = ErrorMessages.getUserFriendlyMessage(e, context: 'read file');
        _isLoading = false;
      });
    }
  }

  Future<void> _loadSmallFile(File file, String ext) async {
    var content = await file.readAsString();

    // Pretty-print JSON files
    if (ext == 'json') {
      try {
        final decoded = jsonDecode(content);
        content = const JsonEncoder.withIndent('  ').convert(decoded);
      } catch (_) {
        // Not valid JSON, show as-is
      }
    }

    setState(() {
      _lines = content.split('\n');
      _totalLines = _lines.length;
      _isLoading = false;
    });
  }

  Future<void> _loadLargeFile(File file, String ext) async {
    // Show loading progress for large files
    final lines = <String>[];
    final stream = file.openRead();
    final buffer = StringBuffer();
    int loadedBytes = 0;

    await for (final chunk in stream.transform(utf8.decoder)) {
      buffer.write(chunk);
      loadedBytes += chunk.length;

      // Update progress periodically
      if (loadedBytes % (100 * 1024) == 0) {
        setState(() {
          // Show loading progress
        });
      }
    }

    var content = buffer.toString();

    // Pretty-print JSON files (skip for very large files)
    if (ext == 'json' && _fileSize < 5 * 1024 * 1024) {
      try {
        final decoded = jsonDecode(content);
        content = const JsonEncoder.withIndent('  ').convert(decoded);
      } catch (_) {
        // Not valid JSON, show as-is
      }
    }

    setState(() {
      _lines = content.split('\n');
      _totalLines = _lines.length;
      _isLoading = false;
    });
  }

  void _performSearch(String query) {
    if (query.isEmpty) {
      setState(() {
        _searchMatches = [];
        _currentMatchIndex = -1;
        _searchQuery = '';
      });
      return;
    }

    final matches = <int>[];
    final lowerQuery = query.toLowerCase();

    for (int i = 0; i < _lines.length; i++) {
      if (_lines[i].toLowerCase().contains(lowerQuery)) {
        matches.add(i);
      }
    }

    setState(() {
      _searchMatches = matches;
      _searchQuery = query;
      _currentMatchIndex = matches.isNotEmpty ? 0 : -1;
    });

    if (matches.isNotEmpty) {
      _scrollToLine(matches[0]);
    }
  }

  void _nextMatch() {
    if (_searchMatches.isEmpty) return;

    setState(() {
      _currentMatchIndex = (_currentMatchIndex + 1) % _searchMatches.length;
    });
    _scrollToLine(_searchMatches[_currentMatchIndex]);
  }

  void _previousMatch() {
    if (_searchMatches.isEmpty) return;

    setState(() {
      _currentMatchIndex = (_currentMatchIndex - 1 + _searchMatches.length) % _searchMatches.length;
    });
    _scrollToLine(_searchMatches[_currentMatchIndex]);
  }

  void _scrollToLine(int lineIndex) {
    // Ensure scroll controller is attached before scrolling
    if (!_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;

    double targetOffset;
    if (_wrapText) {
      // In wrap mode, estimate position based on proportion of total lines
      // This is approximate since wrapped lines have variable heights
      final proportion = lineIndex / _totalLines;
      targetOffset = proportion * maxScroll;
    } else {
      // In non-wrap mode, use precise fixed item height
      targetOffset = lineIndex * _itemHeight;
    }

    _scrollController.animateTo(
      targetOffset.clamp(0.0, maxScroll),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _showGotoLineDialog() {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go to Line'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Enter line number (1-$_totalLines)',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (value) {
            _gotoLine(value);
            Navigator.pop(ctx);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              _gotoLine(controller.text);
              Navigator.pop(ctx);
            },
            child: const Text('Go'),
          ),
        ],
      ),
    );
  }

  void _gotoLine(String value) {
    final lineNumber = int.tryParse(value);
    if (lineNumber == null || lineNumber < 1 || lineNumber > _totalLines) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid line number. Enter 1-$_totalLines')),
      );
      return;
    }

    _scrollToLine(lineNumber - 1); // Convert to 0-indexed
  }

  String get _fullContent => _lines.join('\n');

  @override
  Widget build(BuildContext context) {
    final fileName = widget.filePath.split(Platform.pathSeparator).last;
    final ext = fileName.split('.').last.toLowerCase();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(fileName, style: const TextStyle(fontSize: 16)),
            if (_totalLines > 0)
              Text(
                '$_totalLines lines • ${_formatFileSize(_fileSize)}',
                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
              ),
          ],
        ),
        actions: [
          // Search toggle
          IconButton(
            icon: Icon(_showSearch ? LucideIcons.x : LucideIcons.search),
            tooltip: _showSearch ? 'Close search' : 'Search',
            onPressed: () {
              setState(() {
                _showSearch = !_showSearch;
                if (!_showSearch) {
                  _searchController.clear();
                  _searchMatches = [];
                  _currentMatchIndex = -1;
                  _searchQuery = '';
                }
              });
            },
          ),
          // Goto line - disabled when wrap text is on due to variable line heights
          IconButton(
            icon: Icon(
              LucideIcons.hash,
              color: _wrapText ? Colors.grey : null,
            ),
            tooltip: _wrapText
                ? 'Disable "Wrap text" to use Go to line'
                : 'Go to line',
            onPressed: _totalLines > 0 && !_wrapText
                ? _showGotoLineDialog
                : _wrapText
                    ? () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text('Disable "Wrap text" in settings to use Go to line'),
                            action: SnackBarAction(
                              label: 'Disable',
                              onPressed: () {
                                setState(() => _wrapText = false);
                              },
                            ),
                          ),
                        );
                      }
                    : null,
          ),
          // Copy all
          IconButton(
            icon: const Icon(LucideIcons.copy),
            tooltip: 'Copy all',
            onPressed: _lines.isNotEmpty
                ? () {
                    Clipboard.setData(ClipboardData(text: _fullContent));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')),
                    );
                  }
                : null,
          ),
          // Settings menu
          PopupMenuButton<String>(
            icon: const Icon(LucideIcons.settings2),
            onSelected: (value) {
              switch (value) {
                case 'larger':
                  setState(() => _fontSize = (_fontSize + 2).clamp(10, 24));
                  break;
                case 'smaller':
                  setState(() => _fontSize = (_fontSize - 2).clamp(10, 24));
                  break;
                case 'wrap':
                  setState(() => _wrapText = !_wrapText);
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
                child: Row(
                  children: [
                    Icon(_wrapText ? LucideIcons.check : null, size: 16),
                    const SizedBox(width: 8),
                    const Text('Wrap text'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'lines',
                child: Row(
                  children: [
                    Icon(_showLineNumbers ? LucideIcons.check : null, size: 16),
                    const SizedBox(width: 8),
                    const Text('Line numbers'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          if (_showSearch) _buildSearchBar(),
          // Content
          Expanded(child: _buildContent(ext)),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
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
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
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
          // Match counter
          if (_searchMatches.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${_currentMatchIndex + 1}/${_searchMatches.length}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          if (_searchQuery.isNotEmpty && _searchMatches.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'No matches',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          const SizedBox(width: 4),
          // Navigation buttons
          IconButton(
            icon: const Icon(LucideIcons.chevronUp, size: 20),
            onPressed: _searchMatches.isNotEmpty ? _previousMatch : null,
            tooltip: 'Previous match',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(LucideIcons.chevronDown, size: 20),
            onPressed: _searchMatches.isNotEmpty ? _nextMatch : null,
            tooltip: 'Next match',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildContent(String ext) {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            if (_fileSize > _largeFileThreshold) ...[
              const SizedBox(height: 16),
              Text(
                'Loading large file (${_formatFileSize(_fileSize)})...',
                style: TextStyle(color: Colors.grey[600]),
              ),
            ],
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(LucideIcons.fileWarning, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text('Error loading file', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600])),
            ),
          ],
        ),
      );
    }

    final isCode = [
      'dart', 'js', 'ts', 'py', 'java', 'kt', 'swift', 'go', 'rs',
      'c', 'cpp', 'h', 'css', 'html', 'xml', 'json', 'yaml', 'yml', 'sh', 'bash'
    ].contains(ext);

    final bgColor = isCode ? const Color(0xFF1E1E1E) : null;
    final textColor = isCode ? Colors.white : null;
    final lineNumberWidth = _showLineNumbers ? (_totalLines.toString().length * 10.0 + 24) : 0.0;

    return Container(
      color: bgColor,
      child: _wrapText
          ? _buildWrappedContent(isCode, textColor, lineNumberWidth)
          : _buildScrollableContent(isCode, textColor, lineNumberWidth),
    );
  }

  Widget _buildWrappedContent(bool isCode, Color? textColor, double lineNumberWidth) {
    return ListView.builder(
      controller: _scrollController,
      itemCount: _lines.length,
      // No itemExtent - allow variable heights for text wrapping
      itemBuilder: (context, index) {
        final isMatch = _searchMatches.contains(index);
        final isCurrentMatch = _currentMatchIndex >= 0 &&
            _searchMatches.isNotEmpty &&
            _searchMatches[_currentMatchIndex] == index;

        return Container(
          color: isCurrentMatch
              ? Colors.yellow.withOpacity(0.3)
              : isMatch
                  ? Colors.yellow.withOpacity(0.15)
                  : null,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_showLineNumbers)
                SizedBox(
                  width: lineNumberWidth,
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontSize: _fontSize,
                      fontFamily: 'monospace',
                      color: Colors.grey,
                      height: 1.4,
                    ),
                  ),
                ),
              Expanded(
                child: _buildHighlightedText(
                  _lines[index].isEmpty ? ' ' : _lines[index],
                  isCode,
                  textColor,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildScrollableContent(bool isCode, Color? textColor, double lineNumberWidth) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: _calculateContentWidth(),
        child: ListView.builder(
          controller: _scrollController,
          itemCount: _lines.length,
          itemExtent: _itemHeight, // Fixed height for precise go-to-line
          itemBuilder: (context, index) {
            final isMatch = _searchMatches.contains(index);
            final isCurrentMatch = _currentMatchIndex >= 0 &&
                _searchMatches.isNotEmpty &&
                _searchMatches[_currentMatchIndex] == index;

            return Container(
              height: _itemHeight,
              color: isCurrentMatch
                  ? Colors.yellow.withOpacity(0.3)
                  : isMatch
                      ? Colors.yellow.withOpacity(0.15)
                      : null,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  if (_showLineNumbers)
                    SizedBox(
                      width: lineNumberWidth,
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontSize: _fontSize,
                          fontFamily: 'monospace',
                          color: Colors.grey,
                        ),
                      ),
                    ),
                  Text(
                    _lines[index].isEmpty ? ' ' : _lines[index],
                    style: TextStyle(
                      fontSize: _fontSize,
                      fontFamily: isCode ? 'monospace' : null,
                      color: textColor,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHighlightedText(String text, bool isCode, Color? textColor) {
    final baseStyle = TextStyle(
      fontSize: _fontSize,
      fontFamily: isCode ? 'monospace' : null,
      color: textColor,
      height: 1.4,
    );

    if (_searchQuery.isEmpty) {
      return Text(
        text,
        style: baseStyle,
        softWrap: true, // Enable text wrapping
      );
    }

    // Highlight search matches
    final spans = <TextSpan>[];
    final lowerText = text.toLowerCase();
    final lowerQuery = _searchQuery.toLowerCase();
    int start = 0;

    while (true) {
      final matchIndex = lowerText.indexOf(lowerQuery, start);
      if (matchIndex == -1) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }

      if (matchIndex > start) {
        spans.add(TextSpan(text: text.substring(start, matchIndex)));
      }

      spans.add(TextSpan(
        text: text.substring(matchIndex, matchIndex + _searchQuery.length),
        style: const TextStyle(
          backgroundColor: Colors.yellow,
          color: Colors.black,
        ),
      ));

      start = matchIndex + _searchQuery.length;
    }

    return Text.rich(
      TextSpan(
        children: spans,
        style: baseStyle,
      ),
      softWrap: true, // Enable text wrapping
    );
  }

  double _calculateContentWidth() {
    // Estimate width based on longest line
    int maxLength = 0;
    for (final line in _lines) {
      if (line.length > maxLength) maxLength = line.length;
    }
    // Approximate: each character is about 8 pixels wide at font size 14
    final charWidth = _fontSize * 0.6;
    final lineNumberWidth = _showLineNumbers ? (_totalLines.toString().length * 10.0 + 24) : 0.0;
    return maxLength * charWidth + lineNumberWidth + 64; // Add padding
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Controller for scrolling to specific items (used for large lists)
class ItemScrollController {
  void scrollTo({required int index, Duration? duration}) {
    // This is a placeholder - the actual implementation uses the scroll controller
  }
}
