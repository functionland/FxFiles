import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/models/fula_object.dart';

class FulaBrowserScreen extends StatefulWidget {
  final String? bucket;
  final String? prefix;

  const FulaBrowserScreen({super.key, this.bucket, this.prefix});

  @override
  State<FulaBrowserScreen> createState() => _FulaBrowserScreenState();
}

class _FulaBrowserScreenState extends State<FulaBrowserScreen> {
  List<FulaObject> _objects = [];
  List<String> _buckets = [];
  String? _currentBucket;
  String _currentPrefix = '';
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currentBucket = widget.bucket;
    _currentPrefix = widget.prefix ?? '';
    _loadData();
  }

  Future<void> _loadData() async {
    if (!FulaApiService.instance.isConfigured) {
      setState(() {
        _isLoading = false;
        _error = 'Fula API not configured. Go to Settings to configure.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      if (_currentBucket == null) {
        _buckets = await FulaApiService.instance.listBuckets();
        setState(() => _isLoading = false);
      } else {
        _objects = await FulaApiService.instance.listObjects(
          _currentBucket!,
          prefix: _currentPrefix,
        );
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  void _selectBucket(String bucket) {
    setState(() {
      _currentBucket = bucket;
      _currentPrefix = '';
    });
    _loadData();
  }

  void _navigateTo(FulaObject obj) {
    if (obj.isDirectory) {
      setState(() => _currentPrefix = obj.key);
      _loadData();
    }
  }

  void _navigateUp() {
    if (_currentPrefix.isEmpty) {
      setState(() => _currentBucket = null);
    } else {
      final parts = _currentPrefix.split('/');
      parts.removeLast();
      if (parts.isNotEmpty) parts.removeLast();
      setState(() => _currentPrefix = parts.isEmpty ? '' : '${parts.join('/')}/');
    }
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentBucket ?? 'Fula Cloud'),
        actions: [
          if (_currentBucket != null)
            IconButton(
              icon: const Icon(LucideIcons.folderUp),
              onPressed: _navigateUp,
            ),
          IconButton(
            icon: const Icon(LucideIcons.refreshCw),
            onPressed: _loadData,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!, textAlign: TextAlign.center));
    }
    if (_currentBucket == null) {
      return _buildBucketList();
    }
    return _buildObjectList();
  }

  Widget _buildBucketList() {
    if (_buckets.isEmpty) {
      return const Center(child: Text('No buckets found'));
    }
    return ListView.builder(
      itemCount: _buckets.length,
      itemBuilder: (context, index) {
        final bucket = _buckets[index];
        return ListTile(
          leading: const Icon(LucideIcons.database),
          title: Text(bucket),
          onTap: () => _selectBucket(bucket),
        );
      },
    );
  }

  Widget _buildObjectList() {
    if (_objects.isEmpty) {
      return const Center(child: Text('Empty'));
    }
    return ListView.builder(
      itemCount: _objects.length,
      itemBuilder: (context, index) {
        final obj = _objects[index];
        return ListTile(
          leading: Icon(obj.isDirectory ? LucideIcons.folder : LucideIcons.file),
          title: Text(obj.name),
          subtitle: Text(obj.isDirectory ? 'Folder' : obj.sizeFormatted),
          onTap: () => _navigateTo(obj),
        );
      },
    );
  }
}
