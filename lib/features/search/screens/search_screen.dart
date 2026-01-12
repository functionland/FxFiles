import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/file_service.dart';
import 'package:fula_files/core/services/face_storage_service.dart';
import 'package:fula_files/core/models/local_file.dart';
import 'package:fula_files/core/models/face_data.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with SingleTickerProviderStateMixin {
  final _searchController = TextEditingController();
  List<LocalFile> _fileResults = [];
  List<Person> _personResults = [];
  bool _isSearching = false;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.isEmpty) {
      setState(() {
        _fileResults = [];
        _personResults = [];
      });
      return;
    }

    setState(() => _isSearching = true);
    try {
      // Search files
      final fileResults = await FileService.instance.searchFiles(query);
      
      // Search people by name
      final personResults = await FaceStorageService.instance.searchPersonsByName(query);
      
      setState(() {
        _fileResults = fileResults;
        _personResults = personResults;
        _isSearching = false;
      });
    } catch (e) {
      setState(() => _isSearching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasResults = _fileResults.isNotEmpty || _personResults.isNotEmpty;
    
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search files or people...',
            border: InputBorder.none,
          ),
          onChanged: _search,
        ),
        actions: [
          if (_searchController.text.isNotEmpty)
            IconButton(
              icon: const Icon(LucideIcons.x),
              tooltip: 'Clear search',
              onPressed: () {
                _searchController.clear();
                setState(() {
                  _fileResults = [];
                  _personResults = [];
                });
              },
            ),
        ],
        bottom: hasResults ? TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              icon: const Icon(LucideIcons.file, size: 18),
              text: 'Files (${_fileResults.length})',
            ),
            Tab(
              icon: const Icon(LucideIcons.users, size: 18),
              text: 'People (${_personResults.length})',
            ),
          ],
        ) : null,
      ),
      body: _isSearching
          ? const Center(child: CircularProgressIndicator())
          : !hasResults
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        LucideIcons.search,
                        size: 64,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _searchController.text.isEmpty
                            ? 'Search for files or people'
                            : 'No results found',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                      ),
                    ],
                  ),
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildFileResults(),
                    _buildPersonResults(),
                  ],
                ),
    );
  }

  Widget _buildFileResults() {
    if (_fileResults.isEmpty) {
      return Center(
        child: Text(
          'No files found',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    
    return ListView.builder(
      itemCount: _fileResults.length,
      itemBuilder: (context, index) {
        final file = _fileResults[index];
        return ListTile(
          leading: Icon(
            file.isDirectory ? LucideIcons.folder : LucideIcons.file,
          ),
          title: Text(file.name),
          subtitle: Text(file.path),
        );
      },
    );
  }

  Widget _buildPersonResults() {
    if (_personResults.isEmpty) {
      return Center(
        child: Text(
          'No people found',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    
    return ListView.builder(
      itemCount: _personResults.length,
      itemBuilder: (context, index) {
        final person = _personResults[index];
        return ListTile(
          leading: _buildPersonAvatar(person),
          title: Text(person.name),
          subtitle: Text('${person.faceCount} photo${person.faceCount == 1 ? '' : 's'}'),
          onTap: () => _showPersonPhotos(person),
        );
      },
    );
  }

  Widget _buildPersonAvatar(Person person) {
    if (person.thumbnailPath != null) {
      final file = File(person.thumbnailPath!);
      if (file.existsSync()) {
        return CircleAvatar(
          radius: 24,
          backgroundImage: FileImage(file),
        );
      }
    }
    
    return CircleAvatar(
      radius: 24,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: Text(
        person.name.isNotEmpty ? person.name[0].toUpperCase() : '?',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Future<void> _showPersonPhotos(Person person) async {
    final images = await FaceStorageService.instance.getImagesForPerson(person.id);
    
    if (!mounted) return;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  _buildPersonAvatar(person),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          person.name,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          '${images.length} photo${images.length == 1 ? '' : 's'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.x),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: images.isEmpty
                  ? const Center(child: Text('No photos found'))
                  : GridView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.all(8),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 4,
                        mainAxisSpacing: 4,
                      ),
                      itemCount: images.length,
                      itemBuilder: (_, i) {
                        final path = images[i];
                        final file = File(path);
                        return GestureDetector(
                          onTap: () {
                            // Navigate to image viewer - bottom sheet stays open underneath
                            context.push('/viewer/image', extra: path);
                          },
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: file.existsSync()
                                ? Image.file(
                                    file,
                                    fit: BoxFit.cover,
                                    cacheWidth: 200,
                                    errorBuilder: (_, __, ___) => Container(
                                      color: Colors.grey[300],
                                      child: const Icon(LucideIcons.imageOff),
                                    ),
                                  )
                                : Container(
                                    color: Colors.grey[300],
                                    child: const Icon(LucideIcons.imageOff),
                                  ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
