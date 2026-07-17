import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/ask_ai_history.dart';
import 'package:fula_files/core/services/ask_ai_history_service.dart';

class AskAiHistorySheet extends ConsumerStatefulWidget {
  final String id;

  const AskAiHistorySheet({
    super.key,
    required this.id,
  });

  static void show(BuildContext context, String id) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          builder: (context, scrollController) {
            return AskAiHistorySheet(id: id);
          },
        );
      },
    );
  }

  @override
  ConsumerState<AskAiHistorySheet> createState() => _AskAiHistorySheetState();
}

class _AskAiHistorySheetState extends ConsumerState<AskAiHistorySheet> {
  List<AskAiHistory> _history = [];
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _loadLocal();
    _syncCloud();
  }

  void _loadLocal() {
    setState(() {
      _history = AskAiHistoryService.instance.getHistoryForTag(widget.id);
    });
  }

  Future<void> _syncCloud() async {
    setState(() => _isSyncing = true);
    await AskAiHistoryService.instance.syncHistoryForTag(widget.id);
    if (mounted) {
      _loadLocal();
      setState(() => _isSyncing = false);
    }
  }
  
  Future<void> _delete(AskAiHistory item) async {
    await AskAiHistoryService.instance.deleteHistory(item.id);
    _loadLocal();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(LucideIcons.history, color: Colors.purple),
              const SizedBox(width: 8),
              Text(
                'AI Chat History',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(width: 12),
              if (_isSyncing)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const Spacer(),
              IconButton(
                icon: const Icon(LucideIcons.x),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const Divider(),
          Expanded(
            child: _history.isEmpty
                ? const Center(child: Text('No history found.'))
                : ListView.builder(
                    itemCount: _history.length,
                    itemBuilder: (context, index) {
                      final item = _history[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ExpansionTile(
                          title: Text(
                            item.prompt,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(item.createdAt.toString().split('.')[0]),
                          childrenPadding: const EdgeInsets.all(16),
                          expandedCrossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(
                              item.response,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Files context: ${item.filenames.length}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                TextButton.icon(
                                  onPressed: () => _delete(item),
                                  icon: const Icon(LucideIcons.trash2, size: 16),
                                  label: const Text('Delete'),
                                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
