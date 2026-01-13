import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:showcaseview/showcaseview.dart';
import 'package:fula_files/core/services/file_service.dart';
import 'package:fula_files/core/services/media_service.dart';
import 'package:fula_files/core/services/sync_service.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/folder_watch_service.dart';
import 'package:fula_files/core/services/sharing_service.dart';
import 'package:fula_files/core/services/face_detection_service.dart';
import 'package:fula_files/core/services/archive_service.dart';
import 'package:fula_files/core/services/tutorial_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/models/recent_file.dart';
import 'package:fula_files/core/models/folder_sync.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/shared/widgets/file_thumbnail.dart';
import 'package:fula_files/shared/widgets/thumb_scroll.dart';
import 'package:fula_files/features/settings/providers/settings_provider.dart';
import 'package:fula_files/features/sharing/widgets/create_share_dialog.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:fula_files/shared/utils/error_messages.dart';

/// View mode for file browser
enum ViewMode {
  list,
  largeGrid, // 2 columns
  smallGrid, // 4 columns
}

class FileBrowserScreen extends ConsumerStatefulWidget {
  final String? initialPath;
  final String? category;
  final bool cloudMode; // True to browse cloud buckets/folders
  final String? initialBucket; // Initial bucket for cloud mode
  final String? initialPrefix; // Initial prefix for cloud mode

  const FileBrowserScreen({
    super.key, 
    this.initialPath, 
    this.category,
    this.cloudMode = false,
    this.initialBucket,
    this.initialPrefix,
  });

  @override
  ConsumerState<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

// Wrapper to hold either a local file or a cloud-only file for unified list
class _FileListItem {
  final LocalFile? localFile;
  final FulaObject? cloudFile;
  
  _FileListItem.local(this.localFile) : cloudFile = null;
  _FileListItem.cloud(this.cloudFile) : localFile = null;
  
  bool get isCloudOnly => cloudFile != null;
  String get name => localFile?.name ?? cloudFile?.key ?? '';
  DateTime get sortDate => localFile?.modifiedAt ?? cloudFile?.lastModified ?? DateTime.now();
}

class _FileBrowserScreenState extends ConsumerState<FileBrowserScreen> {
  List<LocalFile> _files = [];
  List<_FileListItem> _combinedFiles = []; // Merged and sorted list (local + cloud-only)
  String _currentPath = '';
  String _rootPath = ''; // Track the root to know when to pop navigation
  bool _isLoading = true;
  bool _isLoadingMore = false;
  final Set<String> _selectedFiles = {};
  bool _selectionMode = false;
  bool _isCategoryMode = false; // True when showing flat category files
  
  // Cloud mode state
  bool _isCloudMode = false;
  String? _currentBucket;
  String _currentPrefix = '';
  List<String> _buckets = [];
  List<FulaObject> _cloudObjects = [];
  
  // Pagination & sorting state
  int _totalCount = 0;
  bool _hasMore = false;
  int _currentOffset = 0;
  static const int _pageSize = 250;
  String _sortBy = 'date'; // 'date' or 'name'
  bool _sortAscending = false;
  
  // View mode state
  ViewMode _viewMode = ViewMode.list;
  
  // Scroll controller for lazy loading
  final ScrollController _scrollController = ScrollController();

  // Debounce timer for sync status updates
  Timer? _syncRefreshTimer;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    SyncService.instance.addListener(_onSyncStatusChanged);
    _loadViewMode();
    _initPath();
  }

  /// Load saved view mode for current category/path
  void _loadViewMode() {
    final key = _getViewModeKey();
    final savedMode = LocalStorageService.instance.getSetting<String>(key);
    if (savedMode != null) {
      setState(() {
        _viewMode = ViewMode.values.firstWhere(
          (m) => m.name == savedMode,
          orElse: () => ViewMode.list,
        );
      });
    }
  }

  /// Save view mode for current category/path
  void _saveViewMode() {
    final key = _getViewModeKey();
    LocalStorageService.instance.saveSetting(key, _viewMode.name);
  }

  /// Get storage key for view mode (per category or path)
  String _getViewModeKey() {
    if (widget.category != null) {
      return 'viewMode_category_${widget.category}';
    } else if (widget.cloudMode) {
      return 'viewMode_cloud';
    } else {
      return 'viewMode_folder';
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _syncRefreshTimer?.cancel();
    SyncService.instance.removeListener(_onSyncStatusChanged);
    super.dispose();
  }

  void _onSyncStatusChanged(String localPath, SyncStatus status) {
    // Debounce: Only refresh UI at most once per 500ms
    // This prevents ~20 rebuilds/sec when 5 parallel uploads are running
    _syncRefreshTimer?.cancel();
    _syncRefreshTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {});
      }
    });
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

        // On iOS, use MediaService for media categories
        final isMediaCategory = category == FileCategory.images ||
                                category == FileCategory.videos ||
                                category == FileCategory.audio;

        final List<LocalFile> newFiles;
        final bool hasMore;

        if (Platform.isIOS && isMediaCategory) {
          final result = await MediaService.instance.getMediaByCategory(
            category,
            offset: _currentOffset,
            limit: _pageSize,
            sortBy: _sortBy,
            ascending: _sortAscending,
          );
          newFiles = result.files;
          hasMore = result.hasMore;
        } else {
          final result = await FileService.instance.getFilesByCategory(
            category,
            offset: _currentOffset,
            limit: _pageSize,
            sortBy: _sortBy,
            ascending: _sortAscending,
          );
          newFiles = result.files;
          hasMore = result.hasMore;
        }

        if (!mounted) return;

        setState(() {
          _files.addAll(newFiles);
          // Also update _combinedFiles which is used for rendering in category mode
          _combinedFiles.addAll(newFiles.map((f) => _FileListItem.local(f)));
          _currentOffset += newFiles.length;
          _totalCount = _files.length;
          _hasMore = hasMore;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading more files: $e');
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
          _hasMore = false; // Stop trying to load more on error
        });
      }
    }
  }

  Future<void> _initPath() async {
    // Check if cloud mode
    if (widget.cloudMode) {
      _isCloudMode = true;
      _currentBucket = widget.initialBucket;
      _currentPrefix = widget.initialPrefix ?? '';
      await _loadCloudData();
      return;
    }
    
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
  
  // ============================================================================
  // CLOUD MODE METHODS
  // ============================================================================
  
  Future<void> _loadCloudData() async {
    if (!FulaApiService.instance.isConfigured) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Fula API not configured. Go to Settings to configure.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    setState(() {
      _isLoading = true;
      _cloudObjects = [];
      _combinedFiles = [];
    });

    try {
      if (_currentBucket == null) {
        // Load bucket list (treated as root folders)
        _buckets = await FulaApiService.instance.listBuckets();
        setState(() => _isLoading = false);
      } else {
        // Load objects in current bucket/prefix
        _cloudObjects = await FulaApiService.instance.listObjects(
          _currentBucket!,
          prefix: _currentPrefix,
        );
        
        // Build combined list with local file info where available
        await _buildCloudCombinedList();
        
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.getUserFriendlyMessage(e)), backgroundColor: Colors.red),
        );
      }
    }
  }
  
  Future<void> _buildCloudCombinedList() async {
    final combined = <_FileListItem>[];
    
    for (final cloudObj in _cloudObjects) {
      // Try to find matching local file
      final localFile = await _findLocalFileForCloudObject(cloudObj);
      
      if (localFile != null) {
        // File exists locally - use local file (has thumbnail, can open)
        combined.add(_FileListItem.local(localFile));
      } else {
        // Cloud only
        combined.add(_FileListItem.cloud(cloudObj));
      }
    }
    
    // Sort combined list
    combined.sort((a, b) {
      // Directories first
      final aIsDir = a.localFile?.isDirectory == true || a.cloudFile?.isDirectory == true;
      final bIsDir = b.localFile?.isDirectory == true || b.cloudFile?.isDirectory == true;
      if (aIsDir && !bIsDir) return -1;
      if (!aIsDir && bIsDir) return 1;
      
      int comparison;
      if (_sortBy == 'name') {
        comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      } else {
        comparison = a.sortDate.compareTo(b.sortDate);
      }
      return _sortAscending ? comparison : -comparison;
    });
    
    _combinedFiles = combined;
  }
  
  Future<LocalFile?> _findLocalFileForCloudObject(FulaObject cloudObj) async {
    // 1. First check sync states to find local path for this cloud object
    final allSyncStates = LocalStorageService.instance.getAllSyncStates();

    for (final state in allSyncStates) {
      if (state.bucket == _currentBucket && state.remoteKey == cloudObj.key) {
        // Found matching sync state - check if local file exists
        final file = File(state.localPath);
        if (await file.exists()) {
          final stat = await file.stat();
          return LocalFile(
            path: state.localPath,
            name: state.localPath.split('/').last.split('\\').last,
            isDirectory: false,
            size: stat.size,
            modifiedAt: stat.modified,
          );
        }
      }
    }

    // 2. Fallback: Check category directory by filename
    if (_currentBucket != null) {
      final category = _categoryFromBucket(_currentBucket!);
      if (category != null) {
        try {
          final categoryDir = await FileService.instance.getCategoryDirectory(category);
          final filename = cloudObj.key.split('/').last;
          final potentialPath = '${categoryDir.path}${Platform.pathSeparator}$filename';
          final file = File(potentialPath);
          if (await file.exists()) {
            final stat = await file.stat();
            return LocalFile(
              path: potentialPath,
              name: filename,
              isDirectory: false,
              size: stat.size,
              modifiedAt: stat.modified,
            );
          }
        } catch (_) {
          // Ignore errors when checking category directory
        }
      }
    }

    return null;
  }
  
  void _navigateToCloudFolder(FulaObject folder) {
    setState(() {
      _currentPrefix = folder.key;
    });
    _loadCloudData();
  }
  
  void _navigateToCloudBucket(String bucket) {
    setState(() {
      _currentBucket = bucket;
      _currentPrefix = '';
    });
    _loadCloudData();
  }
  
  bool _handleCloudBackNavigation() {
    if (_currentPrefix.isNotEmpty) {
      // Navigate up in prefix
      final parts = _currentPrefix.split('/');
      parts.removeLast(); // Remove trailing empty string from ending /
      if (parts.isNotEmpty) parts.removeLast(); // Remove current folder
      setState(() {
        _currentPrefix = parts.isEmpty ? '' : '${parts.join('/')}/';
      });
      _loadCloudData();
      return true;
    } else if (_currentBucket != null) {
      // Navigate back to bucket list
      setState(() {
        _currentBucket = null;
        _currentPrefix = '';
      });
      _loadCloudData();
      return true;
    }
    return false; // At root, allow normal back
  }

  Future<void> _loadCategoryFiles() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _currentOffset = 0;
      _files = [];
      _combinedFiles = [];
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
        if (!mounted) return;
        setState(() {
          _files = files;
          // Category mode uses _combinedFiles for rendering
          _combinedFiles = files.map((f) => _FileListItem.local(f)).toList();
          _totalCount = files.length;
          _hasMore = false;
          _isLoading = false;
        });
        return;
      }
      
      // On iOS, use MediaService for media categories (images, videos, audio)
      // This uses PhotoKit to access the device's photo library
      final isMediaCategory = category == FileCategory.images || 
                              category == FileCategory.videos || 
                              category == FileCategory.audio;
      
      final MediaResult result;
      if (Platform.isIOS && isMediaCategory) {
        result = await MediaService.instance.getMediaByCategory(
          category,
          offset: 0,
          limit: _pageSize,
          sortBy: _sortBy,
          ascending: _sortAscending,
        );
      } else {
        // Android or non-media categories: use FileService
        final fileResult = await FileService.instance.getFilesByCategory(
          category,
          offset: 0,
          limit: _pageSize,
          sortBy: _sortBy,
          ascending: _sortAscending,
        );
        result = MediaResult(
          files: fileResult.files,
          totalCount: fileResult.totalCount,
          hasMore: fileResult.hasMore,
        );
      }
      
      // Fetch cloud files for this category and sync status
      List<FulaObject> cloudOnlyFiles = [];
      if (FulaApiService.instance.isConfigured && AuthService.instance.isAuthenticated) {
        try {
          final bucketName = category.bucketName;
          final cloudFiles = await FulaApiService.instance.listObjects(bucketName);
          debugPrint('Cloud files in $bucketName: ${cloudFiles.length}');
          
          // Create a map of cloud file names for quick lookup
          final cloudFileMap = {for (var cf in cloudFiles) cf.key: cf};
          
          // Sync local file status with cloud
          for (final localFile in result.files) {
            final cloudFile = cloudFileMap[localFile.name];
            final currentState = LocalStorageService.instance.getSyncState(localFile.path);
            
            if (cloudFile != null) {
              // File exists on cloud - mark as synced if not already
              if (currentState?.status != SyncStatus.synced) {
                await LocalStorageService.instance.addSyncState(SyncState(
                  localPath: localFile.path,
                  remotePath: '$bucketName/${localFile.name}',
                  remoteKey: localFile.name,
                  bucket: bucketName,
                  status: SyncStatus.synced,
                  lastSyncedAt: cloudFile.lastModified ?? DateTime.now(),
                  etag: cloudFile.etag,
                  localSize: localFile.size,
                  remoteSize: cloudFile.size,
                ));
              }
            } else {
              // File not on cloud - remove synced status if it was marked synced
              if (currentState?.status == SyncStatus.synced) {
                await LocalStorageService.instance.deleteSyncState(localFile.path);
              }
            }
          }
          
          // Find files that are on cloud but not locally
          final localFileNames = result.files.map((f) => f.name).toSet();
          cloudOnlyFiles = cloudFiles.where((cf) => !localFileNames.contains(cf.key)).toList();
          debugPrint('Cloud-only files: ${cloudOnlyFiles.length}');
        } catch (e) {
          debugPrint('Error fetching cloud files: $e');
        }
      }
      
      if (!mounted) return;
      
      // Build combined list and sort by timestamp
      final combined = <_FileListItem>[
        ...result.files.map((f) => _FileListItem.local(f)),
        ...cloudOnlyFiles.map((f) => _FileListItem.cloud(f)),
      ];
      
      // Sort combined list
      combined.sort((a, b) {
        int comparison;
        if (_sortBy == 'name') {
          comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        } else {
          comparison = a.sortDate.compareTo(b.sortDate);
        }
        return _sortAscending ? comparison : -comparison;
      });
      
      setState(() {
        _files = result.files;
        _combinedFiles = combined;
        _totalCount = result.totalCount;
        _hasMore = result.hasMore;
        _currentOffset = result.files.length;
        _isLoading = false;
      });
      
      // Queue images for face detection in background (only for images category)
      if (category == FileCategory.images) {
        _queueImagesForFaceDetection(result.files);
      }
    } catch (e) {
      if (!mounted) return;
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

  /// Get category from bucket name (nullable for unknown buckets)
  FileCategory? _categoryFromBucket(String bucket) {
    switch (bucket.toLowerCase()) {
      case 'images': return FileCategory.images;
      case 'videos': return FileCategory.videos;
      case 'audio': return FileCategory.audio;
      case 'documents': return FileCategory.documents;
      case 'downloads': return FileCategory.downloads;
      case 'archives': return FileCategory.archives;
      default: return null;
    }
  }

  /// Check if current category is a media category (images, videos, audio)
  bool _isMediaCategory() {
    if (widget.category == null) return false;
    final category = _categoryFromString(widget.category!);
    return category == FileCategory.images || 
           category == FileCategory.videos || 
           category == FileCategory.audio;
  }

  /// Get icon for current view mode
  IconData get _viewModeIcon {
    switch (_viewMode) {
      case ViewMode.list:
        return LucideIcons.list;
      case ViewMode.largeGrid:
        return LucideIcons.layoutGrid;
      case ViewMode.smallGrid:
        return LucideIcons.grid;
    }
  }

  /// Get tooltip for current view mode
  String get _viewModeTooltip {
    switch (_viewMode) {
      case ViewMode.list:
        return 'List view';
      case ViewMode.largeGrid:
        return 'Large grid';
      case ViewMode.smallGrid:
        return 'Small grid';
    }
  }

  /// Cycle through view modes
  void _cycleViewMode() {
    setState(() {
      switch (_viewMode) {
        case ViewMode.list:
          _viewMode = ViewMode.largeGrid;
          break;
        case ViewMode.largeGrid:
          _viewMode = ViewMode.smallGrid;
          break;
        case ViewMode.smallGrid:
          _viewMode = ViewMode.list;
          break;
      }
    });
    _saveViewMode(); // Persist the selection
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
      // Pass the image list when in Images category for correct navigation order
      if (_isCategoryMode && widget.category == 'images') {
        // Build image list from combined files, preserving the category's sort order
        final imageList = _combinedFiles
            .where((item) => item.localFile != null && !item.isCloudOnly)
            .map((item) => item.localFile!.path)
            .toList();
        final initialIndex = imageList.indexOf(file.path);

        context.push('/viewer/image', extra: {
          'filePath': file.path,
          'imageList': imageList,
          'initialIndex': initialIndex >= 0 ? initialIndex : 0,
        });
      } else {
        context.push('/viewer/image', extra: file.path);
      }
    } else if (file.isVideo) {
      context.push('/viewer/video', extra: file.path);
    } else if (file.isAudio) {
      context.push('/viewer/audio', extra: file.path);
    } else if (['txt', 'md', 'json', 'xml', 'yaml', 'yml', 'dart', 'js', 'py', 'java', 'kt', 'swift', 'go', 'rs', 'c', 'cpp', 'h', 'css', 'html', 'sh', 'rtf', 'csv', 'log', 'ini', 'conf', 'cfg', 'ts', 'tsx', 'jsx', 'vue', 'sql', 'gradle', 'properties', 'env', 'gitignore', 'dockerignore', 'makefile', 'cmake'].contains(ext)) {
      context.push('/viewer/text', extra: file.path);
    } else {
      // Unknown file type - open with system app selector
      _openWithExternalApp(file);
    }
  }

  void _navigateUp() {
    // Handle cloud mode navigation
    if (_isCloudMode) {
      if (!_handleCloudBackNavigation()) {
        context.pop();
      }
      return;
    }
    
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

  // Determines if system back gesture should pop the route or be handled internally
  bool _canPopNavigation() {
    // Handle cloud mode - don't pop if we can navigate up
    if (_isCloudMode) {
      return _currentBucket == null; // Only pop if at bucket list root
    }
    
    if (_isCategoryMode) {
      // In category mode, allow system pop
      return true;
    }
    // In folder mode, only allow pop if at root
    return _currentPath == _rootPath || Directory(_currentPath).parent.path == _currentPath;
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
    final title = _isCloudMode
        ? (_currentBucket ?? 'Cloud Storage')
        : widget.category != null
            ? _categoryTitle(widget.category!)
            : _currentPath.split(Platform.pathSeparator).last;

    return ShowCaseWidget(
      builder: (showcaseContext) => PopScope(
        canPop: _canPopNavigation(),
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) {
            _navigateUp();
          }
        },
        child: Scaffold(
          appBar: _selectionMode ? _buildSelectionAppBar() : AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _navigateUp,
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              if (_isCloudMode && _currentPrefix.isNotEmpty)
                Text(
                  _currentPrefix,
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else if (_totalCount > 0)
                Text(
                  '$_totalCount items${_hasMore ? '+' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          actions: [
            // Sync icon for categories
            if (_isCategoryMode && AuthService.instance.isAuthenticated)
              BrowserTutorialShowcase(
                showcaseKey: TutorialService.instance.browserSyncKey,
                stepIndex: 3,
                targetBorderRadius: BorderRadius.circular(20),
                child: _buildCategorySyncIcon(),
              ),
            // View mode toggle
            BrowserTutorialShowcase(
              showcaseKey: TutorialService.instance.browserViewModeKey,
              stepIndex: 2,
              targetBorderRadius: BorderRadius.circular(20),
              child: IconButton(
                icon: Icon(_viewModeIcon),
                onPressed: _cycleViewMode,
              ),
            ),
            // Sort
            BrowserTutorialShowcase(
              showcaseKey: TutorialService.instance.browserSortKey,
              stepIndex: 1,
              targetBorderRadius: BorderRadius.circular(20),
              child: IconButton(
                icon: const Icon(LucideIcons.arrowUpDown),
                onPressed: _showSortOptions,
              ),
            ),
            if (!_isCategoryMode && !_isCloudMode)
              IconButton(
                icon: const Icon(LucideIcons.folderUp),
                tooltip: 'Go up',
                onPressed: _navigateUp,
              ),
            // Refresh
            BrowserTutorialShowcase(
              showcaseKey: TutorialService.instance.browserRefreshKey,
              stepIndex: 0,
              targetBorderRadius: BorderRadius.circular(20),
              child: IconButton(
                icon: const Icon(LucideIcons.refreshCw),
                onPressed: _isCloudMode
                    ? _loadCloudData
                    : (_isCategoryMode ? _loadCategoryFiles : _loadFiles),
              ),
            ),
            // Help icon for tutorial
            if (_isCategoryMode)
              IconButton(
                icon: const Icon(LucideIcons.helpCircle),
                onPressed: () => _startTutorial(showcaseContext),
              ),
          ],
        ),
        body: _buildBody(),
        ),
      ),
    );
  }

  void _startTutorial(BuildContext showcaseContext) {
    // Filter keys based on what's visible
    final keys = <GlobalKey>[
      TutorialService.instance.browserRefreshKey,
      TutorialService.instance.browserSortKey,
      TutorialService.instance.browserViewModeKey,
    ];

    // Add sync key only if category mode and authenticated
    if (_isCategoryMode && AuthService.instance.isAuthenticated) {
      keys.add(TutorialService.instance.browserSyncKey);
    }

    // Add item keys only if there are items
    if (_combinedFiles.isNotEmpty || _files.isNotEmpty) {
      // Menu key is only available in list view
      if (_viewMode == ViewMode.list) {
        keys.add(TutorialService.instance.browserItemMenuKey);
      }
      keys.add(TutorialService.instance.browserItemKey);
    }

    ShowCaseWidget.of(showcaseContext).startShowCase(keys);
  }
  
  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    
    // Cloud mode
    if (_isCloudMode) {
      return _buildCloudBody();
    }
    
    // Category or folder mode
    final isEmpty = _isCategoryMode ? _combinedFiles.isEmpty : _files.isEmpty;
    if (isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.folderOpen, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No files found'),
            // iOS: Show option to select more photos if in limited access mode
            if (Platform.isIOS && _isCategoryMode && _isMediaCategory())
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: TextButton.icon(
                  onPressed: () async {
                    await FileService.instance.openIOSLimitedPhotosPicker();
                    _loadCategoryFiles();
                  },
                  icon: const Icon(LucideIcons.imagePlus),
                  label: const Text('Select Photos to Access'),
                ),
              ),
          ],
        ),
      );
    }
    
    // Use different layouts based on view mode
    if (_viewMode == ViewMode.list) {
      return _buildListView();
    } else {
      return _buildGridView();
    }
  }

  /// Build ThumbScrollItem list for thumbscroll widget
  List<ThumbScrollItem> _buildThumbScrollItems() {
    if (_isCategoryMode) {
      return _combinedFiles.map((item) => ThumbScrollItem(
        name: item.name,
        date: item.sortDate,
      )).toList();
    } else {
      return _files.map((file) => ThumbScrollItem(
        name: file.name,
        date: file.modifiedAt,
      )).toList();
    }
  }

  /// Get current sort mode for thumbscroll
  ThumbScrollSortMode _getThumbScrollSortMode() {
    return _sortBy == 'name' ? ThumbScrollSortMode.name : ThumbScrollSortMode.date;
  }

  Widget _buildListView() {
    final settings = ref.watch(settingsProvider);
    final thumbScrollItems = _buildThumbScrollItems();

    final listView = RefreshIndicator(
      onRefresh: _isCategoryMode ? _loadCategoryFiles : _loadFiles,
      child: ListView.builder(
        controller: _scrollController,
        cacheExtent: 500,
        itemCount: _isCategoryMode
            ? _combinedFiles.length + (_hasMore ? 1 : 0)
            : _files.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          final itemCount = _isCategoryMode ? _combinedFiles.length : _files.length;

          // Loading indicator at bottom
          if (index >= itemCount) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }

          // Category mode: use combined sorted list
          if (_isCategoryMode) {
            final item = _combinedFiles[index];
            if (item.isCloudOnly) {
              return _buildCloudOnlyFileItem(item.cloudFile!);
            }
            final file = item.localFile!;
            final syncState = LocalStorageService.instance.getSyncState(file.path);
            final isSelected = _selectedFiles.contains(file.path);
            return _buildLocalFileItem(file, syncState, isSelected, index: index);
          }

          // Folder mode: just local files
          final file = _files[index];
          final syncState = LocalStorageService.instance.getSyncState(file.path);
          final isSelected = _selectedFiles.contains(file.path);
          return _buildLocalFileItem(file, syncState, isSelected, index: index);
        },
      ),
    );

    // Wrap with ThumbScroll if enabled and has enough items
    if (settings.thumbScrollEnabled && thumbScrollItems.length > 20) {
      return ThumbScroll(
        controller: _scrollController,
        items: thumbScrollItems,
        sortMode: _getThumbScrollSortMode(),
        ascending: _sortAscending,
        enabled: true,
        child: listView,
      );
    }

    return listView;
  }

  Widget _buildGridView() {
    final settings = ref.watch(settingsProvider);
    final thumbScrollItems = _buildThumbScrollItems();
    final crossAxisCount = _viewMode == ViewMode.largeGrid ? 2 : 4;
    final itemCount = _isCategoryMode
        ? _combinedFiles.length + (_hasMore ? 1 : 0)
        : _files.length + (_hasMore ? 1 : 0);

    final gridView = RefreshIndicator(
      onRefresh: _isCategoryMode ? _loadCategoryFiles : _loadFiles,
      child: GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(8),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: _viewMode == ViewMode.largeGrid ? 0.85 : 0.9,
        ),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          final fileCount = _isCategoryMode ? _combinedFiles.length : _files.length;

          // Loading indicator at bottom
          if (index >= fileCount) {
            return const Center(child: CircularProgressIndicator());
          }

          // Category mode: use combined sorted list
          if (_isCategoryMode) {
            final item = _combinedFiles[index];
            if (item.isCloudOnly) {
              return _buildCloudOnlyGridItem(item.cloudFile!);
            }
            final file = item.localFile!;
            final syncState = LocalStorageService.instance.getSyncState(file.path);
            final isSelected = _selectedFiles.contains(file.path);
            return _buildGridItem(file, syncState, isSelected, index: index);
          }

          // Folder mode: just local files
          final file = _files[index];
          final syncState = LocalStorageService.instance.getSyncState(file.path);
          final isSelected = _selectedFiles.contains(file.path);
          return _buildGridItem(file, syncState, isSelected, index: index);
        },
      ),
    );

    // Wrap with ThumbScroll if enabled and has enough items
    if (settings.thumbScrollEnabled && thumbScrollItems.length > 20) {
      return ThumbScroll(
        controller: _scrollController,
        items: thumbScrollItems,
        sortMode: _getThumbScrollSortMode(),
        ascending: _sortAscending,
        enabled: true,
        child: gridView,
      );
    }

    return gridView;
  }

  Widget _buildGridItem(LocalFile file, SyncState? syncState, bool isSelected, {int index = -1}) {
    final isFolderSynced = file.isDirectory && _isFolderSyncEnabled(file.path);
    final isLargeGrid = _viewMode == ViewMode.largeGrid;
    final isFirstItem = index == 0 && _isCategoryMode;

    Widget gridItem = GestureDetector(
      onTap: _selectionMode
          ? () => _toggleSelection(file)
          : () => _navigateTo(file),
      onLongPress: () => _toggleSelection(file),
      child: Container(
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5)
              : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: isSelected
              ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail area
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Thumbnail or icon
                    _buildGridThumbnail(file),
                    // Selection indicator
                    if (isSelected)
                      Container(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                        child: const Center(
                          child: Icon(LucideIcons.check, color: Colors.white, size: 32),
                        ),
                      ),
                    // Sync status indicator
                    if (syncState != null || isFolderSynced)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: isFolderSynced
                              ? const Icon(LucideIcons.folderSync, size: 14, color: Colors.green)
                              : _buildSyncStatusIcon(syncState!.status),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // File info
            Container(
              padding: EdgeInsets.all(isLargeGrid ? 8 : 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    maxLines: isLargeGrid ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: isLargeGrid ? 13 : 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (isLargeGrid) ...[
                    const SizedBox(height: 2),
                    Text(
                      file.isDirectory ? 'Folder' : file.sizeFormatted,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // Wrap first item with showcase
    if (isFirstItem) {
      gridItem = BrowserTutorialShowcase(
        showcaseKey: TutorialService.instance.browserItemKey,
        stepIndex: 5,
        targetBorderRadius: BorderRadius.circular(12),
        child: gridItem,
      );
    }

    return gridItem;
  }

  Widget _buildGridThumbnail(LocalFile file) {
    // For directories, show folder icon
    if (file.isDirectory) {
      return Container(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Icon(
          LucideIcons.folder,
          size: _viewMode == ViewMode.largeGrid ? 48 : 32,
          color: Theme.of(context).colorScheme.secondary,
        ),
      );
    }
    
    // For files, try to show thumbnail
    final category = FileCategory.fromPath(file.path);
    
    // Images and videos can have thumbnails
    if (category == FileCategory.images || category == FileCategory.videos) {
      return FileThumbnail(
        file: file, 
        size: 200, // Use larger size for grid
      );
    }
    
    // For other files, show category icon
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        _getCategoryIcon(category),
        size: _viewMode == ViewMode.largeGrid ? 48 : 32,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }

  Widget _buildCloudOnlyGridItem(FulaObject cloudFile) {
    final isLargeGrid = _viewMode == ViewMode.largeGrid;
    
    return GestureDetector(
      onTap: () => _showCloudFileOptions(cloudFile),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail area with cloud icon
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: Container(
                  color: Colors.blue.withValues(alpha: 0.1),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Center(
                        child: Icon(
                          LucideIcons.cloud,
                          size: isLargeGrid ? 48 : 32,
                          color: Colors.blue,
                        ),
                      ),
                      // Cloud indicator
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.blue,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(LucideIcons.download, size: 12, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // File info
            Container(
              padding: EdgeInsets.all(isLargeGrid ? 8 : 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cloudFile.key,
                    maxLines: isLargeGrid ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: isLargeGrid ? 13 : 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (isLargeGrid) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Cloud only',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.blue.shade700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getCategoryIcon(FileCategory category) {
    switch (category) {
      case FileCategory.images:
        return LucideIcons.image;
      case FileCategory.videos:
        return LucideIcons.video;
      case FileCategory.audio:
        return LucideIcons.music;
      case FileCategory.documents:
        return LucideIcons.fileText;
      case FileCategory.archives:
        return LucideIcons.archive;
      case FileCategory.downloads:
        return LucideIcons.download;
      default:
        return LucideIcons.file;
    }
  }
  
  Widget _buildCloudBody() {
    // Show bucket list if no bucket selected
    if (_currentBucket == null) {
      if (_buckets.isEmpty) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.cloud, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              const Text('No cloud storage found'),
              const SizedBox(height: 8),
              Text(
                'Configure Fula API in Settings',
                style: TextStyle(color: Colors.grey[600]),
              ),
            ],
          ),
        );
      }
      
      return RefreshIndicator(
        onRefresh: _loadCloudData,
        child: ListView.builder(
          itemCount: _buckets.length,
          itemBuilder: (context, index) {
            final bucket = _buckets[index];
            return ListTile(
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  LucideIcons.database,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              title: Text(bucket, style: const TextStyle(fontWeight: FontWeight.w500)),
              subtitle: const Text('Cloud bucket'),
              trailing: const Icon(LucideIcons.chevronRight),
              onTap: () => _navigateToCloudBucket(bucket),
            );
          },
        ),
      );
    }
    
    // Show files in current bucket/prefix
    if (_combinedFiles.isEmpty && _cloudObjects.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.folderOpen, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No files in this location'),
          ],
        ),
      );
    }
    
    return RefreshIndicator(
      onRefresh: _loadCloudData,
      child: ListView.builder(
        controller: _scrollController,
        itemCount: _combinedFiles.length,
        itemBuilder: (context, index) {
          final item = _combinedFiles[index];
          
          if (item.isCloudOnly) {
            final cloudFile = item.cloudFile!;
            if (cloudFile.isDirectory) {
              return _buildCloudFolderItem(cloudFile);
            }
            return _buildCloudOnlyFileItem(cloudFile);
          }
          
          // File exists locally - show with thumbnail
          final file = item.localFile!;
          final syncState = LocalStorageService.instance.getSyncState(file.path);
          final isSelected = _selectedFiles.contains(file.path);
          return _buildLocalFileItem(file, syncState, isSelected);
        },
      ),
    );
  }
  
  Widget _buildCloudFolderItem(FulaObject folder) {
    // Extract just the folder name from the key
    final parts = folder.key.split('/');
    final folderName = parts.where((p) => p.isNotEmpty).lastOrNull ?? folder.key;
    
    return ListTile(
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          LucideIcons.folder,
          color: Theme.of(context).colorScheme.secondary,
        ),
      ),
      title: Text(folderName, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: const Text('Folder'),
      trailing: const Icon(LucideIcons.chevronRight),
      onTap: () => _navigateToCloudFolder(folder),
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
          icon: const Icon(LucideIcons.archive),
          tooltip: 'Compress to ZIP',
          onPressed: _compressSelected,
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
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
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
            // Folder sync option - only for directories
            if (file.isDirectory && isLoggedIn)
              ListTile(
                leading: Icon(
                  _isFolderSyncEnabled(file.path) ? LucideIcons.checkCircle : LucideIcons.folderSync,
                  color: _isFolderSyncEnabled(file.path) ? Colors.green : Colors.blue,
                ),
                title: Text(_isFolderSyncEnabled(file.path) ? 'Auto-Sync Enabled' : 'Enable Auto-Sync'),
                subtitle: Text(_isFolderSyncEnabled(file.path) ? 'Tap to manage' : 'Auto-upload new files'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showFolderSyncOptions(file);
                },
              ),
            // Share options - require file to be synced to cloud
            Builder(builder: (context) {
              final syncState = LocalStorageService.instance.getSyncState(file.path);
              final isFileSynced = syncState != null && syncState.status == SyncStatus.synced;
              final canShare = isLoggedIn && isFileSynced;
              final shareDisabledReason = !isLoggedIn
                  ? 'Sign in required'
                  : !isFileSynced
                      ? 'Upload to cloud first'
                      : '';

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: Icon(LucideIcons.link, color: canShare ? Colors.blue : Colors.grey),
                    title: Text('Create Link', style: TextStyle(color: canShare ? null : Colors.grey)),
                    subtitle: Text(canShare ? 'Anyone with link can view' : shareDisabledReason, style: const TextStyle(fontSize: 12)),
                    onTap: canShare ? () {
                      Navigator.pop(ctx);
                      _createPublicLink(file);
                    } : () {
                      Navigator.pop(ctx);
                      _showShareDisabledInfo(isLoggedIn);
                    },
                  ),
                  ListTile(
                    leading: Icon(LucideIcons.lock, color: canShare ? Colors.orange : Colors.grey),
                    title: Text('Create Link with Password', style: TextStyle(color: canShare ? null : Colors.grey)),
                    subtitle: Text(canShare ? 'Requires password to view' : shareDisabledReason, style: const TextStyle(fontSize: 12)),
                    onTap: canShare ? () {
                      Navigator.pop(ctx);
                      _createPasswordLink(file);
                    } : () {
                      Navigator.pop(ctx);
                      _showShareDisabledInfo(isLoggedIn);
                    },
                  ),
                  ListTile(
                    leading: Icon(LucideIcons.userPlus, color: canShare ? Colors.green : Colors.grey),
                    title: Text('Create Link For...', style: TextStyle(color: canShare ? null : Colors.grey)),
                    subtitle: Text(canShare ? 'Share with specific recipient' : shareDisabledReason, style: const TextStyle(fontSize: 12)),
                    onTap: canShare ? () {
                      Navigator.pop(ctx);
                      _createShareForRecipient(file);
                    } : () {
                      Navigator.pop(ctx);
                      _showShareDisabledInfo(isLoggedIn);
                    },
                  ),
                ],
              );
            }),
            const Divider(height: 1),
            // Archive actions - only for archive files
            if (!file.isDirectory && ArchiveService.instance.isArchive(file.path))
              ListTile(
                leading: const Icon(LucideIcons.folderOutput, color: Colors.orange),
                title: const Text('Extract Here'),
                subtitle: const Text('Unzip to current folder'),
                onTap: () {
                  Navigator.pop(ctx);
                  _extractArchive(file, null);
                },
              ),
            if (!file.isDirectory && ArchiveService.instance.isArchive(file.path))
              ListTile(
                leading: const Icon(LucideIcons.folderOpen, color: Colors.orange),
                title: const Text('Extract to...'),
                subtitle: const Text('Choose destination folder'),
                onTap: () {
                  Navigator.pop(ctx);
                  _extractArchiveToLocation(file);
                },
              ),
            if (!file.isDirectory && ArchiveService.instance.isArchive(file.path))
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
              title: const Text('Share via...'),
              onTap: () {
                Navigator.pop(ctx);
                _shareFileViaNative(file);
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
            // Delete options based on sync status
            ..._buildDeleteOptions(ctx, file),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _uploadFile(LocalFile file) async {
    try {
      if (file.isDirectory) {
        // Upload folder recursively
        await _uploadFolder(file);
      } else {
        // Upload single file
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
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forUpload(e)), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _uploadFolder(LocalFile folder) async {
    final dir = Directory(folder.path);
    final folderName = folder.name;
    int fileCount = 0;
    
    // Get all files recursively
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        // Calculate relative path from folder root
        final relativePath = entity.path.substring(folder.path.length + 1);
        final remoteKey = '$folderName/$relativePath'.replaceAll('\\', '/');
        
        // Determine bucket - use 'other' for mixed folder contents
        final category = FileCategory.fromPath(entity.path);
        final bucket = category.bucketName;
        
        await SyncService.instance.queueUpload(
          localPath: entity.path,
          remoteBucket: bucket,
          remoteKey: remoteKey,
        );
        fileCount++;
      }
    }
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Queued $fileCount files from "$folderName" for upload')),
      );
    }
  }

  Future<void> _uploadSelected() async {
    for (final path in _selectedFiles) {
      final file = _files.firstWhere((f) => f.path == path);
      await _uploadFile(file);
    }
    _clearSelection();
  }

  // Build sync icon for category with status indication
  Widget _buildCategorySyncIcon() {
    final category = _categoryFromString(widget.category!);
    final syncPath = 'category:${widget.category}';
    final folderSync = FolderWatchService.instance.getFolderSync(syncPath);
    
    IconData icon;
    Color? color;
    String tooltip;
    
    if (folderSync == null || folderSync.status == FolderSyncStatus.disabled) {
      icon = LucideIcons.cloudOff;
      color = Colors.grey;
      tooltip = 'Enable auto-sync';
    } else if (folderSync.status == FolderSyncStatus.syncing) {
      icon = LucideIcons.refreshCw;
      color = Colors.blue;
      tooltip = 'Syncing...';
    } else if (folderSync.status == FolderSyncStatus.synced) {
      icon = LucideIcons.checkCircle;
      color = Colors.green;
      tooltip = 'Synced';
    } else if (folderSync.status == FolderSyncStatus.error) {
      icon = LucideIcons.cloudOff;
      color = Colors.red;
      tooltip = 'Sync error';
    } else {
      icon = LucideIcons.cloud;
      color = Colors.blue;
      tooltip = 'Auto-sync enabled';
    }
    
    return IconButton(
      icon: Icon(icon, color: color),
      tooltip: tooltip,
      onPressed: () => _showCategorySyncOptions(category),
    );
  }

  void _showCategorySyncOptions(FileCategory category) {
    final syncPath = 'category:${widget.category}';
    final folderSync = FolderWatchService.instance.getFolderSync(syncPath);
    final isEnabled = folderSync?.isEnabled ?? false;
    
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Auto-Sync ${_categoryTitle(widget.category!)}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (isEnabled) ...[
              ListTile(
                leading: Icon(LucideIcons.refreshCw, color: Colors.blue),
                title: const Text('Sync Now'),
                subtitle: const Text('Upload all unsynced files'),
                onTap: () {
                  Navigator.pop(ctx);
                  _syncCategoryNow(category);
                },
              ),
              ListTile(
                leading: Icon(LucideIcons.cloudOff, color: Colors.red),
                title: const Text('Disable Auto-Sync'),
                subtitle: const Text('Stop automatic uploads'),
                onTap: () {
                  Navigator.pop(ctx);
                  _disableCategorySync();
                },
              ),
            ] else ...[
              ListTile(
                leading: Icon(LucideIcons.cloud, color: Colors.blue),
                title: const Text('Enable Auto-Sync'),
                subtitle: const Text('Automatically upload new files'),
                onTap: () {
                  Navigator.pop(ctx);
                  _enableCategorySync(category);
                },
              ),
            ],
            if (folderSync != null) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Status: ${_syncStatusText(folderSync.status)}'),
                    if (folderSync.totalFiles > 0)
                      Text('Progress: ${folderSync.syncedFiles}/${folderSync.totalFiles} files'),
                    if (folderSync.lastSyncedAt != null)
                      Text('Last synced: ${_formatDateTime(folderSync.lastSyncedAt!)}'),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _syncStatusText(FolderSyncStatus status) {
    switch (status) {
      case FolderSyncStatus.disabled: return 'Disabled';
      case FolderSyncStatus.enabled: return 'Enabled';
      case FolderSyncStatus.syncing: return 'Syncing...';
      case FolderSyncStatus.synced: return 'Synced';
      case FolderSyncStatus.error: return 'Error';
    }
  }

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _enableCategorySync(FileCategory category) async {
    try {
      final syncPath = 'category:${widget.category}';
      await FolderWatchService.instance.enableFolderSync(
        path: syncPath,
        targetBucket: category.bucketName,
        categoryName: widget.category,
        isCategory: true,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Auto-sync enabled for ${_categoryTitle(widget.category!)}')),
        );
        setState(() {}); // Refresh UI
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forSync(e)), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _disableCategorySync() async {
    try {
      final syncPath = 'category:${widget.category}';
      await FolderWatchService.instance.disableFolderSync(syncPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Auto-sync disabled for ${_categoryTitle(widget.category!)}')),
        );
        setState(() {}); // Refresh UI
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forSync(e)), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _syncCategoryNow(FileCategory category) async {
    try {
      final syncPath = 'category:${widget.category}';
      await FolderWatchService.instance.syncFolder(syncPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Started syncing ${_categoryTitle(widget.category!)}')),
        );
        setState(() {}); // Refresh UI
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forSync(e)), backgroundColor: Colors.red),
        );
      }
    }
  }

  // Face detection helpers
  void _queueImagesForFaceDetection(List<LocalFile> files) {
    // Queue images for face detection in background
    // This runs asynchronously and doesn't block the UI
    final imagePaths = files
        .where((f) => f.isImage && !f.isDirectory)
        .map((f) => f.path)
        .toList();
    
    if (imagePaths.isNotEmpty) {
      FaceDetectionService.instance.queueImagesForProcessing(imagePaths);
    }
  }

  // Folder sync helpers
  bool _isFolderSyncEnabled(String path) {
    return LocalStorageService.instance.isFolderSyncEnabled(path);
  }

  void _showFolderSyncOptions(LocalFile folder) {
    final folderSync = FolderWatchService.instance.getFolderSync(folder.path);
    final isEnabled = folderSync?.isEnabled ?? false;
    
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Auto-Sync "${folder.name}"',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (isEnabled) ...[
              ListTile(
                leading: Icon(LucideIcons.refreshCw, color: Colors.blue),
                title: const Text('Sync Now'),
                subtitle: const Text('Upload all unsynced files'),
                onTap: () {
                  Navigator.pop(ctx);
                  _syncFolderNow(folder);
                },
              ),
              ListTile(
                leading: Icon(LucideIcons.cloudOff, color: Colors.red),
                title: const Text('Disable Auto-Sync'),
                subtitle: const Text('Stop automatic uploads'),
                onTap: () {
                  Navigator.pop(ctx);
                  _disableFolderSync(folder);
                },
              ),
            ] else ...[
              ListTile(
                leading: Icon(LucideIcons.cloud, color: Colors.blue),
                title: const Text('Enable Auto-Sync'),
                subtitle: const Text('Automatically upload new files'),
                onTap: () {
                  Navigator.pop(ctx);
                  _enableFolderSync(folder);
                },
              ),
            ],
            if (folderSync != null) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Status: ${_syncStatusText(folderSync.status)}'),
                    if (folderSync.totalFiles > 0)
                      Text('Progress: ${folderSync.syncedFiles}/${folderSync.totalFiles} files'),
                    if (folderSync.lastSyncedAt != null)
                      Text('Last synced: ${_formatDateTime(folderSync.lastSyncedAt!)}'),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _enableFolderSync(LocalFile folder) async {
    try {
      final category = FileCategory.fromPath(folder.path);
      await FolderWatchService.instance.enableFolderSync(
        path: folder.path,
        targetBucket: category.bucketName,
        isCategory: false,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Auto-sync enabled for "${folder.name}"')),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forSync(e)), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _disableFolderSync(LocalFile folder) async {
    try {
      await FolderWatchService.instance.disableFolderSync(folder.path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Auto-sync disabled for "${folder.name}"')),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forSync(e)), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _syncFolderNow(LocalFile folder) async {
    try {
      await FolderWatchService.instance.syncFolder(folder.path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Started syncing "${folder.name}"')),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forSync(e)), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ============================================================================
  // SHARING
  // ============================================================================

  /// Show info message when share is disabled
  void _showShareDisabledInfo(bool isLoggedIn) {
    if (!mounted) return;

    // Clear any existing snackbars first
    ScaffoldMessenger.of(context).clearSnackBars();

    if (!isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please sign in to share files.'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 5),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please upload the file to cloud first before sharing.'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 5),
          showCloseIcon: true,
          closeIconColor: Colors.white,
        ),
      );
    }
  }

  /// Create a public link (anyone with link can access)
  Future<void> _createPublicLink(LocalFile file) async {
    final dek = await AuthService.instance.getEncryptionKey();
    if (dek == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Encryption key not available. Please sign in again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final category = FileCategory.fromPath(file.path);
    final bucket = category.bucketName;
    final pathScope = file.isDirectory ? '${file.name}/' : file.name;

    if (!mounted) return;

    final result = await showCreatePublicLinkDialog(
      context: context,
      pathScope: pathScope,
      bucket: bucket,
      dek: dek,
      fileName: file.name,
      contentType: _getContentType(file),
      localPath: file.path,
    );

    if (result != null && mounted) {
      _showGeneratedShareLinkDialog(result, isPasswordProtected: false);
    }
  }

  /// Create a password-protected link
  Future<void> _createPasswordLink(LocalFile file) async {
    final dek = await AuthService.instance.getEncryptionKey();
    if (dek == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Encryption key not available. Please sign in again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final category = FileCategory.fromPath(file.path);
    final bucket = category.bucketName;
    final pathScope = file.isDirectory ? '${file.name}/' : file.name;

    if (!mounted) return;

    final result = await showCreatePasswordLinkDialog(
      context: context,
      pathScope: pathScope,
      bucket: bucket,
      dek: dek,
      fileName: file.name,
      contentType: _getContentType(file),
      localPath: file.path,
    );

    if (result != null && mounted) {
      _showGeneratedShareLinkDialog(result, isPasswordProtected: true);
    }
  }

  /// Create a share for a specific recipient
  Future<void> _createShareForRecipient(LocalFile file) async {
    final dek = await AuthService.instance.getEncryptionKey();
    if (dek == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Encryption key not available. Please sign in again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final category = FileCategory.fromPath(file.path);
    final bucket = category.bucketName;
    final pathScope = file.isDirectory ? '${file.name}/' : file.name;

    if (!mounted) return;

    final token = await showCreateShareForRecipientDialog(
      context: context,
      pathScope: pathScope,
      bucket: bucket,
      dek: dek,
      fileName: file.name,
      contentType: _getContentType(file),
      localPath: file.path,
    );

    if (token != null && mounted) {
      final shareLink = SharingService.instance.generateShareLink(token);
      _showShareLinkDialog(shareLink, token);
    }
  }

  String? _getContentType(LocalFile file) {
    final ext = file.extension.toLowerCase();
    const mimeTypes = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'avi': 'video/x-msvideo',
      'mp3': 'audio/mpeg',
      'wav': 'audio/wav',
      'pdf': 'application/pdf',
      'txt': 'text/plain',
      'json': 'application/json',
      'zip': 'application/zip',
    };
    return mimeTypes[ext];
  }

  /// Show dialog for generated share links (public or password-protected)
  void _showGeneratedShareLinkDialog(GeneratedShareLink result, {required bool isPasswordProtected}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(LucideIcons.checkCircle, color: Colors.green),
            const SizedBox(width: 8),
            Expanded(child: Text(isPasswordProtected ? 'Password Link Created!' : 'Link Created!')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isPasswordProtected
                  ? 'Share this link. Recipients will need the password you set to access.'
                  : 'Anyone with this link can view the shared content.',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                result.url,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  isPasswordProtected ? LucideIcons.lock : LucideIcons.link,
                  size: 16,
                  color: isPasswordProtected ? Colors.orange : Colors.blue,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isPasswordProtected ? 'Password protected' : 'Public link',
                    style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            if (result.token.expiresAt != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(LucideIcons.clock, size: 16, color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Expires: ${_formatDateTime(result.token.expiresAt!)}',
                      style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: result.url));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Link copied to clipboard')),
              );
              Navigator.pop(ctx);
            },
            icon: const Icon(LucideIcons.copy),
            label: const Text('Copy Link'),
          ),
        ],
      ),
    );
  }

  // Legacy method for backward compatibility
  Future<void> _createShareLink(LocalFile file) async {
    await _createShareForRecipient(file);
  }

  void _showShareLinkDialog(String shareLink, ShareToken token) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(LucideIcons.checkCircle, color: Colors.green),
            const SizedBox(width: 8),
            const Expanded(child: Text('Share Created!')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Share link created successfully. Send this link to the recipient:'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                shareLink,
                style: TextStyle(
                  fontFamily: 'monospace', 
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(LucideIcons.shield, size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Permission: ${token.permissions.displayName}',
                    style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            if (token.expiresAt != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(LucideIcons.clock, size: 16, color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Expires: ${_formatDateTime(token.expiresAt!)}',
                      style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: shareLink));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Share link copied to clipboard')),
              );
              Navigator.pop(ctx);
            },
            icon: const Icon(LucideIcons.copy),
            label: const Text('Copy Link'),
          ),
        ],
      ),
    );
  }

  Future<void> _shareSelected() async {
    // Use platform share for selected files
    final files = _selectedFiles.map((path) => XFile(path)).toList();
    try {
      await SharePlus.instance.share(ShareParams(files: files));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forShare(e)), backgroundColor: Colors.red),
        );
      }
    }
    _clearSelection();
  }

  Future<void> _shareFileViaNative(LocalFile file) async {
    try {
      if (file.isDirectory) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot share folders directly. Share individual files instead.')),
        );
        return;
      }
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forShare(e)), backgroundColor: Colors.red),
        );
      }
    }
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

  Widget _buildLocalFileItem(LocalFile file, SyncState? syncState, bool isSelected, {int index = -1}) {
    final isFolderSynced = file.isDirectory && _isFolderSyncEnabled(file.path);
    final dateFormatted = _formatFileDate(file.modifiedAt);
    final isFirstItem = index == 0 && _isCategoryMode;

    // Build the trailing menu button, with showcase for first item
    Widget menuButton = IconButton(
      icon: const Icon(LucideIcons.moreVertical),
      onPressed: () => _showFileOptions(file),
    );
    if (isFirstItem) {
      menuButton = BrowserTutorialShowcase(
        showcaseKey: TutorialService.instance.browserItemMenuKey,
        stepIndex: 4,
        targetBorderRadius: BorderRadius.circular(20),
        child: menuButton,
      );
    }

    // Build the list tile
    Widget listTile = ListTile(
      selected: isSelected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
      leading: FileThumbnail(file: file, size: 48),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          Text(file.isDirectory ? 'Folder' : file.sizeFormatted),
          Text(
            ' • $dateFormatted',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          // Show auto-sync indicator for folders with sync enabled
          if (isFolderSynced) ...[
            const SizedBox(width: 8),
            const Icon(LucideIcons.folderSync, size: 14, color: Colors.green),
          ],
          if (syncState != null) ...[
            const SizedBox(width: 8),
            _buildSyncStatusIcon(syncState.status),
          ],
        ],
      ),
      trailing: menuButton,
      onTap: _selectionMode
          ? () => _toggleSelection(file)
          : () => _navigateTo(file),
      onLongPress: () => _toggleSelection(file),
    );

    // Wrap first item with showcase for the item itself
    if (isFirstItem) {
      listTile = BrowserTutorialShowcase(
        showcaseKey: TutorialService.instance.browserItemKey,
        stepIndex: 5,
        targetBorderRadius: BorderRadius.circular(8),
        child: listTile,
      );
    }

    return listTile;
  }

  /// Format file date for display
  String _formatFileDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final fileDate = DateTime(date.year, date.month, date.day);

    if (fileDate == today) {
      return 'Today';
    } else if (fileDate == yesterday) {
      return 'Yesterday';
    } else if (now.difference(date).inDays < 7) {
      return DateFormat('EEEE').format(date); // Day name (e.g., "Monday")
    } else if (date.year == now.year) {
      return DateFormat('MMM d').format(date); // e.g., "Jan 15"
    } else {
      return DateFormat('MMM d, y').format(date); // e.g., "Jan 15, 2023"
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

  Widget _buildCloudOnlyFileItem(FulaObject cloudFile) {
    final dateFormatted = cloudFile.lastModified != null
        ? _formatFileDate(cloudFile.lastModified!)
        : null;

    return ListTile(
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(LucideIcons.cloud, color: Colors.blue),
      ),
      title: Text(cloudFile.key, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          Text(_formatFileSize(cloudFile.size)),
          if (dateFormatted != null)
            Text(
              ' • $dateFormatted',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(width: 8),
          const Icon(LucideIcons.download, size: 14, color: Colors.blue),
          const SizedBox(width: 4),
          Text('Cloud only', style: TextStyle(color: Colors.blue.shade700, fontSize: 12)),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(LucideIcons.moreVertical),
        onPressed: () => _showCloudFileOptions(cloudFile),
      ),
    );
  }

  void _showCloudFileOptions(FulaObject cloudFile) {
    // Get bucket from current bucket (cloud mode) or category
    final bucket = _isCloudMode
        ? _currentBucket!
        : _categoryFromString(widget.category!).bucketName;
    
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.download, color: Colors.blue),
              title: const Text('Download'),
              onTap: () {
                Navigator.pop(ctx);
                _downloadCloudFile(cloudFile);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.cloudOff, color: Colors.red),
              title: const Text('Delete from Cloud', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteCloudOnlyFile(cloudFile, bucket);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _downloadCloudFile(FulaObject cloudFile) async {
    // Get bucket from current bucket (cloud mode) or category
    final bucket = _isCloudMode
        ? _currentBucket!
        : _categoryFromString(widget.category!).bucketName;
    final category = _isCloudMode
        ? _categoryFromBucket(bucket)
        : _categoryFromString(widget.category!);

    // Show downloading indicator
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Downloading ${cloudFile.key}...')),
    );

    try {
      // Get encryption key for decryption
      final encryptionKey = await AuthService.instance.getEncryptionKey();

      Uint8List data;
      if (encryptionKey != null) {
        // Download and decrypt if we have an encryption key
        data = await FulaApiService.instance.downloadAndDecrypt(
          bucket,
          cloudFile.key,
          encryptionKey,
        );
        debugPrint('Downloaded and decrypted ${cloudFile.key}');
      } else {
        // Fallback to plain download if no encryption key
        data = await FulaApiService.instance.downloadObject(bucket, cloudFile.key);
        debugPrint('Downloaded ${cloudFile.key} without decryption (no key)');
      }

      // Get the appropriate download directory based on category
      final downloadPath = await _getDownloadPath(category ?? FileCategory.other, cloudFile.key);

      // Write file to local storage
      final file = File(downloadPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data);

      // Add sync state for the downloaded file
      await LocalStorageService.instance.addSyncState(SyncState(
        localPath: downloadPath,
        remotePath: '$bucket/${cloudFile.key}',
        remoteKey: cloudFile.key,
        bucket: bucket,
        status: SyncStatus.synced,
        lastSyncedAt: DateTime.now(),
        etag: cloudFile.etag,
        localSize: data.length,
        remoteSize: cloudFile.size,
      ));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Downloaded ${cloudFile.key}')),
        );
        // Refresh to show the file locally
        if (_isCloudMode) {
          _loadCloudData();
        } else {
          _loadCategoryFiles();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.forDownload(e)), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<String> _getDownloadPath(FileCategory category, String fileName) async {
    // Get external storage directory
    final directories = await FileService.instance.getStorageRoots();
    if (directories.isEmpty) {
      throw Exception('No storage available');
    }
    
    // Use Download folder as base
    final basePath = directories.first.path;
    final downloadDir = '$basePath/Download';
    
    return '$downloadDir/$fileName';
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
            SnackBar(content: Text(ErrorMessages.forRename(e)), backgroundColor: Colors.red),
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
                  SnackBar(content: Text(ErrorMessages.forCopy(e)), backgroundColor: Colors.red),
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
                  SnackBar(content: Text(ErrorMessages.forMove(e)), backgroundColor: Colors.red),
                );
              }
            }
          },
        ),
        duration: const Duration(seconds: 10),
      ),
    );
  }

  List<Widget> _buildDeleteOptions(BuildContext ctx, LocalFile file) {
    final syncState = LocalStorageService.instance.getSyncState(file.path);
    final isOnCloud = syncState?.status == SyncStatus.synced;
    final isLoggedIn = AuthService.instance.isAuthenticated;
    
    return [
      // Delete from device (always available for local files)
      ListTile(
        leading: const Icon(LucideIcons.trash2, color: Colors.red),
        title: const Text('Delete from Device', style: TextStyle(color: Colors.red)),
        onTap: () {
          Navigator.pop(ctx);
          _deleteFile(file);
        },
      ),
      // Delete from cloud (only if synced and logged in)
      if (isOnCloud && isLoggedIn)
        ListTile(
          leading: const Icon(LucideIcons.cloudOff, color: Colors.red),
          title: const Text('Delete from Cloud', style: TextStyle(color: Colors.red)),
          onTap: () {
            Navigator.pop(ctx);
            _deleteFromCloud(file);
          },
        ),
    ];
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
            SnackBar(content: Text(ErrorMessages.forDelete(e)), backgroundColor: Colors.orange),
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

  Future<void> _deleteFromCloud(LocalFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete from Cloud'),
        content: Text('Delete "${file.name}" from cloud storage?\n\nThe local file will not be affected.'),
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
        final category = FileCategory.fromPath(file.path);
        final bucket = category.bucketName;
        await FulaApiService.instance.deleteObject(bucket, file.name);
        
        // Remove sync state since file is no longer on cloud
        await LocalStorageService.instance.deleteSyncState(file.path);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Deleted from cloud')),
          );
          // Refresh to update sync status icons
          if (_isCategoryMode) {
            _loadCategoryFiles();
          } else {
            _loadFiles();
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ErrorMessages.getUserFriendlyMessage(e)), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _deleteCloudOnlyFile(FulaObject cloudFile, String bucket) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete from Cloud'),
        content: Text('Delete "${cloudFile.key}" from cloud storage?'),
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
        await FulaApiService.instance.deleteObject(bucket, cloudFile.key);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Deleted from cloud')),
          );
          _loadCategoryFiles();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ErrorMessages.getUserFriendlyMessage(e)), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  // ============================================================================
  // ARCHIVE OPERATIONS
  // ============================================================================

  /// Extract an archive file to the specified directory (or same folder if null)
  Future<void> _extractArchive(LocalFile file, String? outputDir) async {
    // Store output path for navigation
    String? extractedPath;

    // Show loading indicator
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
              const SizedBox(width: 16),
              Text('Extracting ${file.name}...'),
            ],
          ),
          duration: const Duration(seconds: 30),
        ),
      );
    }

    try {
      final result = await ArchiveService.instance.extractZip(
        file.path,
        outputDir: outputDir,
      );

      if (!mounted) return;

      // Clear the loading snackbar
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (result.success) {
        extractedPath = result.outputPath;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Extracted ${result.fileCount} files'),
            duration: const Duration(seconds: 4),
          ),
        );
        // Refresh the file list
        if (_isCategoryMode) {
          _loadCategoryFiles();
        } else {
          _loadFiles();
        }

        // Navigate to extracted folder after a short delay
        if (extractedPath != null) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (mounted) {
            context.push('/browser', extra: {'path': extractedPath});
          }
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Extraction failed: ${result.error}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.getUserFriendlyMessage(e)), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Let user pick a destination folder and extract archive there
  Future<void> _extractArchiveToLocation(LocalFile file) async {
    try {
      // Use file_picker to select destination directory
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select destination folder',
      );

      if (result != null && mounted) {
        await _extractArchive(file, result);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.getUserFriendlyMessage(e, context: 'select folder')), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Compress selected files to a ZIP archive
  Future<void> _compressSelected() async {
    if (_selectedFiles.isEmpty) return;

    // Show loading indicator
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
              const SizedBox(width: 16),
              Text('Compressing ${_selectedFiles.length} item(s)...'),
            ],
          ),
          duration: const Duration(seconds: 60),
        ),
      );
    }

    try {
      final paths = _selectedFiles.toList();
      final result = await ArchiveService.instance.compressToZip(paths);

      if (!mounted) return;

      // Clear selection and loading snackbar
      _clearSelection();
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Created ZIP with ${result.fileCount} files'),
            action: SnackBarAction(
              label: 'View',
              onPressed: () {
                // Refresh and scroll to show the new file
                if (_isCategoryMode) {
                  _loadCategoryFiles();
                } else {
                  _loadFiles();
                }
              },
            ),
          ),
        );
        // Refresh the file list
        if (_isCategoryMode) {
          _loadCategoryFiles();
        } else {
          _loadFiles();
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Compression failed: ${result.error}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessages.getUserFriendlyMessage(e)), backgroundColor: Colors.red),
        );
      }
    }
  }
}
