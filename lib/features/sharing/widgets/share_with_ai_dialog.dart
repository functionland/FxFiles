import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/features/sharing/services/collab_ai_pairing_service.dart';

/// Show the "Share with AI Agent" dialog for a collaboration [groupId].
///
/// The owner pastes the AI agent's `FULA-…` id; FxFiles authorizes the group for
/// the agent and shows the platform-appropriate MCP client config to copy. The
/// existing collaboration LINK is always offered as a working fallback.
Future<void> showShareWithAiDialog(
  BuildContext context, {
  required String groupId,
  required String groupName,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ShareWithAiDialog(groupId: groupId, groupName: groupName),
  );
}

class _ShareWithAiDialog extends StatefulWidget {
  final String groupId;
  final String groupName;
  const _ShareWithAiDialog({required this.groupId, required this.groupName});

  @override
  State<_ShareWithAiDialog> createState() => _ShareWithAiDialogState();
}

class _ShareWithAiDialogState extends State<_ShareWithAiDialog> {
  final _idController = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _unsupportedMsg;
  CollabAiPairing? _result;
  String? _fallbackUrl;
  late bool _showHosted = !_isDesktopTarget;

  static bool get _isDesktopTarget =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final fulaId = _idController.text.trim();
    if (fulaId.isEmpty) {
      setState(() => _error = 'Enter the AI agent id (starts with "FULA-").');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _unsupportedMsg = null;
    });
    try {
      final pairing = await CollabAiPairingService.instance.pairGroupWithAi(
        groupId: widget.groupId,
        fulaId: fulaId,
      );
      if (!mounted) return;
      setState(() {
        _result = pairing;
        _fallbackUrl = pairing.fallbackCollabUrl;
        _busy = false;
      });
    } on CollabPairingUnsupported catch (e) {
      final fb =
          await CollabAiPairingService.instance.fallbackCollabUrl(widget.groupId);
      if (!mounted) return;
      setState(() {
        _unsupportedMsg = e.message;
        _fallbackUrl = fb;
        _busy = false;
      });
    } catch (e) {
      final fb =
          await CollabAiPairingService.instance.fallbackCollabUrl(widget.groupId);
      if (!mounted) return;
      setState(() {
        _error = e is CollabPairingException ? e.message : e.toString();
        _fallbackUrl = fb;
        _busy = false;
      });
    }
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          const Icon(LucideIcons.bot),
          const SizedBox(width: 8),
          Expanded(child: Text(_result != null ? 'AI Agent Ready' : 'Share with AI Agent')),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: _result != null ? _buildResult(theme) : _buildForm(theme),
        ),
      ),
      actions: _result != null
          ? [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ]
          : [
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _pair,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(LucideIcons.sparkles, size: 16),
                label: const Text('Authorize'),
              ),
            ],
    );
  }

  Widget _buildForm(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Warning: what the AI can do.
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.amber.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(LucideIcons.alertTriangle,
                  size: 18, color: Colors.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'The AI agent will be able to see all files in '
                  '"${widget.groupName}" and add new files to it. It cannot '
                  'permanently delete your files. You can revoke access at any '
                  'time.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // How to connect a web AI + get its Fula id (Flow A + Flow B step 2).
        _noteBox(
          theme,
          LucideIcons.info,
          'To connect a web AI (Claude / ChatGPT): add a custom connector for the '
          'URL below and sign in with the SAME Google account as FxFiles. Then ask '
          'the AI "What is your Fula identity?" and paste the FULA-… id it returns.',
        ),
        const SizedBox(height: 8),
        _copyBox(theme, 'Connector URL', '$kHostedMcpBaseUrl/mcp'),
        const SizedBox(height: 16),
        TextField(
          controller: _idController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'AI agent id',
            hintText: 'FULA-…',
            border: OutlineInputBorder(),
            prefixIcon: Icon(LucideIcons.key),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Paste the "FULA-…" id your AI agent shows when connecting.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        if (_unsupportedMsg != null) ...[
          const SizedBox(height: 12),
          _noteBox(theme, LucideIcons.info,
              'AI pairing is not available in this build yet.\n$_unsupportedMsg'),
          if (_fallbackUrl != null) ...[
            const SizedBox(height: 12),
            Text('Meanwhile, share this collaboration link with the AI:',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            _copyBox(theme, 'Collaboration link', _fallbackUrl!),
          ],
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 13)),
          if (_fallbackUrl != null) ...[
            const SizedBox(height: 12),
            _copyBox(theme, 'Collaboration link', _fallbackUrl!),
          ],
        ],
      ],
    );
  }

  Widget _buildResult(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'The group "${widget.groupName}" is authorized for this AI.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Desktop'), icon: Icon(LucideIcons.monitor, size: 16)),
            ButtonSegment(value: true, label: Text('Mobile / Web'), icon: Icon(LucideIcons.cloud, size: 16)),
          ],
          selected: {_showHosted},
          onSelectionChanged: (s) => setState(() => _showHosted = s.first),
        ),
        const SizedBox(height: 12),
        ...(_showHosted ? _buildHostedResult(theme) : _buildDesktopResult(theme)),
        const SizedBox(height: 16),
        Text(
          'Or share the collaboration link — note it carries the RAW group key in '
          'its fragment (less protected than the wrapped key above); prefer the '
          'connector / config when your agent supports it.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 6),
        _copyBox(
            theme, 'Collaboration link (raw group key)', _result!.fallbackCollabUrl),
      ],
    );
  }

  /// Desktop (local-stdio): the AI client reads the capability from an env var, so
  /// we hand the user the config to paste.
  List<Widget> _buildDesktopResult(ThemeData theme) {
    return [
      Text('Add this configuration to your desktop AI agent:',
          style: theme.textTheme.bodySmall),
      const SizedBox(height: 8),
      _copyBox(theme, 'Desktop config', _result!.localStdioConfig),
    ];
  }

  /// Mobile / Web (hosted connector): delivery is via the hosted service (C1) —
  /// there is NO config to paste when the bundle was delivered. If delivery
  /// failed, the hosted browser path is unavailable, so point at Desktop / the link.
  List<Widget> _buildHostedResult(ThemeData theme) {
    if (_result!.bundleDelivered) {
      return [
        _noteBox(
          theme,
          LucideIcons.cloud,
          'Your AI is connected to this group via the hosted Fula connector — '
          'nothing to paste. Make sure it added the connector below (signed in '
          'with the same Google account), then try: "List the files in my Fula '
          'collaboration" or "Save this note to my Fula group."',
        ),
        const SizedBox(height: 8),
        _copyBox(theme, 'Connector URL', '$kHostedMcpBaseUrl/mcp'),
      ];
    }
    return [
      _noteBox(
        theme,
        LucideIcons.alertTriangle,
        'Couldn\'t set up the hosted (browser) connection'
        '${_result!.bundleError != null ? ': ${_result!.bundleError}' : ''}. '
        'Share the collaboration link below instead (or use the Desktop option '
        'on a computer).',
      ),
    ];
  }

  Widget _noteBox(ThemeData theme, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  Widget _copyBox(ThemeData theme, String label, String text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.outline)),
            ),
            TextButton.icon(
              onPressed: () => _copy(text, label),
              icon: const Icon(LucideIcons.copy, size: 14),
              label: const Text('Copy'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 140),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
      ],
    );
  }
}
