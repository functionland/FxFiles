import 'package:flutter/material.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/ask_ai_context.dart';
import 'package:fula_files/features/tags/widgets/ask_ai_input_area.dart';

class TagAskAiSheet extends StatefulWidget {
  final FileTag tag;
  final List<TaggedFile> availableFiles;

  const TagAskAiSheet({
    super.key,
    required this.tag,
    required this.availableFiles,
  });

  static void show(BuildContext context, FileTag tag, List<TaggedFile> availableFiles) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: TagAskAiSheet(tag: tag, availableFiles: availableFiles),
        );
      },
    );
  }

  @override
  State<TagAskAiSheet> createState() => _TagAskAiSheetState();
}

class _TagAskAiSheetState extends State<TagAskAiSheet> {
  final Set<String> _selectedFileIds = {};

  @override
  void initState() {
    super.initState();
    // By default, select all files
    for (var f in widget.availableFiles) {
      _selectedFileIds.add(f.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedFiles = widget.availableFiles
        .where((f) => _selectedFileIds.contains(f.id))
        .toList();

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                Text(
                  'Select files to include in context',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.availableFiles.length,
              itemBuilder: (context, index) {
                final file = widget.availableFiles[index];
                final isSelected = _selectedFileIds.contains(file.id);
                return CheckboxListTile(
                  value: isSelected,
                  title: Text(file.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onChanged: (val) {
                    setState(() {
                      if (val == true) {
                        _selectedFileIds.add(file.id);
                      } else {
                        _selectedFileIds.remove(file.id);
                      }
                    });
                  },
                );
              },
            ),
          ),
          const Divider(),
          AskAiInputArea(
            aiContext: TagAskAiContext(widget.tag, selectedFiles),
          ),
        ],
      ),
    );
  }
}
