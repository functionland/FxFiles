import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/ask_ai_context.dart';
import 'package:fula_files/core/services/ai_ask_service.dart';
import 'package:fula_files/core/services/ask_ai_history_service.dart';
import 'package:fula_files/features/tags/widgets/ask_ai_history_sheet.dart';

class AskAiInputArea extends ConsumerStatefulWidget {
  final AskAiContext aiContext;

  const AskAiInputArea({
    super.key,
    required this.aiContext,
  });

  @override
  ConsumerState<AskAiInputArea> createState() => _AskAiInputAreaState();
}

class _AskAiInputAreaState extends ConsumerState<AskAiInputArea> {
  final _promptController = TextEditingController();
  bool _agreed = false;
  bool _isLoading = false;

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Read the attachment set ONCE, at submit time: the sheet rebuilds a fresh
    // context on every checkbox toggle, so re-reading it mid-flight could
    // disagree with what we actually uploaded.
    final attachments = widget.aiContext.attachments;
    final suffix = widget.aiContext.contextualPromptSuffix;

    if (attachments.isEmpty && suffix == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No context available to ask about.')),
      );
      return;
    }

    if (attachments.length > 30) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maximum 30 files are allowed for Ask AI.')),
      );
      return;
    }

    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) return;

    final finalPrompt = suffix != null ? '$prompt$suffix' : prompt;

    setState(() {
      _isLoading = true;
    });

    try {
      final result = await AiAskService.instance.askAi(
        prompt: finalPrompt,
        attachments: attachments,
      );

      if (mounted) {
        _promptController.clear();
        _showResponseBottomSheet(context, result.response);

        // The model answered about a SUBSET. Say so — silently dropping files
        // is what made the original bug invisible.
        if (result.hasSkips) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 6),
              content: Text(
                'Answered using ${result.sentCount} of '
                '${attachments.length} files. Left out: '
                '${result.skipped.map((s) => s.explanation).join(', ')}',
              ),
            ),
          );
        }

        AskAiHistoryService.instance.saveHistory(
          tagId: widget.aiContext.id,
          tagName: widget.aiContext.name,
          filenames: attachments.map((a) => a.fileName).toList(),
          prompt: prompt,
          response: result.response,
        );
      }
    } on AskAiNoFilesAttachedException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 6),
            content: Text(
              'Nothing was sent — none of the selected files could be used: '
              '${e.skipped.map((s) => s.explanation).join(', ')}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showResponseBottomSheet(BuildContext context, String text) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          builder: (context, scrollController) {
            return Container(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(LucideIcons.bot, color: Colors.purple),
                      const SizedBox(width: 8),
                      Text(
                        'AI Response',
                        style: Theme.of(context).textTheme.titleLarge,
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
                    child: SingleChildScrollView(
                      controller: scrollController,
                      child: MarkdownBody(
                        data: text,
                        selectable: true,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            offset: const Offset(0, -2),
            blurRadius: 8,
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Ask AI',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                TextButton.icon(
                  onPressed: () => AskAiHistorySheet.show(context, widget.aiContext.id),
                  icon: const Icon(LucideIcons.history, size: 16),
                  label: const Text('History'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _promptController,
              decoration: const InputDecoration(
                hintText: 'Ask AI About the files',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              maxLines: 3,
              minLines: 1,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: CheckboxListTile(
                    value: _agreed,
                    onChanged: (val) {
                      setState(() {
                        _agreed = val ?? false;
                      });
                    },
                    title: const Text(
                      'I understand that to answer questions, decrypted files will be sent to claude AI Engine',
                      style: TextStyle(fontSize: 12),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ),
                if (_agreed)
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: _isLoading
                        ? const CircularProgressIndicator()
                        : FilledButton.icon(
                            onPressed: _submit,
                            icon: const Icon(LucideIcons.bot),
                            label: const Text('Ask AI'),
                          ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
