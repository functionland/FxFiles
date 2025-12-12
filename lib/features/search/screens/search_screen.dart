import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/file_service.dart';
import 'package:fula_files/core/models/local_file.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _searchController = TextEditingController();
  List<LocalFile> _results = [];
  bool _isSearching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.isEmpty) {
      setState(() => _results = []);
      return;
    }

    setState(() => _isSearching = true);
    try {
      final results = await FileService.instance.searchFiles(query);
      setState(() {
        _results = results;
        _isSearching = false;
      });
    } catch (e) {
      setState(() => _isSearching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search files...',
            border: InputBorder.none,
          ),
          onChanged: _search,
        ),
        actions: [
          if (_searchController.text.isNotEmpty)
            IconButton(
              icon: const Icon(LucideIcons.x),
              onPressed: () {
                _searchController.clear();
                setState(() => _results = []);
              },
            ),
        ],
      ),
      body: _isSearching
          ? const Center(child: CircularProgressIndicator())
          : _results.isEmpty
              ? Center(
                  child: Text(
                    _searchController.text.isEmpty
                        ? 'Type to search'
                        : 'No results found',
                  ),
                )
              : ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final file = _results[index];
                    return ListTile(
                      leading: Icon(
                        file.isDirectory ? LucideIcons.folder : LucideIcons.file,
                      ),
                      title: Text(file.name),
                      subtitle: Text(file.path),
                    );
                  },
                ),
    );
  }
}
