import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:fula_files/core/models/ai_task.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/services/ai_model_service.dart';
import 'package:fula_files/core/services/ai_task_service.dart';
import 'package:fula_files/core/services/device_memory_service.dart';
import 'package:fula_files/core/services/local_llm_service.dart';
import 'package:fula_files/core/services/tabular_parser.dart';
import 'package:fula_files/features/ai_tasks/providers/ai_model_provider.dart';
import 'package:fula_files/features/ai_tasks/widgets/legal_disclaimer_dialog.dart';
import 'package:fula_files/features/ai_tasks/widgets/model_download_card.dart';
import 'package:fula_files/features/ai_tasks/widgets/target_app_picker.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';

/// Configure + run an AI task. Mirrors `WebsiteDetailScreen` for the asset
/// import flow but with the CRM-specific task config (target app + prompt)
/// instead of style/palette/category pickers.
class AiTaskDetailScreen extends ConsumerStatefulWidget {
  final String tagId;
  final FileTag? tag;

  const AiTaskDetailScreen({super.key, required this.tagId, this.tag});

  @override
  ConsumerState<AiTaskDetailScreen> createState() => _AiTaskDetailScreenState();
}

class _AiTaskDetailScreenState extends ConsumerState<AiTaskDetailScreen> {
  final _promptController = TextEditingController();
  TargetApp _targetApp = TargetApp.whatsapp;
  bool _isRunning = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadTask();
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _loadTask() async {
    final tagState = ref.read(tagProvider);
    final currentTag =
        widget.tag ?? tagState.tags.where((t) => t.id == widget.tagId).firstOrNull;
    final tagName = currentTag?.name ?? widget.tagId;
    final task = await AiTaskService.instance.getOrCreate(
      tagId: widget.tagId,
      tagName: tagName,
    );
    if (!mounted) return;
    setState(() {
      _targetApp = task.targetApp;
      _promptController.text = task.userPrompt;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tagState = ref.watch(tagProvider);
    final currentTag =
        widget.tag ?? tagState.tags.where((t) => t.id == widget.tagId).firstOrNull;
    final displayName =
        (currentTag?.name ?? 'AI Task').replaceFirst('ai-tasks-', '');
    final color = currentTag != null ? Color(currentTag.colorValue) : Colors.indigo;
    final taggedFilesAsync = ref.watch(taggedFilesProvider(widget.tagId));

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(displayName),
          ],
        ),
      ),
      body: ListView(
        children: [
          const ModelDownloadCard(),
          _section(
            context,
            title: 'Attached files',
            trailing: IconButton(
              icon: const Icon(LucideIcons.filePlus, size: 18),
              tooltip: 'Import file',
              onPressed: _pickCsvFile,
            ),
          ),
          taggedFilesAsync.when(
            data: (files) => files.isEmpty
                ? _emptyAssetState()
                : Column(
                    children: [
                      for (final f in files)
                        ListTile(
                          leading:
                              const Icon(LucideIcons.fileSpreadsheet, size: 22),
                          title: Text(f.fileName,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: f.localPath == null
                              ? const Text('Not available locally',
                                  style:
                                      TextStyle(fontSize: 11, color: Colors.grey))
                              : null,
                          trailing: IconButton(
                            icon: const Icon(LucideIcons.x, size: 18),
                            tooltip: 'Remove',
                            onPressed: () => _removeFile(f),
                          ),
                        ),
                    ],
                  ),
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error loading attached files: $e'),
            ),
          ),
          const Divider(),
          _section(context, title: 'Task type'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: _TaskTypeCard(),
          ),
          _section(context, title: 'Send via'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: TargetAppPicker(
              selected: _targetApp,
              onSelected: (t) => setState(() => _targetApp = t),
            ),
          ),
          _section(context, title: 'Prompt'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _promptController,
              maxLines: 5,
              minLines: 3,
              decoration: const InputDecoration(
                hintText:
                    'e.g. "Send Hello {Name}, hope you are well to each row." '
                    'Use {ColumnName} placeholders matching your CSV headers.',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
          ),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(LucideIcons.alertCircle,
                        size: 18, color: Colors.red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            child: FilledButton.icon(
              onPressed: _isRunning ? null : _runTask,
              icon: _isRunning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(LucideIcons.play),
              label: Text(_isRunning ? 'Preparing…' : 'Run task'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(BuildContext context,
      {required String title, Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
      child: Row(
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const Spacer(),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _emptyAssetState() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          children: [
            Icon(LucideIcons.fileX, size: 36, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(
              'No CSV attached',
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'v1 only reads CSV — export from Excel/Numbers/Sheets first',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _pickCsvFile,
              icon: const Icon(LucideIcons.filePlus, size: 16),
              label: const Text('Import CSV'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickCsvFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv'],
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.first;
      if (picked.path == null) return;

      // Copy into the app sandbox so we have a stable path that survives
      // platform sandbox migrations. Same pattern as
      // WebsiteDetailScreen._importPickedFiles.
      final appDir = await getApplicationDocumentsDirectory();
      final importedDir = Directory(p.join(appDir.path, 'Imported'));
      if (!await importedDir.exists()) {
        await importedDir.create(recursive: true);
      }
      var destName = picked.name;
      var destPath = p.join(importedDir.path, destName);
      var counter = 1;
      while (await File(destPath).exists()) {
        final base = p.basenameWithoutExtension(picked.name);
        final ext = p.extension(picked.name);
        destName = '$base ($counter)$ext';
        destPath = p.join(importedDir.path, destName);
        counter++;
      }
      await File(picked.path!).copy(destPath);
      final storedPath = Platform.isIOS ? 'Imported/$destName' : destPath;
      await ref.tagFile(
        tagId: widget.tagId,
        localPath: storedPath,
        fileName: destName,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to import file: $e')),
        );
      }
    }
  }

  Future<void> _removeFile(TaggedFile file) async {
    await ref.untagFile(
      tagId: widget.tagId,
      localPath: file.localPath,
      remoteKey: file.remoteKey,
      iosAssetId: file.iosAssetId,
    );
  }

  Future<void> _runTask() async {
    setState(() => _errorMessage = null);

    // 1. Confirm the legal disclaimer.
    final confirmed = await showAiAutomationDisclaimer(context);
    if (!confirmed || !mounted) return;

    setState(() => _isRunning = true);
    String? fallbackBanner;
    try {
      final memSvc = DeviceMemoryService.instance;
      final useHeuristicOnly = !memSvc.supportsOnDeviceLlm;

      // 2. Ensure the model is ready (or kick off the download), but
      // only on devices that can actually host the LLM. Insufficient
      // devices skip straight to the heuristic-only path.
      if (!useHeuristicOnly && !await AiModelService.instance.isReady()) {
        await AiModelService.instance.startDownload();
        final ev = ref.read(aiModelStatusProvider).value;
        if (ev?.status != AiModelStatus.ready) {
          throw Exception(
              'Model is not ready yet. Wait for the download to finish.');
        }
      }

      // 3. Locate the first attached CSV.
      final files = await ref.read(taggedFilesProvider(widget.tagId).future);
      final csv = files.firstWhere(
        (f) => (f.localPath ?? '').toLowerCase().endsWith('.csv'),
        orElse: () => throw Exception('Attach a CSV file first.'),
      );
      final localPath = await _resolveLocalPath(csv.localPath!);
      final file = File(localPath);
      if (!await file.exists()) {
        throw Exception('Attached CSV not found on disk');
      }

      // 4. Parse the CSV.
      final tabular = await TabularParser.parse(file);
      if (tabular.isEmpty) {
        throw Exception('CSV has no data rows.');
      }

      // 5. Build the prompt + run the LLM (or fall back to heuristics).
      // Three failure modes that all degrade to the same heuristic path:
      //  - Device tier too low (LowMemoryException, or pre-flagged
      //    by useHeuristicOnly)
      //  - LLM output unparseable (TemplateInferenceFailure)
      // In each case we still ship a working bulk-send — the user just
      // sees their prompt used verbatim as the template.
      final samples = tabular.rows.take(3).toList();
      InferredCrmTemplate template;
      if (useHeuristicOnly) {
        template = _heuristicFallback(tabular.headers);
        fallbackBanner =
            'AI parsing is disabled on this device — using your prompt as '
            'the message template. {ColumnName} placeholders will still be '
            'substituted per row.';
      } else {
        try {
          template = await LocalLlmService.instance.inferTemplate(
            headers: tabular.headers,
            samples: samples,
            prompt: _promptController.text.trim(),
          );
        } on LowMemoryException catch (_) {
          template = _heuristicFallback(tabular.headers);
          fallbackBanner =
              'Your device is low on memory right now — AI parsing skipped, '
              'using your prompt as the literal template.';
        } on TemplateInferenceFailure catch (_) {
          template = _heuristicFallback(tabular.headers);
          fallbackBanner =
              'AI parsing didn\'t return a usable result — using your '
              'prompt as the literal template.';
        }
      }

      // 6. Build the SendPlanRow list — deterministic substitution.
      final rows = <SendPlanRow>[];
      for (final row in tabular.rows) {
        final recipient = (row[template.recipientColumn] ?? '').trim();
        final name = template.nameColumn != null
            ? (row[template.nameColumn] ?? '').trim()
            : null;
        final message = _renderTemplate(template.perRowTemplate, row);
        rows.add(SendPlanRow(
          recipient: recipient,
          displayName: name == null || name.isEmpty ? null : name,
          message: message,
          status: recipient.isEmpty ? SendStatus.failed : SendStatus.pending,
          failureReason:
              recipient.isEmpty ? 'Recipient column is empty' : null,
        ));
      }

      // 7. Persist on the AiTask record.
      final task = await AiTaskService.instance.getOrCreate(
        tagId: widget.tagId,
        tagName: 'ai-tasks-${_promptController.text}',
      );
      task.userPrompt = _promptController.text.trim();
      task.targetApp = _targetApp;
      task.renderedTemplate = template.perRowTemplate;
      task.recipientColumn = template.recipientColumn;
      task.nameColumn = template.nameColumn;
      task.rows = rows;
      await AiTaskService.instance.save(task);

      // 8. Surface the fallback banner if we ended up on the heuristic
      // path, then hand off to the run screen.
      if (!mounted) return;
      if (fallbackBanner != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(fallbackBanner),
            duration: const Duration(seconds: 6),
          ),
        );
      }
      context.push('/ai-tasks/${widget.tagId}/run');
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = e.toString());
      }
    } finally {
      if (mounted) setState(() => _isRunning = false);
    }
  }

  /// Mirrors WebsiteDetailScreen's path-resolution helper: turn a stored
  /// path (which may be a Documents-relative path on iOS) into a usable
  /// absolute path on the current sandbox.
  Future<String> _resolveLocalPath(String path) async {
    if (path.startsWith('/') || (Platform.isWindows && path.length > 2)) {
      return path;
    }
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, path);
  }

  /// Heuristic fallback when the LLM produces unusable output. Used in
  /// place of the manual-editor sheet for v1.
  InferredCrmTemplate _heuristicFallback(List<String> headers) {
    String? recipient;
    final phoneRe = RegExp(r'phone|mobile|cell|tel', caseSensitive: false);
    final emailRe = RegExp('email|mail', caseSensitive: false);
    final preferEmail = _targetApp == TargetApp.email;
    for (final h in headers) {
      if (preferEmail && emailRe.hasMatch(h)) {
        recipient = h;
        break;
      }
      if (!preferEmail && phoneRe.hasMatch(h)) {
        recipient = h;
        break;
      }
    }
    recipient ??= headers.firstWhere(
      (_) => true,
      orElse: () => headers.first,
    );
    String? name;
    final nameRe = RegExp('name', caseSensitive: false);
    for (final h in headers) {
      if (nameRe.hasMatch(h)) {
        name = h;
        break;
      }
    }
    return InferredCrmTemplate(
      perRowTemplate: _promptController.text.trim(),
      recipientColumn: recipient,
      nameColumn: name,
      fromFallback: true,
    );
  }

  String _renderTemplate(String template, Map<String, String> row) {
    // Substitute `{Column}` and `{column}` matches (case-insensitive).
    return template.replaceAllMapped(RegExp(r'\{([^{}]+)\}'), (m) {
      final key = m.group(1)!;
      // Exact match first, then case-insensitive.
      if (row.containsKey(key)) return row[key]!;
      for (final entry in row.entries) {
        if (entry.key.toLowerCase() == key.toLowerCase()) {
          return entry.value;
        }
      }
      return m.group(0)!;
    });
  }
}

class _TaskTypeCard extends StatelessWidget {
  const _TaskTypeCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.primary, width: 2),
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.userPlus, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('CRM Automation',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text(
                  'Attach a CSV with one recipient per row. The AI extracts a '
                  'message template and column mapping; you approve each '
                  'message before it sends.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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
