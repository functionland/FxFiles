import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/core/models/automate_task.dart';
import 'package:fula_files/core/models/messaging_target.dart';
import 'package:fula_files/core/services/automate_task_service.dart';
import 'package:fula_files/core/services/ipfs_gateway_helper.dart';
import 'package:fula_files/core/services/ipfs_public_service.dart';
import 'package:fula_files/core/services/tabular_parser.dart';
import 'package:fula_files/core/utils/target_uri_builder.dart';
import 'package:fula_files/core/utils/template_renderer.dart';
import 'package:fula_files/features/automate/widgets/placeholder_chip_bar.dart';
import 'package:fula_files/shared/widgets/legal_disclaimer_dialog.dart';
import 'package:fula_files/web/services/web_automate_csv_store.dart';
import 'package:fula_files/web/services/web_tag_service.dart';

/// Mirror of lib/features/automate/screens/automate_task_detail_screen.dart
/// for the web shell. Same sections (Recipients CSV → Send via →
/// Attachment → Placeholders → TO/Subject/Message → Run task), same
/// deterministic TemplateRenderer substitution and TargetUriBuilder
/// validation. Browser differences: the CSV + attachment bytes live in
/// IndexedDB instead of sandbox files, and phone-contacts / VCard /
/// reuse-from-tag imports stay native (no contacts API on the web).
class WebAutomateTaskDetailScreen extends StatefulWidget {
  final String tagId;
  const WebAutomateTaskDetailScreen({super.key, required this.tagId});

  @override
  State<WebAutomateTaskDetailScreen> createState() =>
      _WebAutomateTaskDetailScreenState();
}

class _WebAutomateTaskDetailScreenState
    extends State<WebAutomateTaskDetailScreen> {
  final _toController = TextEditingController();
  final _messageController = TextEditingController();
  final _subjectController = TextEditingController();

  final _toFocus = FocusNode();
  final _messageFocus = FocusNode();
  final _subjectFocus = FocusNode();

  TargetApp _targetApp = TargetApp.whatsapp;
  bool _isRunning = false;
  String? _errorMessage;
  String? _uploadStatus;

  String _tagName = '';
  Color _tagColor = Colors.indigo;

  // Recipients CSV (from IndexedDB).
  String? _csvFileName;
  String? _csvText;
  List<String> _headers = const [];

  // Attachment (bytes in IndexedDB; CID persisted on the task).
  String? _attachmentFileName;
  String? _attachmentCid;
  bool _hasAttachmentBytes = false;

  List<SendPlanRow> _existingRows = const [];

  StreamSubscription<AutomateTask>? _taskSub;

  String get _displayName => _tagName.isEmpty
      ? 'Automate task'
      : _tagName.replaceFirst('automate-tasks-', '');

  @override
  void initState() {
    super.initState();
    _loadTask();
    _taskSub = AutomateTaskService.instance.statusStream.listen((t) {
      if (t.tagId == widget.tagId && mounted) {
        setState(() => _existingRows = List<SendPlanRow>.from(t.rows));
      }
    });
  }

  @override
  void dispose() {
    _taskSub?.cancel();
    _toController.dispose();
    _messageController.dispose();
    _subjectController.dispose();
    _toFocus.dispose();
    _messageFocus.dispose();
    _subjectFocus.dispose();
    super.dispose();
  }

  Future<void> _loadTask() async {
    try {
      await WebTagService.instance.load();
    } catch (_) {
      // Tag manifest load is best-effort here — the task record itself
      // is local and still works (name falls back to the stored one).
    }
    final tag = WebTagService.instance.tagById(widget.tagId);
    final task = await AutomateTaskService.instance.getOrCreate(
      tagId: widget.tagId,
      tagName: tag?.name ?? widget.tagId,
    );
    final csv = await WebAutomateCsvStore.instance.readCsv(widget.tagId);
    final attachment =
        await WebAutomateCsvStore.instance.readAttachment(widget.tagId);
    if (!mounted) return;
    setState(() {
      _tagName = tag?.name ?? task.tagName;
      _tagColor = tag != null ? Color(tag.colorValue) : Colors.indigo;
      _targetApp = task.targetApp;
      _toController.text = task.toFieldTemplate;
      _messageController.text = task.messageTemplate;
      _subjectController.text = task.subjectTemplate ?? '';
      _attachmentFileName =
          attachment?.fileName ?? task.attachmentFileName;
      _attachmentCid = task.attachmentCid;
      _hasAttachmentBytes = attachment != null;
      _csvFileName = csv?.fileName;
      _csvText = csv?.csvText;
      _existingRows = List<SendPlanRow>.from(task.rows);
    });
    _refreshHeaders();
  }

  void _refreshHeaders() {
    final text = _csvText;
    if (text == null || text.isEmpty) {
      setState(() => _headers = const []);
      return;
    }
    try {
      final tabular = TabularParser.parseBytes(
        utf8.encode(text),
        fileName: _csvFileName ?? 'recipients.csv',
      );
      setState(() => _headers = tabular.headers);
    } catch (e) {
      debugPrint('WebAutomateTaskDetail: header refresh failed: $e');
      setState(() => _headers = const []);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final isEmail = _targetApp == TargetApp.email;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/automate-tasks'),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration:
                  BoxDecoration(color: _tagColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(_displayName),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            children: [
              _section(
                context,
                title: 'Recipients (CSV)',
                trailing: IconButton(
                  icon: const Icon(LucideIcons.filePlus, size: 18),
                  tooltip: 'Import recipients',
                  onPressed: _pickCsvFile,
                ),
              ),
              if (_csvFileName == null)
                _emptyAssetState()
              else
                ListTile(
                  leading:
                      const Icon(LucideIcons.fileSpreadsheet, size: 22),
                  title: Text(_csvFileName!,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${_headers.length} column${_headers.length == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: IconButton(
                    icon: const Icon(LucideIcons.x, size: 18),
                    tooltip: 'Remove',
                    onPressed: _removeCsv,
                  ),
                ),
              const Divider(),
              if (_existingRows.isNotEmpty) _progressCard(),
              _section(context, title: 'Send via'),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: _WebTargetAppPicker(
                  selected: _targetApp,
                  onSelected: (t) => setState(() => _targetApp = t),
                ),
              ),
              if (_targetApp == TargetApp.sms)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(
                    'SMS links open your device\'s messaging app — they '
                    'work from phones and tablets; most desktop browsers '
                    'have no SMS handler.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                  ),
                ),
              _section(
                context,
                title: 'Attachment (optional)',
                trailing: _attachmentFileName == null
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
                  extraChips:
                      _attachmentFileName != null ? const ['File'] : const [],
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
                      border: Border.all(
                          color: Colors.red.withValues(alpha: 0.3)),
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
        ),
      ),
    );
  }

  Widget _progressCard() {
    final theme = Theme.of(context);
    final total = _existingRows.length;
    final sent =
        _existingRows.where((r) => r.status == SendStatus.sent).length;
    final opened =
        _existingRows.where((r) => r.status == SendStatus.opened).length;
    final pending =
        _existingRows.where((r) => r.status == SendStatus.pending).length;
    final failed =
        _existingRows.where((r) => r.status == SendStatus.failed).length;

    final isComplete = pending == 0 && opened == 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.dividerColor),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                    isComplete
                        ? LucideIcons.checkCircle2
                        : LucideIcons.playCircle,
                    size: 18,
                    color: isComplete
                        ? Colors.green
                        : theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  isComplete ? 'Send complete' : 'Send in progress',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _progressLine(
                  total: total,
                  sent: sent,
                  opened: opened,
                  pending: pending,
                  failed: failed),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: () =>
                    context.go('/automate-tasks/${widget.tagId}/run'),
                icon: const Icon(LucideIcons.listChecks, size: 16),
                label: const Text('View send progress'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _progressLine({
    required int total,
    required int sent,
    required int opened,
    required int pending,
    required int failed,
  }) {
    final parts = <String>[];
    if (sent > 0) parts.add('$sent sent');
    if (opened > 0) parts.add('$opened opened');
    if (pending > 0) parts.add('$pending pending');
    if (failed > 0) parts.add('$failed failed');
    final summary = parts.isEmpty ? '$total total' : parts.join(' · ');
    return '$summary of $total';
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
              'No recipients yet',
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'Import a CSV file — the first row becomes the column '
              'chips. Phone-contacts and VCard import are available in '
              'the FxFiles app.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _pickCsvFile,
              icon: const Icon(LucideIcons.filePlus, size: 16),
              label: const Text('Import a CSV file'),
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
        withData: true,
      );
      final picked = result?.files.firstOrNull;
      final bytes = picked?.bytes;
      if (picked == null || bytes == null) return;

      // Validates size + extension and parses — same messages as native.
      final tabular =
          TabularParser.parseBytes(bytes, fileName: picked.name);
      await WebAutomateCsvStore.instance.saveCsv(
        tagId: widget.tagId,
        fileName: picked.name,
        csvText: utf8.decode(bytes),
      );
      if (!mounted) return;
      setState(() {
        _csvFileName = picked.name;
        _csvText = utf8.decode(bytes);
        _headers = tabular.headers;
      });
    } catch (e) {
      _snack('Failed to import file: $e');
    }
  }

  Future<void> _removeCsv() async {
    await WebAutomateCsvStore.instance.removeCsv(widget.tagId);
    if (!mounted) return;
    setState(() {
      _csvFileName = null;
      _csvText = null;
      _headers = const [];
    });
  }

  Future<void> _pickAttachment() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true,
      );
      final picked = result?.files.firstOrNull;
      final bytes = picked?.bytes;
      if (picked == null || bytes == null) return;
      if (bytes.length > WebAutomateCsvStore.maxAttachmentBytes) {
        _snack('Attachment is too large — keep it under '
            '${WebAutomateCsvStore.maxAttachmentBytes ~/ (1024 * 1024)} MB.');
        return;
      }

      await WebAutomateCsvStore.instance.saveAttachment(
        tagId: widget.tagId,
        fileName: picked.name,
        bytes: bytes,
      );
      // Persist name immediately; a new file invalidates any prior CID.
      final task = await AutomateTaskService.instance.getOrCreate(
        tagId: widget.tagId,
        tagName: _tagName.isEmpty ? widget.tagId : _tagName,
      );
      task.attachmentFileName = picked.name;
      task.attachmentCid = null;
      await AutomateTaskService.instance.save(task);

      if (!mounted) return;
      setState(() {
        _attachmentFileName = picked.name;
        _attachmentCid = null;
        _hasAttachmentBytes = true;
      });
    } catch (e) {
      _snack('Failed to attach file: $e');
    }
  }

  Future<void> _removeAttachment() async {
    await WebAutomateCsvStore.instance.removeAttachment(widget.tagId);
    final task = await AutomateTaskService.instance.getOrCreate(
      tagId: widget.tagId,
      tagName: _tagName.isEmpty ? widget.tagId : _tagName,
    );
    task.attachmentLocalPath = null;
    task.attachmentFileName = null;
    task.attachmentCid = null;
    await AutomateTaskService.instance.save(task);
    if (!mounted) return;
    setState(() {
      _attachmentFileName = null;
      _attachmentCid = null;
      _hasAttachmentBytes = false;
    });
  }

  Widget _attachmentCard() {
    final theme = Theme.of(context);
    if (_attachmentFileName == null) {
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
        : (_hasAttachmentBytes
            ? 'Will upload to IPFS on Run'
            : 'Re-attach the file in this browser to upload');
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

  Future<bool?> _confirmReRun() async {
    final sent =
        _existingRows.where((r) => r.status == SendStatus.sent).length;
    final opened =
        _existingRows.where((r) => r.status == SendStatus.opened).length;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace previous send plan?'),
        content: Text(
          'You already have a send plan with $sent sent and $opened opened. '
          'Running again will rebuild the plan from the current CSV + '
          'templates and reset every row to pending. Tap View send '
          'progress to continue the existing send instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Replace and re-run'),
          ),
        ],
      ),
    );
  }

  /// IPFS-public consent for the attachment — same inline pattern the
  /// web bucket screen uses for Share Publicly.
  Future<bool> _confirmIpfsUpload() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Upload attachment to IPFS?'),
        content: Text(
          'The attachment "${_attachmentFileName ?? 'file'}" will be '
          'uploaded to IPFS without any encryption so recipients can '
          'open the {File} link. Anyone with the link will be able to '
          'access it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.teal),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Upload and continue'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _runTask() async {
    setState(() => _errorMessage = null);

    if (_toController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'TO field is empty');
      return;
    }
    if (_messageController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'Message is empty');
      return;
    }

    final hasProgress =
        _existingRows.any((r) => r.status != SendStatus.pending);
    if (hasProgress) {
      final cont = await _confirmReRun();
      if (cont != true) return;
      if (!mounted) return;
    }

    final confirmed = await showBulkSendDisclaimer(context);
    if (!confirmed || !mounted) return;

    setState(() => _isRunning = true);
    try {
      // ----- Attachment upload (if needed) -----
      String? attachmentUrl;
      if (_attachmentFileName != null) {
        if (_attachmentCid == null) {
          final attachment = await WebAutomateCsvStore.instance
              .readAttachment(widget.tagId);
          if (attachment == null) {
            throw Exception(
                'Attachment bytes are not in this browser — re-attach '
                'the file (or remove the attachment) and run again.');
          }
          if (!mounted) return;
          final ipfsOk = await _confirmIpfsUpload();
          if (ipfsOk != true) return;
          setState(() => _uploadStatus = 'Uploading attachment to IPFS…');
          final result = await IpfsPublicService.instance.pinBytes(
            attachment.bytes,
            attachment.fileName,
          );
          _attachmentCid = result.cid;
          setState(() => _uploadStatus = null);

          // Persist the CID immediately so a tab-close here doesn't
          // make the user re-upload on the next Run.
          final t0 = await AutomateTaskService.instance.getOrCreate(
            tagId: widget.tagId,
            tagName: _tagName.isEmpty ? widget.tagId : _tagName,
          );
          t0.attachmentCid = _attachmentCid;
          await AutomateTaskService.instance.save(t0);
        }
        attachmentUrl = IpfsGatewayHelper.buildUrlForCid(_attachmentCid!);
      }

      final text = _csvText;
      if (text == null || text.isEmpty) {
        throw Exception('Attach a CSV file first.');
      }
      final tabular = TabularParser.parseBytes(
        utf8.encode(text),
        fileName: _csvFileName ?? 'recipients.csv',
      );
      if (tabular.isEmpty) {
        throw Exception('CSV has no data rows.');
      }

      final toTpl = _toController.text;
      final msgTpl = _messageController.text;
      final subjectTpl =
          _targetApp == TargetApp.email && _subjectController.text.isNotEmpty
              ? _subjectController.text
              : null;

      // Per-row substitution + pre-validation — identical to the app.
      final rows = <SendPlanRow>[];
      for (final row in tabular.rows) {
        final renderRow = attachmentUrl != null
            ? {...row, 'File': attachmentUrl}
            : row;
        final renderedTo =
            TemplateRenderer.render(toTpl, renderRow).trim();
        final renderedMsg = TemplateRenderer.render(msgTpl, renderRow);

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
          displayName: _displayNameFor(row),
          message: renderedMsg,
          status: failureReason == null
              ? SendStatus.pending
              : SendStatus.failed,
          failureReason: failureReason,
        ));
      }

      final task = await AutomateTaskService.instance.getOrCreate(
        tagId: widget.tagId,
        tagName: _tagName.isEmpty ? widget.tagId : _tagName,
      );
      task.targetApp = _targetApp;
      task.toFieldTemplate = toTpl;
      task.messageTemplate = msgTpl;
      task.subjectTemplate = subjectTpl;
      task.rows = rows;
      task.attachmentFileName = _attachmentFileName;
      task.attachmentCid = _attachmentCid;
      await AutomateTaskService.instance.save(task);

      if (!mounted) return;
      context.go('/automate-tasks/${widget.tagId}/run');
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = e.toString());
      }
    } finally {
      if (mounted) setState(() => _isRunning = false);
    }
  }

  String? _displayNameFor(Map<String, String> row) {
    for (final entry in row.entries) {
      if (entry.key.toLowerCase().contains('name') &&
          entry.value.trim().isNotEmpty) {
        return entry.value.trim();
      }
    }
    return null;
  }
}

/// Web variant of shared/widgets/target_app_picker.dart. The native
/// picker probes installed apps via dart:io Platform checks; in a
/// browser every target resolves to a universal link (wa.me / t.me /
/// mailto: / sms:) handled by the OS, so all four stay selectable.
class _WebTargetAppPicker extends StatelessWidget {
  final TargetApp selected;
  final ValueChanged<TargetApp> onSelected;

  const _WebTargetAppPicker({
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemBuilder: (_, i) {
          final target = TargetApp.values[i];
          return _TargetCard(
            target: target,
            selected: selected == target,
            onTap: () => onSelected(target),
          );
        },
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemCount: TargetApp.values.length,
      ),
    );
  }
}

class _TargetCard extends StatelessWidget {
  final TargetApp target;
  final bool selected;
  final VoidCallback onTap;

  const _TargetCard({
    required this.target,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 100,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.dividerColor.withValues(alpha: 0.5),
            width: selected ? 2 : 1,
          ),
          color: selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
              : theme.cardColor,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_iconFor(target),
                size: 28,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 6),
            Text(
              TargetUriBuilder.label(target),
              style: theme.textTheme.labelMedium,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(TargetApp t) {
    switch (t) {
      case TargetApp.whatsapp:
        return LucideIcons.messageCircle;
      case TargetApp.telegram:
        return LucideIcons.send;
      case TargetApp.sms:
        return LucideIcons.messageSquare;
      case TargetApp.email:
        return LucideIcons.mail;
    }
  }
}
