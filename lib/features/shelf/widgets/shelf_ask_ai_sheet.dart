import 'package:flutter/material.dart';
import 'package:fula_files/core/models/shelf_item.dart';
import 'package:fula_files/core/models/ask_ai_context.dart';
import 'package:fula_files/features/tags/widgets/ask_ai_input_area.dart';

class ShelfAskAiSheet extends StatelessWidget {
  final ShelfItem item;

  const ShelfAskAiSheet({super.key, required this.item});

  static void show(BuildContext context, ShelfItem item) {
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
          child: ShelfAskAiSheet(item: item),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
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
          AskAiInputArea(
            aiContext: ShelfAskAiContext(item),
          ),
        ],
      ),
    );
  }
}
