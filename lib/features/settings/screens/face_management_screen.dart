import 'dart:io';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/face_data.dart';
import 'package:fula_files/core/services/face_storage_service.dart';
import 'package:fula_files/core/services/face_detection_service.dart';

class FaceManagementScreen extends StatefulWidget {
  const FaceManagementScreen({super.key});

  @override
  State<FaceManagementScreen> createState() => _FaceManagementScreenState();
}

class _FaceManagementScreenState extends State<FaceManagementScreen> {
  List<Person> _persons = [];
  int _unnamedFaceCount = 0;
  bool _isLoading = true;
  int _processedImages = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    
    try {
      await FaceStorageService.instance.init();
      
      final persons = await FaceStorageService.instance.getAllPersons();
      final unnamedCount = await FaceStorageService.instance.getUnnamedFaceCount();
      final processedImages = await FaceStorageService.instance.getProcessedImageCount();
      
      // Sort by face count (most faces first)
      persons.sort((a, b) => b.faceCount.compareTo(a.faceCount));
      
      setState(() {
        _persons = persons;
        _unnamedFaceCount = unnamedCount;
        _processedImages = processedImages;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading face data: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _openUnnamedFaces() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const _UnnamedFacesScreen()),
    );
    
    if (result == true) {
      _loadData(); // Refresh if changes were made
    }
  }

  Future<void> _openPersonDetail(Person person) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => _PersonDetailScreen(person: person)),
    );
    
    if (result == true) {
      _loadData(); // Refresh if changes were made
    }
  }

  Future<void> _mergePerson(Person person) async {
    // Get other persons to merge with
    final otherPersons = _persons.where((p) => p.id != person.id).toList();
    
    if (otherPersons.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other people to merge with')),
      );
      return;
    }
    
    final targetPerson = await showDialog<Person>(
      context: context,
      builder: (ctx) => _MergePersonDialog(
        sourcePerson: person,
        otherPersons: otherPersons,
      ),
    );
    
    if (targetPerson != null) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm Merge'),
          content: Text(
            'Merge "${person.name}" into "${targetPerson.name}"?\n\n'
            'All faces from "${person.name}" will be moved to "${targetPerson.name}" '
            'and "${person.name}" will be deleted.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Merge'),
            ),
          ],
        ),
      );
      
      if (confirm == true) {
        await FaceStorageService.instance.mergePersons(targetPerson.id, person.id);
        _loadData();
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Merged into ${targetPerson.name}')),
          );
        }
      }
    }
  }

  Future<void> _handleMenuAction(String action) async {
    switch (action) {
      case 'rescan':
        await _rescanAllImages();
        break;
      case 'clear_people':
        await _clearAllPeople();
        break;
      case 'clear_all':
        await _clearAllData();
        break;
    }
  }

  Future<void> _rescanAllImages() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Re-scan All Images?'),
        content: const Text(
          'This will clear all processing states and re-detect faces in all your images.\n\n'
          'This may take a while depending on how many images you have.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Re-scan'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);
    
    try {
      await FaceStorageService.instance.clearProcessingStates();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Browse your images to start re-scanning.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
    
    await _loadData();
  }

  Future<void> _clearAllPeople() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All People?'),
        content: const Text(
          'This will delete all people. Detected faces will remain unnamed.\n\n'
          'You can re-assign faces to people later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Clear People'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);
    
    try {
      final persons = await FaceStorageService.instance.getAllPersons();
      for (final person in persons) {
        await FaceStorageService.instance.deletePerson(person.id);
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All people cleared')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
    
    await _loadData();
  }

  Future<void> _clearAllData() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All Face Data?'),
        content: const Text(
          'This will delete ALL face detection data including:\n'
          '• All detected faces\n'
          '• All people\n'
          '• All processing history\n\n'
          'This cannot be undone!',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);
    
    try {
      await FaceStorageService.instance.clearAll();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All face data cleared')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
    
    await _loadData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Face Recognition'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.refreshCw),
            onPressed: _loadData,
            tooltip: 'Refresh',
          ),
          PopupMenuButton<String>(
            icon: const Icon(LucideIcons.moreVertical),
            onSelected: _handleMenuAction,
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'rescan',
                child: Row(
                  children: [
                    Icon(LucideIcons.scanFace, size: 20),
                    SizedBox(width: 12),
                    Text('Re-scan All Images'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'clear_people',
                child: Row(
                  children: [
                    Icon(LucideIcons.userMinus, size: 20),
                    SizedBox(width: 12),
                    Text('Clear All People'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'clear_all',
                child: Row(
                  children: [
                    Icon(LucideIcons.trash2, size: 20, color: Colors.red),
                    SizedBox(width: 12),
                    Text('Clear All Data', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Stats card
                Card(
                  margin: const EdgeInsets.all(16),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _StatItem(
                          icon: LucideIcons.users,
                          value: _persons.length.toString(),
                          label: 'Named',
                        ),
                        _StatItem(
                          icon: LucideIcons.helpCircle,
                          value: _unnamedFaceCount.toString(),
                          label: 'Unnamed',
                        ),
                        _StatItem(
                          icon: LucideIcons.image,
                          value: _processedImages.toString(),
                          label: 'Scanned',
                        ),
                        if (FaceDetectionService.instance.isProcessing)
                          _StatItem(
                            icon: LucideIcons.loader,
                            value: FaceDetectionService.instance.queueLength.toString(),
                            label: 'Queue',
                          ),
                      ],
                    ),
                  ),
                ),
                
                // Main list
                Expanded(
                  child: ListView(
                    children: [
                      // Unnamed Faces section - always at top
                      if (_unnamedFaceCount > 0)
                        ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                            child: const Icon(LucideIcons.users),
                          ),
                          title: const Text('Unnamed People', style: TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text('$_unnamedFaceCount face${_unnamedFaceCount == 1 ? '' : 's'} to organize'),
                          trailing: const Icon(LucideIcons.chevronRight),
                          onTap: _openUnnamedFaces,
                        ),
                      
                      if (_unnamedFaceCount > 0 && _persons.isNotEmpty)
                        const Divider(),
                      
                      // Named persons
                      if (_persons.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Text(
                            'Named People',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                        ..._persons.map((person) => _PersonTile(
                          person: person,
                          onTap: () => _openPersonDetail(person),
                          onMerge: () => _mergePerson(person),
                        )),
                      ],
                      
                      // Empty state
                      if (_unnamedFaceCount == 0 && _persons.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                LucideIcons.scanFace,
                                size: 64,
                                color: Theme.of(context).colorScheme.outline,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No faces detected yet',
                                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Browse your photos to start detecting faces',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _StatItem({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
      ],
    );
  }
}

class _PersonTile extends StatelessWidget {
  final Person person;
  final VoidCallback onTap;
  final VoidCallback onMerge;

  const _PersonTile({
    required this.person,
    required this.onTap,
    required this.onMerge,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _buildThumbnail(context),
      title: Text(person.name),
      subtitle: Text('${person.faceCount} photo${person.faceCount == 1 ? '' : 's'}'),
      trailing: PopupMenuButton<String>(
        icon: const Icon(LucideIcons.moreVertical),
        onSelected: (value) {
          if (value == 'merge') {
            onMerge();
          }
        },
        itemBuilder: (ctx) => [
          const PopupMenuItem(
            value: 'merge',
            child: Row(
              children: [
                Icon(LucideIcons.merge, size: 20),
                SizedBox(width: 12),
                Text('Merge with another person'),
              ],
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _buildThumbnail(BuildContext context) {
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
}

/// Dialog for selecting a person to merge with
class _MergePersonDialog extends StatefulWidget {
  final Person sourcePerson;
  final List<Person> otherPersons;

  const _MergePersonDialog({
    required this.sourcePerson,
    required this.otherPersons,
  });

  @override
  State<_MergePersonDialog> createState() => _MergePersonDialogState();
}

class _MergePersonDialogState extends State<_MergePersonDialog> {
  final _searchController = TextEditingController();
  List<Person> _filteredPersons = [];

  @override
  void initState() {
    super.initState();
    _filteredPersons = widget.otherPersons;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterPersons(String query) {
    if (query.isEmpty) {
      setState(() => _filteredPersons = widget.otherPersons);
    } else {
      final lower = query.toLowerCase();
      setState(() {
        _filteredPersons = widget.otherPersons
            .where((p) => p.name.toLowerCase().contains(lower))
            .toList();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Merge "${widget.sourcePerson.name}" with...'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.5,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search people...',
                prefixIcon: const Icon(LucideIcons.search),
                isDense: true,
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(LucideIcons.x, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          _filterPersons('');
                        },
                      )
                    : null,
              ),
              onChanged: _filterPersons,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _filteredPersons.isEmpty
                  ? const Center(child: Text('No matches found'))
                  : ListView.builder(
                      itemCount: _filteredPersons.length,
                      itemBuilder: (ctx, index) {
                        final p = _filteredPersons[index];
                        return ListTile(
                          leading: p.thumbnailPath != null && File(p.thumbnailPath!).existsSync()
                              ? CircleAvatar(backgroundImage: FileImage(File(p.thumbnailPath!)))
                              : CircleAvatar(child: Text(p.name.isNotEmpty ? p.name[0] : '?')),
                          title: Text(p.name),
                          subtitle: Text('${p.faceCount} face${p.faceCount == 1 ? '' : 's'}'),
                          onTap: () => Navigator.pop(context, p),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _PersonNameDialog extends StatefulWidget {
  final TextEditingController controller;
  final List<String> existingNames;
  final String currentName;
  final List<Person> persons;

  const _PersonNameDialog({
    required this.controller,
    required this.existingNames,
    required this.currentName,
    required this.persons,
  });

  @override
  State<_PersonNameDialog> createState() => _PersonNameDialogState();
}

class _PersonNameDialogState extends State<_PersonNameDialog> {
  List<Person> _suggestions = [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_updateSuggestions);
  }

  void _updateSuggestions() {
    final query = widget.controller.text.toLowerCase();
    if (query.isEmpty) {
      setState(() => _suggestions = []);
    } else {
      setState(() {
        _suggestions = widget.persons
            .where((p) => 
                p.name.toLowerCase().contains(query) && 
                p.name.toLowerCase() != widget.currentName.toLowerCase())
            .take(5)
            .toList();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Name'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: widget.controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Enter person name',
            ),
            textCapitalization: TextCapitalization.words,
          ),
          if (_suggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Existing people (tap to merge):',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 4),
            ...(_suggestions.map((p) => ListTile(
              dense: true,
              leading: const Icon(LucideIcons.user, size: 18),
              title: Text(p.name),
              subtitle: Text('${p.faceCount} photos'),
              onTap: () {
                widget.controller.text = p.name;
                Navigator.pop(context, p.name);
              },
            ))),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, widget.controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _MoveFaceDialog extends StatefulWidget {
  final DetectedFace face;
  final List<Person> otherPersons;

  const _MoveFaceDialog({
    required this.face,
    required this.otherPersons,
  });

  @override
  State<_MoveFaceDialog> createState() => _MoveFaceDialogState();
}

class _MoveFaceDialogState extends State<_MoveFaceDialog> {
  final _searchController = TextEditingController();
  List<Person> _filteredPersons = [];

  @override
  void initState() {
    super.initState();
    _filteredPersons = widget.otherPersons;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterPersons(String query) {
    if (query.isEmpty) {
      setState(() => _filteredPersons = widget.otherPersons);
    } else {
      final lower = query.toLowerCase();
      setState(() {
        _filteredPersons = widget.otherPersons
            .where((p) => p.name.toLowerCase().contains(lower))
            .toList();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Move Face To'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Show the face being moved
            if (widget.face.thumbnailPath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: CircleAvatar(
                  radius: 36,
                  backgroundImage: FileImage(File(widget.face.thumbnailPath!)),
                ),
              ),
            // Search field
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search people...',
                prefixIcon: const Icon(LucideIcons.search),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(LucideIcons.x, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          _filterPersons('');
                        },
                      )
                    : null,
              ),
              onChanged: _filterPersons,
            ),
            const SizedBox(height: 8),
            // Scrollable list of persons
            Expanded(
              child: widget.otherPersons.isEmpty
                  ? const Center(child: Text('No other people available'))
                  : _filteredPersons.isEmpty
                      ? const Center(child: Text('No matches found'))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: _filteredPersons.length,
                          itemBuilder: (ctx, index) {
                            final p = _filteredPersons[index];
                            return ListTile(
                              leading: p.thumbnailPath != null && File(p.thumbnailPath!).existsSync()
                                  ? CircleAvatar(backgroundImage: FileImage(File(p.thumbnailPath!)))
                                  : CircleAvatar(child: Text(p.name.isNotEmpty ? p.name[0] : '?')),
                              title: Text(p.name),
                              subtitle: Text('${p.faceCount} photo${p.faceCount == 1 ? '' : 's'}'),
                              onTap: () => Navigator.pop(context, p),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _PersonPhotosScreen extends StatefulWidget {
  final Person person;
  final List<String> imagePaths;

  const _PersonPhotosScreen({
    required this.person,
    required this.imagePaths,
  });

  @override
  State<_PersonPhotosScreen> createState() => _PersonPhotosScreenState();
}

class _PersonPhotosScreenState extends State<_PersonPhotosScreen> {
  List<DetectedFace> _faces = [];
  bool _isLoading = true;
  bool _showFaces = true; // Toggle between faces view and photos view

  @override
  void initState() {
    super.initState();
    _loadFaces();
  }

  Future<void> _loadFaces() async {
    final faces = await FaceStorageService.instance.getFacesForPerson(widget.person.id);
    setState(() {
      _faces = faces;
      _isLoading = false;
    });
  }

  Future<void> _moveFace(DetectedFace face) async {
    // Get all persons to choose from
    final persons = await FaceStorageService.instance.getAllPersons();
    final otherPersons = persons.where((p) => p.id != widget.person.id).toList();
    
    if (!mounted) return;
    
    final selectedPerson = await showDialog<Person>(
      context: context,
      builder: (ctx) => _MoveFaceDialog(
        face: face,
        otherPersons: otherPersons,
      ),
    );
    
    if (selectedPerson != null) {
      await FaceStorageService.instance.moveFaceToPerson(face.id, selectedPerson.id);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Face moved to ${selectedPerson.name}')),
        );
        // Refresh
        _loadFaces();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.person.name),
        actions: [
          IconButton(
            icon: Icon(_showFaces ? LucideIcons.image : LucideIcons.scanFace),
            tooltip: _showFaces ? 'Show Photos' : 'Show Faces',
            onPressed: () => setState(() => _showFaces = !_showFaces),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _showFaces
              ? _buildFacesView()
              : _buildPhotosView(),
    );
  }

  Widget _buildFacesView() {
    if (_faces.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.scanFace, size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text('No faces found', style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            )),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.8,
      ),
      itemCount: _faces.length,
      itemBuilder: (ctx, index) {
        final face = _faces[index];
        final thumbnailFile = face.thumbnailPath != null ? File(face.thumbnailPath!) : null;
        
        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onLongPress: () => _moveFace(face),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: thumbnailFile != null && thumbnailFile.existsSync()
                      ? Image.file(thumbnailFile, fit: BoxFit.cover)
                      : Container(
                          color: Colors.grey[300],
                          child: const Icon(LucideIcons.user, size: 40),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text(
                    'Long press to move',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPhotosView() {
    if (widget.imagePaths.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.imageOff, size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text('No photos found', style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            )),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: widget.imagePaths.length,
      itemBuilder: (ctx, index) {
        final path = widget.imagePaths[index];
        final file = File(path);
        
        return InkWell(
          onTap: () {
            // Navigate to image viewer if needed
          },
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
        );
      },
    );
  }
}

/// Screen for viewing and tagging unnamed faces
class _UnnamedFacesScreen extends StatefulWidget {
  const _UnnamedFacesScreen();

  @override
  State<_UnnamedFacesScreen> createState() => _UnnamedFacesScreenState();
}

class _UnnamedFacesScreenState extends State<_UnnamedFacesScreen> {
  List<DetectedFace> _faces = [];
  List<Person> _existingPersons = [];
  List<Person> _suggestions = [];
  bool _isLoading = true;
  bool _hasChanges = false;
  
  // Tagging mode state
  DetectedFace? _selectedFace;
  final Set<String> _selectedFaceIds = {};
  final _nameController = TextEditingController();
  Person? _selectedExistingPerson;

  @override
  void initState() {
    super.initState();
    _loadFaces();
    _nameController.addListener(_updateSuggestions);
  }

  @override
  void dispose() {
    _nameController.removeListener(_updateSuggestions);
    _nameController.dispose();
    super.dispose();
  }

  void _updateSuggestions() {
    final query = _nameController.text.toLowerCase().trim();
    if (query.isEmpty) {
      setState(() {
        _suggestions = [];
        _selectedExistingPerson = null;
      });
    } else {
      setState(() {
        _suggestions = _existingPersons
            .where((p) => p.name.toLowerCase().contains(query))
            .take(5)
            .toList();
        // Clear selection if text changed
        if (_selectedExistingPerson != null && 
            _selectedExistingPerson!.name != _nameController.text) {
          _selectedExistingPerson = null;
        }
      });
    }
  }

  void _selectExistingPerson(Person person) {
    setState(() {
      _selectedExistingPerson = person;
      _nameController.text = person.name;
      _suggestions = [];
    });
  }

  Future<void> _loadFaces() async {
    setState(() => _isLoading = true);
    final faces = await FaceStorageService.instance.getUnnamedFaces();
    final persons = await FaceStorageService.instance.getAllPersons();
    setState(() {
      _faces = faces;
      _existingPersons = persons;
      _isLoading = false;
    });
  }

  void _startTagging(DetectedFace face) {
    setState(() {
      _selectedFace = face;
      _selectedFaceIds.clear();
      _selectedFaceIds.add(face.id);
      _nameController.text = '';
    });
  }

  void _toggleFaceSelection(DetectedFace face) {
    if (_selectedFace == null) return;
    
    setState(() {
      if (_selectedFaceIds.contains(face.id)) {
        if (face.id != _selectedFace!.id) {
          _selectedFaceIds.remove(face.id);
        }
      } else {
        _selectedFaceIds.add(face.id);
      }
    });
  }

  void _cancelTagging() {
    setState(() {
      _selectedFace = null;
      _selectedFaceIds.clear();
      _nameController.text = '';
      _selectedExistingPerson = null;
      _suggestions = [];
    });
  }

  Future<void> _saveTaggedPerson() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a name')),
      );
      return;
    }

    if (_selectedFaceIds.isEmpty) return;

    setState(() => _isLoading = true);
    
    try {
      String message;
      
      if (_selectedExistingPerson != null) {
        // Assign faces to existing person (selected from autocomplete)
        await FaceStorageService.instance.assignFacesToPerson(
          _selectedFaceIds.toList(),
          _selectedExistingPerson!.id,
        );
        message = 'Added ${_selectedFaceIds.length} face(s) to ${_selectedExistingPerson!.name}';
      } else {
        // Check if a person with this exact name already exists
        final existingPerson = _existingPersons.firstWhere(
          (p) => p.name.toLowerCase() == name.toLowerCase(),
          orElse: () => Person(id: '', name: '', averageEmbedding: [], createdAt: DateTime.now(), updatedAt: DateTime.now(), faceCount: 0),
        );
        
        if (existingPerson.id.isNotEmpty) {
          // Person with same name exists - add faces to existing person
          await FaceStorageService.instance.assignFacesToPerson(
            _selectedFaceIds.toList(),
            existingPerson.id,
          );
          message = 'Added ${_selectedFaceIds.length} face(s) to ${existingPerson.name}';
        } else {
          // Create new person
          await FaceStorageService.instance.createNamedPerson(
            name,
            _selectedFaceIds.toList(),
          );
          message = 'Created person: $name';
        }
      }
      
      _hasChanges = true;
      _cancelTagging();
      await _loadFaces();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _selectedFace == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectedFace != null) {
          _cancelTagging();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_selectedFace != null 
              ? 'Tag Person (${_selectedFaceIds.length} selected)'
              : 'Unnamed People'),
          leading: IconButton(
            icon: const Icon(LucideIcons.arrowLeft),
            onPressed: () {
              if (_selectedFace != null) {
                _cancelTagging();
              } else {
                Navigator.pop(context, _hasChanges);
              }
            },
          ),
          actions: [
            if (_selectedFace != null)
              IconButton(
                icon: const Icon(LucideIcons.check),
                onPressed: _saveTaggedPerson,
                tooltip: 'Save Person',
              ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  // Sticky header when tagging
                  if (_selectedFace != null)
                    Container(
                      padding: const EdgeInsets.all(16),
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: Row(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Theme.of(context).colorScheme.primary,
                                width: 3,
                              ),
                            ),
                            child: CircleAvatar(
                              radius: 32,
                              backgroundImage: _selectedFace!.thumbnailPath != null
                                  ? FileImage(File(_selectedFace!.thumbnailPath!))
                                  : null,
                              child: _selectedFace!.thumbnailPath == null
                                  ? const Icon(LucideIcons.user)
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextField(
                                  controller: _nameController,
                                  decoration: InputDecoration(
                                    labelText: _selectedExistingPerson != null 
                                        ? 'Adding to existing person'
                                        : 'Person Name',
                                    hintText: 'Enter name or select existing',
                                    filled: true,
                                    prefixIcon: _selectedExistingPerson != null
                                        ? const Icon(LucideIcons.userCheck, color: Colors.green)
                                        : null,
                                  ),
                                  textCapitalization: TextCapitalization.words,
                                  autofocus: true,
                                ),
                                // Autocomplete suggestions
                                if (_suggestions.isNotEmpty)
                                  Container(
                                    margin: const EdgeInsets.only(top: 4),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.surface,
                                      borderRadius: BorderRadius.circular(8),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.1),
                                          blurRadius: 4,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: _suggestions.map((person) => InkWell(
                                        onTap: () => _selectExistingPerson(person),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          child: Row(
                                            children: [
                                              CircleAvatar(
                                                radius: 16,
                                                backgroundImage: person.thumbnailPath != null && 
                                                    File(person.thumbnailPath!).existsSync()
                                                    ? FileImage(File(person.thumbnailPath!))
                                                    : null,
                                                child: person.thumbnailPath == null
                                                    ? Text(person.name.isNotEmpty ? person.name[0] : '?')
                                                    : null,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(person.name, style: const TextStyle(fontWeight: FontWeight.w500)),
                                                    Text('${person.faceCount} face(s)', 
                                                        style: Theme.of(context).textTheme.bodySmall),
                                                  ],
                                                ),
                                              ),
                                              const Icon(LucideIcons.plus, size: 18),
                                            ],
                                          ),
                                        ),
                                      )).toList(),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  
                  if (_selectedFace != null)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        _selectedExistingPerson != null
                            ? 'Tap faces to add to "${_selectedExistingPerson!.name}"'
                            : 'Tap other faces of the same person to group them',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  
                  Expanded(
                    child: _faces.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(LucideIcons.checkCircle, size: 64, 
                                    color: Theme.of(context).colorScheme.primary),
                                const SizedBox(height: 16),
                                Text('All faces have been tagged!',
                                    style: Theme.of(context).textTheme.bodyLarge),
                              ],
                            ),
                          )
                        : GridView.builder(
                            padding: const EdgeInsets.all(8),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                            itemCount: _faces.length,
                            itemBuilder: (ctx, index) {
                              final face = _faces[index];
                              final isSelected = _selectedFaceIds.contains(face.id);
                              final thumbnailFile = face.thumbnailPath != null 
                                  ? File(face.thumbnailPath!) 
                                  : null;
                              
                              return GestureDetector(
                                onLongPress: _selectedFace == null 
                                    ? () => _startTagging(face)
                                    : null,
                                onTap: _selectedFace != null
                                    ? () => _toggleFaceSelection(face)
                                    : null,
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    border: isSelected
                                        ? Border.all(
                                            color: Theme.of(context).colorScheme.primary,
                                            width: 3,
                                          )
                                        : null,
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        thumbnailFile != null && thumbnailFile.existsSync()
                                            ? Image.file(thumbnailFile, fit: BoxFit.cover)
                                            : Container(
                                                color: Colors.grey[300],
                                                child: const Icon(LucideIcons.user, size: 40),
                                              ),
                                        if (isSelected)
                                          Container(
                                            color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                                            child: const Center(
                                              child: Icon(LucideIcons.check, color: Colors.white, size: 32),
                                            ),
                                          ),
                                        if (_selectedFace == null)
                                          Positioned(
                                            bottom: 0,
                                            left: 0,
                                            right: 0,
                                            child: Container(
                                              color: Colors.black54,
                                              padding: const EdgeInsets.all(4),
                                              child: const Text(
                                                'Long press to tag',
                                                style: TextStyle(color: Colors.white, fontSize: 10),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
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

/// Screen for viewing and managing a named person's faces
class _PersonDetailScreen extends StatefulWidget {
  final Person person;

  const _PersonDetailScreen({required this.person});

  @override
  State<_PersonDetailScreen> createState() => _PersonDetailScreenState();
}

class _PersonDetailScreenState extends State<_PersonDetailScreen> {
  List<DetectedFace> _faces = [];
  bool _isLoading = true;
  bool _hasChanges = false;
  late Person _person;

  @override
  void initState() {
    super.initState();
    _person = widget.person;
    _loadFaces();
  }

  Future<void> _loadFaces() async {
    setState(() => _isLoading = true);
    final faces = await FaceStorageService.instance.getFacesForPerson(_person.id);
    final updatedPerson = await FaceStorageService.instance.getPerson(_person.id);
    setState(() {
      _faces = faces;
      if (updatedPerson != null) _person = updatedPerson;
      _isLoading = false;
    });
  }

  Future<void> _editName() async {
    final controller = TextEditingController(text: _person.name);
    
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'Enter person name',
          ),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty && result != _person.name) {
      await FaceStorageService.instance.updatePersonName(_person.id, result);
      _hasChanges = true;
      await _loadFaces();
    }
  }

  Future<void> _removeFace(DetectedFace face) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Face?'),
        content: const Text('This face will be moved back to unnamed faces.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      await FaceStorageService.instance.removeFaceFromPerson(face.id);
      _hasChanges = true;
      await _loadFaces();
      
      final personExists = await FaceStorageService.instance.getPerson(_person.id);
      if (personExists == null && mounted) {
        Navigator.pop(context, true);
      }
    }
  }

  Future<void> _addMoreFaces() async {
    final unnamedFaces = await FaceStorageService.instance.getUnnamedFaces();
    
    if (!mounted) return;
    
    if (unnamedFaces.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No unnamed faces available')),
      );
      return;
    }
    
    final selectedFaces = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _AddFacesDialog(
        unnamedFaces: unnamedFaces,
        personName: _person.name,
      ),
    );
    
    if (selectedFaces != null && selectedFaces.isNotEmpty) {
      await FaceStorageService.instance.assignFacesToPerson(selectedFaces, _person.id);
      _hasChanges = true;
      await _loadFaces();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added ${selectedFaces.length} face(s)')),
        );
      }
    }
  }

  Future<void> _deletePerson() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Person?'),
        content: Text(
          'Delete "${_person.name}"? All faces will be moved back to unnamed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      await FaceStorageService.instance.deletePerson(_person.id);
      if (mounted) {
        Navigator.pop(context, true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_person.name),
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          onPressed: () => Navigator.pop(context, _hasChanges),
        ),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.pencil),
            onPressed: _editName,
            tooltip: 'Edit Name',
          ),
          IconButton(
            icon: const Icon(LucideIcons.userPlus),
            onPressed: _addMoreFaces,
            tooltip: 'Add Faces',
          ),
          IconButton(
            icon: const Icon(LucideIcons.trash2),
            onPressed: _deletePerson,
            tooltip: 'Delete Person',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _faces.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(LucideIcons.userX, size: 64, 
                          color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 16),
                      Text('No faces assigned',
                          style: Theme.of(context).textTheme.bodyLarge),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 0.85,
                  ),
                  itemCount: _faces.length,
                  itemBuilder: (ctx, index) {
                    final face = _faces[index];
                    final thumbnailFile = face.thumbnailPath != null 
                        ? File(face.thumbnailPath!) 
                        : null;
                    
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onLongPress: () => _removeFace(face),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: thumbnailFile != null && thumbnailFile.existsSync()
                                  ? Image.file(thumbnailFile, fit: BoxFit.cover)
                                  : Container(
                                      color: Colors.grey[300],
                                      child: const Icon(LucideIcons.user, size: 40),
                                    ),
                            ),
                            Container(
                              color: Colors.black54,
                              padding: const EdgeInsets.all(4),
                              child: const Text(
                                'Long press to remove',
                                style: TextStyle(color: Colors.white, fontSize: 10),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

/// Dialog for adding unnamed faces to a person
class _AddFacesDialog extends StatefulWidget {
  final List<DetectedFace> unnamedFaces;
  final String personName;

  const _AddFacesDialog({
    required this.unnamedFaces,
    required this.personName,
  });

  @override
  State<_AddFacesDialog> createState() => _AddFacesDialogState();
}

class _AddFacesDialogState extends State<_AddFacesDialog> {
  final Set<String> _selectedIds = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Add Faces to ${widget.personName}'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.5,
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: widget.unnamedFaces.length,
          itemBuilder: (ctx, index) {
            final face = widget.unnamedFaces[index];
            final isSelected = _selectedIds.contains(face.id);
            final thumbnailFile = face.thumbnailPath != null 
                ? File(face.thumbnailPath!) 
                : null;
            
            return GestureDetector(
              onTap: () {
                setState(() {
                  if (isSelected) {
                    _selectedIds.remove(face.id);
                  } else {
                    _selectedIds.add(face.id);
                  }
                });
              },
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: isSelected
                      ? Border.all(color: Theme.of(context).colorScheme.primary, width: 3)
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      thumbnailFile != null && thumbnailFile.existsSync()
                          ? Image.file(thumbnailFile, fit: BoxFit.cover)
                          : Container(
                              color: Colors.grey[300],
                              child: const Icon(LucideIcons.user),
                            ),
                      if (isSelected)
                        Container(
                          color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                          child: const Center(
                            child: Icon(LucideIcons.check, color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selectedIds.isEmpty 
              ? null 
              : () => Navigator.pop(context, _selectedIds.toList()),
          child: Text('Add ${_selectedIds.length} Face${_selectedIds.length == 1 ? '' : 's'}'),
        ),
      ],
    );
  }
}
