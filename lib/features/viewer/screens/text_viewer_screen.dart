import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/models/recent_file.dart';

class TextViewerScreen extends StatefulWidget {
  final String filePath;

  const TextViewerScreen({super.key, required this.filePath});

  @override
  State<TextViewerScreen> createState() => _TextViewerScreenState();
}

class _TextViewerScreenState extends State<TextViewerScreen> {
  String? _content;
  String? _error;
  bool _isLoading = true;
  double _fontSize = 14;
  bool _wrapText = true;
  bool _showLineNumbers = false;

  @override
  void initState() {
    super.initState();
    _loadFile();
    _trackRecentFile();
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
      var content = await file.readAsString();
      
      // Pretty-print JSON files
      final ext = widget.filePath.split('.').last.toLowerCase();
      if (ext == 'json') {
        try {
          final decoded = jsonDecode(content);
          content = const JsonEncoder.withIndent('  ').convert(decoded);
        } catch (_) {
          // Not valid JSON, show as-is
        }
      }
      
      setState(() {
        _content = content;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.filePath.split(Platform.pathSeparator).last;
    final ext = fileName.split('.').last.toLowerCase();

    return Scaffold(
      appBar: AppBar(
        title: Text(fileName, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.copy),
            tooltip: 'Copy all',
            onPressed: _content != null ? () {
              Clipboard.setData(ClipboardData(text: _content!));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            } : null,
          ),
          IconButton(
            icon: const Icon(LucideIcons.share),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Sharing: ${widget.filePath.split(Platform.pathSeparator).last}')),
              );
            },
          ),
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
      body: _buildContent(ext),
    );
  }

  Widget _buildContent(String ext) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
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

    final lines = _content!.split('\n');
    final isCode = ['dart', 'js', 'ts', 'py', 'java', 'kt', 'swift', 'go', 'rs', 'c', 'cpp', 'h', 'css', 'html', 'xml', 'json', 'yaml', 'yml', 'sh', 'bash'].contains(ext);

    return Container(
      color: isCode ? const Color(0xFF1E1E1E) : null,
      child: SingleChildScrollView(
        scrollDirection: _wrapText ? Axis.vertical : Axis.horizontal,
        child: SingleChildScrollView(
          scrollDirection: _wrapText ? Axis.horizontal : Axis.vertical,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _showLineNumbers
              ? _buildWithLineNumbers(lines, isCode)
              : SelectableText(
                  _content!,
                  style: TextStyle(
                    fontSize: _fontSize,
                    fontFamily: isCode ? 'monospace' : null,
                    color: isCode ? Colors.white : null,
                  ),
                ),
          ),
        ),
      ),
    );
  }

  Widget _buildWithLineNumbers(List<String> lines, bool isCode) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Line numbers
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(lines.length, (i) => Text(
            '${i + 1}',
            style: TextStyle(
              fontSize: _fontSize,
              fontFamily: 'monospace',
              color: Colors.grey,
              height: 1.5,
            ),
          )),
        ),
        const SizedBox(width: 16),
        // Content
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lines.map((line) => SelectableText(
            line.isEmpty ? ' ' : line,
            style: TextStyle(
              fontSize: _fontSize,
              fontFamily: isCode ? 'monospace' : null,
              color: isCode ? Colors.white : null,
              height: 1.5,
            ),
          )).toList(),
        ),
      ],
    );
  }
}
