import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/file_service.dart';
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/models/recent_file.dart';
import 'package:fula_files/shared/widgets/file_thumbnail.dart';
import 'package:open_filex/open_filex.dart';

class FileBrowserScreen extends ConsumerStatefulWidget {
  final String? initialPath;
  final String? category;

  const FileBrowserScreen({super.key, this.initialPath, this.category});

  @override
  ConsumerState<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends ConsumerState<FileBrowserScreen> {
  List<LocalFile> _files = [];
  String _currentPath = '';
  String _rootPath = ''; // Track the root to know when to pop navigation
  bool _isLoading = true;
  bool _isLoadingMore = false;
  final Set<String> _selectedFiles = {};
  bool _selectionMode = false;
  bool _isCategoryMode = false; // True when showing flat category files
  
  // Pagination & sorting state
  int _totalCount = 0;
  bool _hasMore = false;
  int _currentOffset = 0;
  static const int _pageSize = 250;
  String _sortBy = 'date'; // 'date' or 'name'
  bool _sortAscending = false;
  
  // Scroll controller for lazy loading
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    SyncService.instance.addListener(_onSyncStatusChanged);
    _initPath();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    SyncService.instance.removeListener(_onSyncStatusChanged);
    super.dispose();
  }
  
  void _onSyncStatusChanged(String localPath, SyncStatus status) {
    // Refresh UI when a file in our current view changes sync status
    if (mounted) {
      setState(() {});
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= 
        _scrollController.position.maxScrollExtent - 500) {
      _loadMoreFiles();
    }
  }

  Future<void> _loadMoreFiles() async {
    if (_isLoadingMore || !_hasMore) return;
    
    setState(() => _isLoadingMore = true);
    
    try {
      if (_isCategoryMode) {
        final category = _categoryFromString(widget.category!);
        final result = await FileService.instance.getFilesByCategory(
          category,
          offset: _currentOffset,
          limit: _pageSize,
          sortBy: _sortBy,
          ascending: _sortAscending,
        );
        setState(() {
          _files.addAll(result.files);
          _currentOffset += result.files.length;
          _hasMore = result.hasMore;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      setState(() => _isLoadingMore = false);
    }
  }

  Future<void> _initPath() async {
    // Request permissions first
    final hasPermission = await FileService.instance.requestStoragePermission();
    if (!hasPermission && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Storage permission required to browse files'),
          backgroundColor: Colors.orange,
        ),
      );
    }

    if (widget.category != null && widget.category != 'downloads') {
      // For categories (except downloads), show flat list of all matching files
      _isCategoryMode = true;
      await _loadCategoryFiles();
    } else if (widget.category == 'downloads') {
      // Downloads is a folder-based category
      final categoryDir = await FileService.instance.getCategoryDirectory(
        FileCategory.downloads,
      );
      _currentPath = categoryDir.path;
      _rootPath = categoryDir.path;
      await _loadFiles();
    } else if (widget.initialPath != null) {
      _currentPath = widget.initialPath!;
      _rootPath = widget.initialPath!;
      await _loadFiles();
    } else {
      final roots = await FileService.instance.getStorageRoots();
      if (roots.isNotEmpty) {
        _currentPath = roots.first.path;
        _rootPath = roots.first.path;
      }
      await _loadFiles();
    }
  }

  Future<void> _loadCategoryFiles() async {
    setState(() {
      _isLoading = true;
      _currentOffset = 0;
      _files = [];
    });
    try {
      final category = _categoryFromString(widget.category!);
      
      // Handle starred category separately
      if (category == FileCategory.starred) {
        final files = await FileService.instance.getStarredFiles();
        // Sort starred files
        files.sort((a, b) {
          int comparison;
          if (_sortBy == 'name') {
            comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          } else {
            comparison = a.modifiedAt.compareTo(b.modifiedAt);
          }
          return _sortAscending ? comparison : -comparison;
        });
        setState(() {
          _files = files;
          _totalCount = files.length;
          _hasMore = false;
          _isLoading = false;
        });
        return;
      }
      
      final result = await FileService.instance.getFilesByCategory(
        category,
        offset: 0,
        limit: _pageSize,
        sortBy: _sortBy,
        ascending: _sortAscending,
      );
      setState(() {
        _files = result.files;
        _totalCount = result.totalCount;
        _hasMore = result.hasMore;
        _currentOffset = result.files.length;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _changeSortOrder(String sortBy, bool ascending) {
    if (_sortBy == sortBy && _sortAscending == ascending) return;
    setState(() {
      _sortBy = sortBy;
      _sortAscending = ascending;
    });
    if (_isCategoryMode) {
      _loadCategoryFiles();
    } else {
      _loadFiles();
    }
  }

  void _showSortOptions() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Sort by', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: Icon(_sortBy == 'date' && !_sortAscending ? Icons.check : null),
              title: const Text('Date modified (newest first)'),
              onTap: () {
                Navigator.pop(ctx);
                _changeSortOrder('date', false);
              },
            ),
            ListTile(
              leading: Icon(_sortBy == 'date' && _sortAscending ? Icons.check : null),
              title: const Text('Date modified (oldest first)'),
              onTap: () {
                Navigator.pop(ctx);
                _changeSortOrder('date', true);
              },
            ),
            ListTile(
              leading: Icon(_sortBy == 'name' && _sortAscending ? Icons.check : null),
              title: const Text('Name (A-Z)'),
              onTap: () {
                Navigator.pop(ctx);
                _changeSortOrder('name', true);
              },
            ),
            ListTile(
              leading: Icon(_sortBy == 'name' && !_sortAscending ? Icons.check : null),
              title: const Text('Name (Z-A)'),
              onTap: () {
                Navigator.pop(ctx);
                _changeSortOrder('name', false);
              },
            ),
          ],
        ),
      ),
    );
  }

  FileCategory _categoryFromString(String cat) {
    switch (cat) {
      case 'images': return FileCategory.images;
      case 'videos': return FileCategory.videos;
      case 'audio': return FileCategory.audio;
      case 'documents': return FileCategory.documents;
      case 'downloads': return FileCategory.downloads;
      case 'archives': return FileCategory.archives;
      case 'starred': return FileCategory.starred;
      default: return FileCategory.other;
    }
  }

  Future<void> _loadFiles() async {
    setState(() => _isLoading = true);
    try {
      final files = await FileService.instance.listDirectory(
        _currentPath,
        sortBy: _sortBy,
        ascending: _sortAscending,
      );
      setState(() {
        _files = files;
        _totalCount = files.length;
        _hasMore = false; // Directory listing doesn't paginate
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _navigateTo(LocalFile file) {
    if (file.isDirectory) {
      setState(() => _currentPath = file.path);
      _loadFiles();
    } else {
      _openFile(file);
    }
  }

  void _openFile(LocalFile file) async {
    // Track as recent file
    await LocalStorageService.instance.addRecentFile(RecentFile(
      path: file.path,
      name: file.name,
      mimeType: file.mimeType,
      size: file.size,
      accessedAt: DateTime.now(),
    ));

    if (!mounted) return;

    final ext = file.extension.toLowerCase();
    
    if (file.isImage) {
      context.push('/viewer/image', extra: file.path);
    } else if (file.isVideo) {
      context.push('/viewer/video', extra: file.path);
    } else if (file.isAudio) {
      context.push('/viewer/audio', extra: file.path);
    } else if (['txt', 'md', 'json', 'xml', 'yaml', 'yml', 'dart', 'js', 'py', 'java', 'kt', 'swift', 'go', 'rs', 'c', 'cpp', 'h', 'css', 'html', 'sh', 'rtf', 'csv', 'log', 'ini', 'conf', 'cfg'].contains(ext)) {
      context.push('/viewer/text', extra: file.path);
    }
  }

  void _navigateUp() {
    if (_isCategoryMode) {
      // In category mode, just go back in navigation
      context.pop();
      return;
    }
    
    // Check if we're at the root
    if (_currentPath == _rootPath || Directory(_currentPath).parent.path == _currentPath) {
      context.pop();
      return;
    }
    
    final parent = Directory(_currentPath).parent;
    setState(() => _currentPath = parent.path);
    _loadFiles();
  }

  void _toggleSelection(LocalFile file) {
    setState(() {
      if (_selectedFiles.contains(file.path)) {
        _selectedFiles.remove(file.path);
        if (_selectedFiles.isEmpty) _selectionMode = false;
      } else {
        _selectedFiles.add(file.path);
        _selectionMode = true;
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedFiles.clear();
      _selectionMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.category != null 
        ? _categoryTitle(widget.category!)
        : _currentPath.split(Platform.pathSeparator).last;

    return Scaffold(
      appBar: _selectionMode ? _buildSelectionAppBar() : AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _navigateUp,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            if (_totalCount > 0)
              Text(
                '$_totalCount items${_hasMore ? '+' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.arrowUpDown),
            tooltip: 'Sort',
            onPressed: _showSortOptions,
          ),
          if (!_isCategoryMode)
            IconButton(
              icon: const Icon(LucideIcons.folderUp),
              onPressed: _navigateUp,
            ),
          IconButton(
            icon: const Icon(LucideIcons.refreshCw),
            onPressed: _isCategoryMode ? _loadCategoryFiles : _loadFiles,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(LucideIcons.folderOpen, size: 64, color: Colors.grey),
                      const SizedBox(height: 16),
                      const Text('No files found'),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _isCategoryMode ? _loadCategoryFiles : _loadFiles,
                  child: ListView.builder(
                    controller: _scrollController,
                    cacheExtent: 500, // Virtualization: cache items outside viewport
                    itemCount: _files.length + (_hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      // Loading indicator at bottom
                      if (index >= _files.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      
                      final file = _files[index];
                      final syncState = LocalStorageService.instance.getSyncState(file.path);
                      final isSelected = _selectedFiles.contains(file.path);
                      
                      return ListTile(
                        selected: isSelected,
                        selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                        leading: FileThumbnail(file: file, size: 48),
                        title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Row(
                          children: [
                            Text(file.isDirectory ? 'Folder' : file.sizeFormatted),
                            if (syncState != null) ...[
                              const SizedBox(width: 8),
                              _buildSyncStatusIcon(syncState.status),
                            ],
                          ],
                        ),
                        trailing: IconButton(
                          icon: const Icon(LucideIcons.moreVertical),
                          onPressed: () => _showFileOptions(file),
                        ),
                        onTap: _selectionMode 
                            ? () => _toggleSelection(file)
                            : () => _navigateTo(file),
                        onLongPress: () => _toggleSelection(file),
                      );
                    },
                  ),
                ),
    );
  }

  AppBar _buildSelectionAppBar() {
    final isLoggedIn = AuthService.instance.isAuthenticated;
    return AppBar(
      leading: IconButton(
        icon: const Icon(LucideIcons.x),
        onPressed: _clearSelection,
      ),
      title: Text('${_selectedFiles.length} selected'),
      actions: [
        if (isLoggedIn) IconButton(
          icon: const Icon(LucideIcons.upload),
          tooltip: 'Upload to cloud',
          onPressed: _uploadSelected,
        ),
        IconButton(
          icon: const Icon(LucideIcons.share2),
          tooltip: 'Share',
          onPressed: _shareSelected,
        ),
        IconButton(
          icon: const Icon(LucideIcons.trash2),
          tooltip: 'Delete',
          onPressed: _deleteSelected,
        ),
      ],
    );
  }

  String _categoryTitle(String cat) {
    switch (cat) {
      case 'images': return 'Images';
      case 'videos': return 'Videos';
      case 'audio': return 'Audio';
      case 'documents': return 'Documents';
      case 'downloads': return 'Downloads';
      case 'archives': return 'Archives';
      case 'starred': return 'Starred';
      default: return 'Files';
    }
  }

  void _showFileOptions(LocalFile file) {
    final isLoggedIn = AuthService.instance.isAuthenticated;
    final isStarred = LocalStorageService.instance.isStarred(file.path);
    
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Star/Unstar option
            ListTile(
              leading: Icon(isStarred ? LucideIcons.starOff : LucideIcons.star),
              title: Text(isStarred ? 'Remove from Starred' : 'Add to Starred'),
              onTap: () async {
                Navigator.pop(ctx);
                await LocalStorageService.instance.toggleStar(file.path);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(isStarred ? 'Removed from starred' : 'Added to starred'),
                    ),
                  );
                  // Refresh if in starred category
                  if (widget.category == 'starred') {
                    _loadCategoryFiles();
                  }
                }
              },
            ),
            const Divider(height: 1),
            // Cloud actions - disabled if not logged in
            ListTile(
              leading: Icon(LucideIcons.upload, color: isLoggedIn ? null : Colors.grey),
              title: Text('Upload to Cloud', style: TextStyle(color: isLoggedIn ? null : Colors.grey)),
              subtitle: isLoggedIn ? null : const Text('Sign in required', style: TextStyle(fontSize: 12)),
              onTap: isLoggedIn ? () {
                Navigator.pop(ctx);
                _uploadFile(file);
              } : null,
            ),
            ListTile(
              leading: Icon(LucideIcons.share2, color: isLoggedIn ? null : Colors.grey),
              title: Text('Create Share Link', style: TextStyle(color: isLoggedIn ? null : Colors.grey)),
              subtitle: isLoggedIn ? null : const Text('Sign in required', style: TextStyle(fontSize: 12)),
              onTap: isLoggedIn ? () {
                Navigator.pop(ctx);
                context.push('/shared');
              } : null,
            ),
            const Divider(height: 1),
            // Local actions
            if (!file.isDirectory) ListTile(
              leading: const Icon(LucideIcons.externalLink),
              title: const Text('Open with...'),
              onTap: () {
                Navigator.pop(ctx);
                _openWithExternalApp(file);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.share),
              title: const Text('Share'),
              onTap: () {
                Navigator.pop(ctx);
                _shareFile(file);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.pencil),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(ctx);
                _renameFile(file);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.copy),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(ctx);
                _copyFile(file);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.folderInput),
              title: const Text('Move'),
              onTap: () {
                Navigator.pop(ctx);
                _moveFile(file);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.trash2, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteFile(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _uploadFile(LocalFile file) async {
    try {
      // Determine bucket based on file category
      final category = FileCategory.fromPath(file.path);
      final bucket = category.bucketName;
      
      await SyncService.instance.queueUpload(
        localPath: file.path,
        remoteBucket: bucket,
        remoteKey: file.name,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Queued for upload: ${file.name}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _uploadSelected() async {
    for (final path in _selectedFiles) {
      final file = _files.firstWhere((f) => f.path == path);
      await _uploadFile(file);
    }
    _clearSelection();
  }

  void _shareSelected() {
    // Use platform share
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Sharing ${_selectedFiles.length} files')),
    );
    _clearSelection();
  }

  void _shareFile(LocalFile file) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Sharing: ${file.name}')),
    );
  }

  Future<void> _deleteSelected() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to Trash'),
        content: Text('Move ${_selectedFiles.length} items to trash?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      int deleted = 0;
      int failed = 0;
      for (final path in _selectedFiles.toList()) {
        try {
          await FileService.instance.moveToTrash(path);
          deleted++;
        } catch (e) {
          failed++;
        }
      }
      _clearSelection();
      if (_isCategoryMode) {
        _loadCategoryFiles();
      } else {
        _loadFiles();
      }
      if (mounted) {
        if (failed > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Deleted $deleted, $failed not found')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Moved $deleted items to trash')),
          );
        }
      }
    }
  }

  Widget _buildSyncStatusIcon(SyncStatus status) {
    switch (status) {
      case SyncStatus.notSynced:
        return Icon(LucideIcons.cloud, size: 14, color: Colors.grey.shade400);
      case SyncStatus.syncing:
        return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case SyncStatus.synced:
        return const Icon(LucideIcons.checkCircle, size: 14, color: Colors.green);
      case SyncStatus.error:
        return const Icon(LucideIcons.cloudOff, size: 14, color: Colors.red);
    }
  }

  Future<void> _renameFile(LocalFile file) async {
    final controller = TextEditingController(text: file.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'New name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != file.name) {
      try {
        await FileService.instance.renameFile(file.path, newName);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Renamed successfully')),
          );
        }
        if (_isCategoryMode) {
          _loadCategoryFiles();
        } else {
          _loadFiles();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _openWithExternalApp(LocalFile file) async {
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open file: ${result.message}')),
      );
    }
  }

  Future<void> _copyFile(LocalFile file) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Select destination for "${file.name}"'),
        action: SnackBarAction(
          label: 'Paste here',
          onPressed: () async {
            final newPath = '$_currentPath${Platform.pathSeparator}${file.name}';
            try {
              await FileService.instance.copyFile(file.path, newPath);
              _loadFiles();
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Copy failed: $e'), backgroundColor: Colors.red),
                );
              }
            }
          },
        ),
        duration: const Duration(seconds: 10),
      ),
    );
  }

  Future<void> _moveFile(LocalFile file) async {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Navigate to destination, then paste "${file.name}"'),
        action: SnackBarAction(
          label: 'Move here',
          onPressed: () async {
            final newPath = '$_currentPath${Platform.pathSeparator}${file.name}';
            try {
              await FileService.instance.moveFile(file.path, newPath);
              _loadFiles();
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Move failed: $e'), backgroundColor: Colors.red),
                );
              }
            }
          },
        ),
        duration: const Duration(seconds: 10),
      ),
    );
  }

  Future<void> _deleteFile(LocalFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to Trash'),
        content: Text('Move "${file.name}" to trash?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await FileService.instance.moveToTrash(file.path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Moved to trash')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$e'), backgroundColor: Colors.orange),
          );
        }
      }
      // Always refresh the list
      if (_isCategoryMode) {
        _loadCategoryFiles();
      } else {
        _loadFiles();
      }
    }
  }
}
