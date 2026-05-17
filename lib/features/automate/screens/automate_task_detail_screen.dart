import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/messaging_target.dart';
import 'package:fula_files/core/services/automate_task_service.dart';
import 'package:fula_files/core/services/ipfs_gateway_helper.dart';
import 'package:fula_files/core/services/ipfs_public_service.dart';
import 'package:fula_files/core/services/tabular_parser.dart';
import 'package:fula_files/core/utils/target_uri_builder.dart';
import 'package:fula_files/core/utils/template_renderer.dart';
import 'package:fula_files/features/automate/widgets/placeholder_chip_bar.dart';
import 'package:fula_files/features/tags/providers/tag_provider.dart';
import 'package:fula_files/features/websites/widgets/legal_disclaimer_dialog.dart'
    as ipfs_warning;
import 'package:fula_files/shared/widgets/legal_disclaimer_dialog.dart';
import 'package:fula_files/shared/widgets/target_app_picker.dart';

/// Configure + run an Automate task. Deterministic bulk-send: attach a
/// CSV, the headers become placeholder chips, the user composes a TO
/// template + message template (+ optional subject for email) using
/// those chips or by typing `{ColumnName}` manually.
///
/// No LLM — `TemplateRenderer.render` substitutes verbatim per row.
class AutomateTaskDetailScreen extends ConsumerStatefulWidget {
  final String tagId;
  final FileTag? tag;

  const AutomateTaskDetailScreen({super.key, required this.tagId, this.tag});

  @override
  ConsumerState<AutomateTaskDetailScreen> createState() =>
      _AutomateTaskDetailScreenState();
}

class _AutomateTaskDetailScreenState
    extends ConsumerState<AutomateTaskDetailScreen> {
  final _toController = TextEditingController();
  final _messageController = TextEditingController();
  final _subjectController = TextEditingController();

  final _toFocus = FocusNode();
  final _messageFocus = FocusNode();
  final _subjectFocus = FocusNode();

  TargetApp _targetApp = TargetApp.whatsapp;
  bool _isRunning = false;
  String? _errorMessage;
  List<String> _headers = const [];

  // Attachment state. The file is picked locally now and held here +
  // persisted on the task; it's NOT uploaded to IPFS until the user
  // taps Run (per the design choice — keeps the IPFS warning tied to
  // the explicit send action).
  String? _attachmentLocalPath;
  String? _attachmentFileName;
  String? _attachmentCid;

  /// Run-time progress string for the IPFS upload phase. null when not
  /// uploading; otherwise something like "Uploading attachment to IPFS…".
  String? _uploadStatus;

  @override
  void initState() {
    super.initState();
    _loadTask();
  }

  @override
  void dispose() {
    _toController.dispose();
    _messageController.dispose();
    _subjectController.dispose();
    _toFocus.dispose();
    _messageFocus.dispose();
    _subjectFocus.dispose();
    super.dispose();
  }

  Future<void> _loadTask() async {
    final tagState = ref.read(tagProvider);
    final currentTag = widget.tag ??
        tagState.tags.where((t) => t.id == widget.tagId).firstOrNull;
    final tagName = currentTag?.name ?? widget.tagId;
    final task = await AutomateTaskService.instance.getOrCreate(
      tagId: widget.tagId,
      tagName: tagName,
    );
    if (!mounted) return;
    setState(() {
      _targetApp = task.targetApp;
      _toController.text = task.toFieldTemplate;
      _messageController.text = task.messageTemplate;
      _subjectController.text = task.subjectTemplate ?? '';
      _attachmentLocalPath = task.attachmentLocalPath;
      _attachmentFileName = task.attachmentFileName;
      _attachmentCid = task.attachmentCid;
    });
    // Re-parse the attached CSV so placeholder chips populate without a
    // user action.
    await _refreshHeaders();
  }

  Future<void> _refreshHeaders() async {
    try {
      final files = await ref.read(taggedFilesProvider(widget.tagId).future);
      final csv = files
          .where((f) => (f.localPath ?? '').toLowerCase().endsWith('.csv'))
          .firstOrNull;
      if (csv == null || csv.localPath == null) {
        if (mounted) setState(() => _headers = const []);
        return;
      }
      final localPath = await _resolveLocalPath(csv.localPath!);
      final file = File(localPath);
      if (!await file.exists()) {
        if (mounted) setState(() => _headers = const []);
        return;
      }
      final tabular = await TabularParser.parse(file);
      if (mounted) setState(() => _headers = tabular.headers);
    } catch (e) {
      // Non-fatal — leave headers empty; the chip bar shows a hint
      // telling the user to attach a CSV.
      debugPrint('AutomateTaskDetail: header refresh failed: $e');
      if (mounted) setState(() => _headers = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tagState = ref.watch(tagProvider);
    final currentTag = widget.tag ??
        tagState.tags.where((t) => t.id == widget.tagId).firstOrNull;
    final displayName = (currentTag?.name ?? 'Automate task')
        .replaceFirst('automate-tasks-', '');
    final color =
        currentTag != null ? Color(currentTag.colorValue) : Colors.indigo;
    final taggedFilesAsync = ref.watch(taggedFilesProvider(widget.tagId));

    final isEmail = _targetApp == TargetApp.email;

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
          _section(
            context,
            title: 'Attached CSV',
            trailing: IconButton(
              icon: const Icon(LucideIcons.filePlus, size: 18),
              tooltip: 'Import CSV',
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
                          leading: const Icon(LucideIcons.fileSpreadsheet,
                              size: 22),
                          title: Text(f.fileName,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: f.localPath == null
                              ? const Text('Not available locally',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.grey))
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
          _section(context, title: 'Send via'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: TargetAppPicker(
              selected: _targetApp,
              onSelected: (t) => setState(() => _targetApp = t),
            ),
          ),
          _section(
            context,
            title: 'Attachment (optional)',
            trailing: _attachmentLocalPath == null
                ? IconButton(
                    icon: const Icon(LucideIcons.paperclip, size: 18),
                    tooltip: 'Attach file',
                    onPressed: _pickAttachment,
                  )
                : null,
          ),
          _attachmentCard(),
          _section(context, title: 'Placeholders'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: PlaceholderChipBar(
              headers: _headers,
              extraChips: _attachmentLocalPath != null ? const ['File'] : const [],
              fields: [
                PlaceholderField(
                  focusNode: _toFocus,
                  controller: _toController,
                  label: 'TO',
                ),
                PlaceholderField(
                  focusNode: _messageFocus,
                  controller: _messageController,
                  label: 'message',
                ),
                if (isEmail)
                  PlaceholderField(
                    focusNode: _subjectFocus,
                    controller: _subjectController,
                    label: 'subject',
                  ),
              ],
            ),
          ),
          _section(
            context,
            title: isEmail ? 'TO (email address)' : 'TO',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _toController,
              focusNode: _toFocus,
              decoration: InputDecoration(
                hintText: isEmail
                    ? '{Email}'
                    : 'e.g. +1{Phone} — or {Phone} if your column has the country code',
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (isEmail) ...[
            _section(context, title: 'Subject'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _subjectController,
                focusNode: _subjectFocus,
                decoration: const InputDecoration(
                  hintText: 'e.g. Hi {Name}, quick question',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
          _section(context, title: 'Message'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _messageController,
              focusNode: _messageFocus,
              maxLines: 6,
              minLines: 3,
              decoration: const InputDecoration(
                hintText: 'e.g. Hello {Name}, hope you are well!',
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
                  border:
                      Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(LucideIcons.alertCircle,
                        size: 18, color: Colors.red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(
                            color: Colors.red, fontSize: 13),
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
              label: Text(_isRunning
                  ? (_uploadStatus ?? 'Preparing…')
                  : 'Run task'),
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
              'v1 only reads CSV — export from Excel / Numbers / Sheets first',
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
      // WebsiteDetailScreen._importPickedFiles and AI flow.
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
      // Re-parse so chips appear without the user navigating away/back.
      await _refreshHeaders();
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
    await _refreshHeaders();
  }

  /// Attachment file picker. Accepts ANY file type — IPFS doesn't care
  /// about content; the recipient's link-handler does. The file is
  /// copied into the app sandbox (same pattern as CSV import) so the
  /// path is stable across platform sandbox migrations. NO IPFS upload
  /// happens here — that's deferred to Run time, when the user has
  /// committed to actually sending the message.
  Future<void> _pickAttachment() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        // withData=false so large files don't load fully into memory.
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.first;
      if (picked.path == null) return;

      final appDir = await getApplicationDocumentsDirectory();
      final attachDir = Directory(p.join(appDir.path, 'AutomateAttachments'));
      if (!await attachDir.exists()) {
        await attachDir.create(recursive: true);
      }
      var destName = picked.name;
      var destPath = p.join(attachDir.path, destName);
      var counter = 1;
      while (await File(destPath).exists()) {
        final base = p.basenameWithoutExtension(picked.name);
        final ext = p.extension(picked.name);
        destName = '$base ($counter)$ext';
        destPath = p.join(attachDir.path, destName);
        counter++;
      }
      await File(picked.path!).copy(destPath);
      final storedPath =
          Platform.isIOS ? 'AutomateAttachments/$destName' : destPath;

      // Persist immediately so a quick app-restart doesn't lose it.
      final task = await AutomateTaskService.instance.getOrCreate(
        tagId: widget.tagId,
        tagName: widget.tag?.name ?? widget.tagId,
      );
      task.attachmentLocalPath = storedPath;
      task.attachmentFileName = destName;
      // Picking a different attachment invalidates any previous IPFS
      // upload — the CID belongs to the old bytes.
      task.attachmentCid = null;
      await AutomateTaskService.instance.save(task);

      if (!mounted) return;
      setState(() {
        _attachmentLocalPath = storedPath;
        _attachmentFileName = destName;
        _attachmentCid = null;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to attach file: $e')),
        );
      }
    }
  }

  Future<void> _removeAttachment() async {
    final task = await AutomateTaskService.instance.getOrCreate(
      tagId: widget.tagId,
      tagName: widget.tag?.name ?? widget.tagId,
    );
    task.attachmentLocalPath = null;
    task.attachmentFileName = null;
    task.attachmentCid = null;
    await AutomateTaskService.instance.save(task);
    if (!mounted) return;
    setState(() {
      _attachmentLocalPath = null;
      _attachmentFileName = null;
      _attachmentCid = null;
    });
  }

  Widget _attachmentCard() {
    final theme = Theme.of(context);
    if (_attachmentLocalPath == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          'Attach a file to share via IPFS. Once attached, a {File} chip '
          'appears — drop it into your message wherever you want the link.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    final urlPreview = _attachmentCid != null
        ? IpfsGatewayHelper.buildUrlForCid(_attachmentCid!)
        : 'Will upload to IPFS on Run';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.paperclip,
                size: 18, color: theme.colorScheme.tertiary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _attachmentFileName ?? '(file)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    urlPreview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(LucideIcons.x, size: 18),
              tooltip: 'Remove attachment',
              onPressed: _removeAttachment,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runTask() async {
    setState(() => _errorMessage = null);

    // Basic validation before opening the disclaimer — saves the user
    // tapping through it just to see an inline error.
    if (_toController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'TO field is empty');
      return;
    }
    if (_messageController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'Message is empty');
      return;
    }

    final confirmed = await showBulkSendDisclaimer(context);
    if (!confirmed || !mounted) return;

    setState(() => _isRunning = true);
    try {
      // ----- Attachment upload (if needed) -----
      // The {File} placeholder resolves to the IPFS gateway URL of the
      // uploaded attachment. Upload happens at Run (not at attach time)
      // so the IPFS-public warning is tied to the explicit "send"
      // action. CID is cached on the task — repeat Runs of the same
      // file skip re-uploading.
      String? attachmentUrl;
      if (_attachmentLocalPath != null) {
        if (_attachmentCid == null) {
          // First time uploading this file. Get IPFS-public consent
          // (the same dialog the website-generation flow shows when
          // pinning files to IPFS) — different from the bulk-send
          // click-to-chat disclaimer we just showed above.
          final ipfsOk = await ipfs_warning.showLegalDisclaimerDialog(context);
          if (ipfsOk != true) {
            // User declined the IPFS warning — abort run; don't send
            // ANY rows (the attachment is required for the {File}
            // placeholder to resolve correctly).
            return;
          }
          setState(() =>
              _uploadStatus = 'Uploading attachment to IPFS…');
          final attachAbs = await _resolveLocalPath(_attachmentLocalPath!);
          final result = await IpfsPublicService.instance
              .pinFile(attachAbs, _attachmentFileName ?? 'file');
          _attachmentCid = result.cid;
          setState(() => _uploadStatus = null);

          // Persist the CID immediately so a crash here doesn't make
          // the user re-upload on the next Run.
          final t0 = await AutomateTaskService.instance.getOrCreate(
            tagId: widget.tagId,
            tagName: widget.tag?.name ?? widget.tagId,
          );
          t0.attachmentCid = _attachmentCid;
          await AutomateTaskService.instance.save(t0);
        }
        attachmentUrl = IpfsGatewayHelper.buildUrlForCid(_attachmentCid!);
      }

      // Locate the attached CSV.
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

      final tabular = await TabularParser.parse(file);
      if (tabular.isEmpty) {
        throw Exception('CSV has no data rows.');
      }

      final toTpl = _toController.text;
      final msgTpl = _messageController.text;
      final subjectTpl =
          _targetApp == TargetApp.email && _subjectController.text.isNotEmpty
              ? _subjectController.text
              : null;

      // Build the per-row send plan via deterministic substitution.
      // When an attachment is set, we inject `{File}` (and the lowercase
      // alias `{file}`) into the render row alongside the CSV columns —
      // TemplateRenderer matches case-insensitively so either works in
      // the template.
      final rows = <SendPlanRow>[];
      for (final row in tabular.rows) {
        final renderRow = attachmentUrl != null
            ? {...row, 'File': attachmentUrl}
            : row;
        final renderedTo =
            TemplateRenderer.render(toTpl, renderRow).trim();
        final renderedMsg = TemplateRenderer.render(msgTpl, renderRow);

        // Pre-validate the recipient at substitution time. For
        // phone-based targets, normalizePhone() is the same check the
        // URI builder will run; doing it here means the user sees the
        // failures in the run-screen preview list before tapping Open.
        String? failureReason;
        if (renderedTo.isEmpty) {
          failureReason = 'TO field rendered to empty';
        } else if (_targetApp == TargetApp.whatsapp ||
            _targetApp == TargetApp.sms) {
          if (TargetUriBuilder.normalizePhone(renderedTo) == null) {
            failureReason = 'Phone is invalid: $renderedTo';
          }
        } else if (_targetApp == TargetApp.telegram) {
          if (!renderedTo.startsWith('@') &&
              TargetUriBuilder.normalizePhone(renderedTo) == null) {
            failureReason =
                'Telegram needs an @handle or phone: $renderedTo';
          }
        }

        rows.add(SendPlanRow(
          recipient: renderedTo,
          // Message preview in the run screen uses this as the row
          // label. Try to surface the first {name}-like column if it
          // exists, fall back to the recipient itself.
          displayName: _displayNameFor(row),
          message: renderedMsg,
          status: failureReason == null
              ? SendStatus.pending
              : SendStatus.failed,
          failureReason: failureReason,
        ));
      }

      // Persist on the AutomateTask record. attachmentLocalPath /
      // attachmentFileName were already persisted at attach time;
      // attachmentCid was just persisted post-upload above. We re-save
      // them here too so a single `save()` is the source of truth for
      // "task as of last Run".
      final task = await AutomateTaskService.instance.getOrCreate(
        tagId: widget.tagId,
        tagName: widget.tag?.name ?? widget.tagId,
      );
      task.targetApp = _targetApp;
      task.toFieldTemplate = toTpl;
      task.messageTemplate = msgTpl;
      task.subjectTemplate = subjectTpl;
      task.rows = rows;
      task.attachmentLocalPath = _attachmentLocalPath;
      task.attachmentFileName = _attachmentFileName;
      task.attachmentCid = _attachmentCid;
      await AutomateTaskService.instance.save(task);

      if (!mounted) return;
      context.push('/automate-tasks/${widget.tagId}/run');
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = e.toString());
      }
    } finally {
      if (mounted) setState(() => _isRunning = false);
    }
  }

  /// Best-effort display-name pick — looks for a "name" header
  /// case-insensitively. Falls back to null so the run screen shows
  /// just the recipient.
  String? _displayNameFor(Map<String, String> row) {
    for (final entry in row.entries) {
      if (entry.key.toLowerCase().contains('name') &&
          entry.value.trim().isNotEmpty) {
        return entry.value.trim();
      }
    }
    return null;
  }

  /// Mirrors the website / AI flows' path-resolution helper: turn a
  /// stored path (which may be a Documents-relative path on iOS) into a
  /// usable absolute path on the current sandbox.
  Future<String> _resolveLocalPath(String path) async {
    if (path.startsWith('/') || (Platform.isWindows && path.length > 2)) {
      return path;
    }
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, path);
  }
}
