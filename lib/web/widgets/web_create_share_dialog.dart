import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/web/services/web_share_service.dart';

/// Mirror of lib/features/sharing/widgets/create_share_dialog.dart for
/// the web shell (the native file is dart:io- and Riverpod-tainted, so
/// the presentation is mirrored here 1:1 — same three choice cards,
/// copy, mode selector, expiry sheet and sticky bar — dispatching to
/// WebShareService instead of the sharesProvider).
class WebCreateShareDialog extends StatefulWidget {
  final String bucket;
  final String pathScope;
  final String storageKey;
  final String? fileName;
  final String? contentType;
  final SnapshotBinding? snapshotBinding;
  final WebShareChoice? lockedChoice;

  /// When set, this dialog creates a TAG share instead of a file share
  /// (native parity: temporal-only, password choice hidden, header
  /// shows the tag chip).
  final String? tagId;
  final String? tagName;

  const WebCreateShareDialog({
    super.key,
    required this.bucket,
    required this.pathScope,
    required this.storageKey,
    this.fileName,
    this.contentType,
    this.snapshotBinding,
    this.lockedChoice,
    this.tagId,
    this.tagName,
  });

  @override
  State<WebCreateShareDialog> createState() => _WebCreateShareDialogState();
}

class _WebCreateShareDialogState extends State<WebCreateShareDialog> {
  late WebShareChoice _choice;
  final _labelController = TextEditingController();
  final _passwordController = TextEditingController();
  final _recipientKeyController = TextEditingController();
  final _recipientNameController = TextEditingController();
  bool _obscurePassword = true;

  ShareMode _shareMode = ShareMode.snapshot;
  int? _expiryDays = 7;
  bool _isLoading = false;
  String? _error;

  bool get _isTagShare => widget.tagId != null;

  @override
  void initState() {
    super.initState();
    _choice = widget.lockedChoice ?? WebShareChoice.recipient;
    if (_isTagShare) {
      // Tag shares are always latest mode (snapshot doesn't apply).
      _shareMode = ShareMode.temporal;
      _labelController.text = widget.tagName ?? 'Tag share';
    } else {
      // Default label = file name (native parity).
      final name = widget.fileName ?? widget.pathScope.split('/').last;
      _labelController.text = name;
    }
  }

  @override
  void dispose() {
    _labelController.dispose();
    _passwordController.dispose();
    _recipientKeyController.dispose();
    _recipientNameController.dispose();
    super.dispose();
  }

  bool get _choiceLocked => widget.lockedChoice != null;

  Future<void> _pasteRecipientKey() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      setState(() => _recipientKeyController.text = data.text!.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Never let the sheet be dismissed WHILE a link is being created.
    // `_submit` ends in `Navigator.pop(context, result)` guarded by a
    // `mounted` check, so a dismissal mid-flight threw away a share that
    // had already been created (and already consumed a fula share token)
    // — the user saw the sheet vanish with no link and no error. The
    // route's `enableDrag: false` closes the drag-to-dismiss half of this
    // (a touch-only gesture, which is why the bug was mobile-only); this
    // blocks the barrier-tap and system-back half.
    return PopScope(
      canPop: !_isLoading,
      child: _sheet(theme),
    );
  }

  Widget _sheet(ThemeData theme) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  _header(context),
                  const SizedBox(height: 12),
                  _labelInput(context),
                  const SizedBox(height: 16),
                  const Text('Share with who?',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    'Pick based on who you trust. The safer you go, the fewer ways it can leak.',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _ShareChoiceCard(
                    title: 'Specific Person',
                    subtitle: 'They should share their FULA ID with you.',
                    badge: _Badge.safest(),
                    selected: _choice == WebShareChoice.recipient,
                    disabled: _choiceLocked &&
                        widget.lockedChoice != WebShareChoice.recipient,
                    onTap: () =>
                        setState(() => _choice = WebShareChoice.recipient),
                    icon: LucideIcons.userCheck,
                  ),
                  if (_choice == WebShareChoice.recipient) _recipientInputs(),
                  // Native parity: the password choice is hidden for
                  // tag shares (reachable via lockedChoice only).
                  if (!_isTagShare) ...[
                    const SizedBox(height: 8),
                    _ShareChoiceCard(
                      title: 'Protected link',
                      subtitle: 'Protect the link with a password.',
                      selected: _choice == WebShareChoice.password,
                      disabled: _choiceLocked &&
                          widget.lockedChoice != WebShareChoice.password,
                      onTap: () =>
                          setState(() => _choice = WebShareChoice.password),
                      icon: LucideIcons.lock,
                    ),
                    if (_choice == WebShareChoice.password) _passwordInput(),
                  ],
                  const SizedBox(height: 8),
                  _ShareChoiceCard(
                    title: 'Anyone with the link',
                    subtitle: 'If the link is forwarded, they get in too.',
                    badge: _Badge.open(),
                    selected: _choice == WebShareChoice.public,
                    disabled: _choiceLocked &&
                        widget.lockedChoice != WebShareChoice.public,
                    onTap: () =>
                        setState(() => _choice = WebShareChoice.public),
                    icon: LucideIcons.link,
                  ),
                  // Tag shares are always "latest" — no mode selector.
                  if (!_isTagShare) ...[
                    const SizedBox(height: 16),
                    _whatTheySeeSelector(context),
                  ],
                  const SizedBox(height: 12),
                  _expirySelector(context),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    _ErrorBlock(error: _error!),
                  ],
                ],
              ),
            ),
            _stickyBar(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final chipLabel =
        _isTagShare ? (widget.tagName ?? 'Tag') : widget.pathScope;
    final chipIcon = _isTagShare ? LucideIcons.tag : LucideIcons.folder;
    return Row(
      children: [
        Expanded(
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.primaryFaint,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(chipIcon, size: 14, color: AppColors.primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    chipLabel,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        IconButton(
          icon: const Icon(LucideIcons.x, size: 18),
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          tooltip: 'Close',
        ),
      ],
    );
  }

  Widget _labelInput(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Label (helps find this share later)',
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _labelController,
          decoration: const InputDecoration(
            isDense: true,
            hintText: 'e.g., Vacation photos',
            border: UnderlineInputBorder(),
          ),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  Widget _recipientInputs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        children: [
          TextField(
            controller: _recipientNameController,
            decoration: const InputDecoration(
              labelText: 'Recipient name',
              prefixIcon: Icon(LucideIcons.user, size: 18),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _recipientKeyController,
            decoration: InputDecoration(
              labelText: 'Their FULA Share ID',
              helperText: 'Ask them to copy it from Settings in the app.',
              prefixIcon: const Icon(LucideIcons.fingerprint, size: 18),
              suffixIcon: IconButton(
                icon: const Icon(LucideIcons.clipboard, size: 16),
                onPressed: _pasteRecipientKey,
                tooltip: 'Paste',
              ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _passwordInput() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: TextField(
        controller: _passwordController,
        obscureText: _obscurePassword,
        decoration: InputDecoration(
          labelText: 'Password',
          helperText: 'Share this separately from the link.',
          prefixIcon: const Icon(LucideIcons.key, size: 18),
          suffixIcon: IconButton(
            icon: Icon(
                _obscurePassword ? LucideIcons.eye : LucideIcons.eyeOff,
                size: 16),
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
          ),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _whatTheySeeSelector(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What they see',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<ShareMode>(
          segments: const [
            ButtonSegment(
              value: ShareMode.temporal,
              label: Text('Always the latest'),
              icon: Icon(LucideIcons.refreshCw, size: 14),
            ),
            ButtonSegment(
              value: ShareMode.snapshot,
              label: Text('Current version'),
              icon: Icon(LucideIcons.camera, size: 14),
            ),
          ],
          selected: {_shareMode},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _shareMode = s.first),
        ),
      ],
    );
  }

  Widget _expirySelector(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: _pickExpiry,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.clock,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Access expires in',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
            Text(
              _expiryLabel(_expiryDays),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevronRight,
                size: 16, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  String _expiryLabel(int? days) {
    if (days == null) return 'Never';
    if (days == 1) return '1 day';
    return '$days days';
  }

  Future<void> _pickExpiry() async {
    final picked = await showModalBottomSheet<int?>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final d in [1, 7, 30, 90])
              ListTile(
                leading: const Icon(LucideIcons.clock, size: 18),
                title: Text(_expiryLabel(d)),
                trailing: _expiryDays == d
                    ? const Icon(LucideIcons.check,
                        size: 18, color: AppColors.primary)
                    : null,
                onTap: () => Navigator.of(ctx).pop(d),
              ),
            if (_choice != WebShareChoice.public)
              ListTile(
                leading: const Icon(LucideIcons.infinity, size: 18),
                title: const Text('Never'),
                trailing: _expiryDays == null
                    ? const Icon(LucideIcons.check,
                        size: 18, color: AppColors.primary)
                    : null,
                onTap: () => Navigator.of(ctx).pop(null),
              ),
          ],
        ),
      ),
    );
    if (picked == null && _expiryDays != null) {
      // Navigator popped without a selection; keep current.
      return;
    }
    setState(() => _expiryDays = picked);
  }

  Widget _stickyBar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Row(
        children: [
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.primary,
                ),
              ),
            ),
          Expanded(
            child: Text(
              _isLoading ? 'Creating link…' : 'Link + expiry picked',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          FilledButton(
            onPressed: _isLoading ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            ),
            child: const Text(
              'Make the link',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final label = _labelController.text.trim().isNotEmpty
        ? _labelController.text.trim()
        : null;

    if (_choice == WebShareChoice.recipient) {
      final key = _recipientKeyController.text.trim();
      final name = _recipientNameController.text.trim();
      if (name.isEmpty) {
        setState(() => _error = 'Add a recipient name first.');
        return;
      }
      if (key.length < 10) {
        setState(() => _error = 'That Share ID doesn\'t look right.');
        return;
      }
    } else if (_choice == WebShareChoice.password) {
      if (_passwordController.text.length < 4) {
        setState(() => _error = 'Password must be at least 4 characters.');
        return;
      }
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final WebShareResult result;
      if (_isTagShare) {
        final tagId = widget.tagId!;
        switch (_choice) {
          case WebShareChoice.recipient:
            result = await WebShareService.createTagRecipientShare(
              tagId: tagId,
              recipientShareId: _recipientKeyController.text.trim(),
              recipientName: _recipientNameController.text.trim(),
              expiryDays: _expiryDays,
              label: label,
            );
          case WebShareChoice.password:
            result = await WebShareService.createTagPasswordLink(
              tagId: tagId,
              expiryDays: _expiryDays ?? 7,
              password: _passwordController.text,
              label: label,
            );
          case WebShareChoice.public:
            result = await WebShareService.createTagPublicLink(
              tagId: tagId,
              expiryDays: _expiryDays ?? 7,
              label: label,
            );
        }
      } else {
        switch (_choice) {
          case WebShareChoice.recipient:
            result = await WebShareService.createRecipientShare(
              bucket: widget.bucket,
              pathScope: widget.pathScope,
              storageKey: widget.storageKey,
              recipientShareId: _recipientKeyController.text.trim(),
              recipientName: _recipientNameController.text.trim(),
              expiryDays: _expiryDays,
              label: label,
              shareMode: _shareMode,
              snapshotBinding: widget.snapshotBinding,
              fileName: widget.fileName,
              contentType: widget.contentType,
            );
          case WebShareChoice.password:
            result = await WebShareService.createPasswordProtectedLink(
              bucket: widget.bucket,
              pathScope: widget.pathScope,
              storageKey: widget.storageKey,
              expiryDays: _expiryDays ?? 7,
              password: _passwordController.text,
              label: label,
              shareMode: _shareMode,
              snapshotBinding: widget.snapshotBinding,
              fileName: widget.fileName,
              contentType: widget.contentType,
            );
          case WebShareChoice.public:
            result = await WebShareService.createPublicLink(
              bucket: widget.bucket,
              pathScope: widget.pathScope,
              storageKey: widget.storageKey,
              expiryDays: _expiryDays ?? 7,
              label: label,
              shareMode: _shareMode,
              snapshotBinding: widget.snapshotBinding,
              fileName: widget.fileName,
              contentType: widget.contentType,
            );
        }
      }
      if (!mounted) return;
      Navigator.pop(context, result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = '$e';
      });
    }
  }
}

// ============================================================================
// Choice card + small support widgets (mirrors of the native ones)
// ============================================================================

class _Badge {
  final String label;
  final Color color;
  const _Badge._(this.label, this.color);
  factory _Badge.safest() => const _Badge._('Safest', AppColors.primary);
  factory _Badge.open() => const _Badge._('Open', Color(0xFFF59E0B));
}

class _ShareChoiceCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final bool disabled;
  final _Badge? badge;
  final VoidCallback onTap;

  const _ShareChoiceCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.disabled = false,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = selected
        ? AppColors.primary
        : theme.dividerColor.withValues(alpha: 0.4);
    final bg = selected
        ? AppColors.primaryFaint
        : theme.colorScheme.surface.withValues(alpha: 0.4);
    return Opacity(
      opacity: disabled ? 0.5 : 1.0,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: disabled ? null : onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border.all(
                  color: borderColor, width: selected ? 1.5 : 1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: selected ? AppColors.primary : theme.cardColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    icon,
                    size: 18,
                    color: selected
                        ? Colors.white
                        : theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(title,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                          if (badge != null) ...[
                            const SizedBox(width: 8),
                            _BadgeChip(badge: badge!),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  selected
                      ? LucideIcons.checkCircle2
                      : LucideIcons.circle,
                  size: 18,
                  color: selected
                      ? AppColors.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BadgeChip extends StatelessWidget {
  final _Badge badge;
  const _BadgeChip({required this.badge});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: badge.color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
            color: badge.color.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Text(
        badge.label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: badge.color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  final String error;
  const _ErrorBlock({required this.error});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.errorFaint,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.errorBorder),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.alertCircle,
              size: 16, color: AppColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Entry point + post-share confirmation dialog (mirrors of the native
// showCreate*Dialog wrappers and showShareCreatedDialog)
// ============================================================================

/// Open the share sheet. When [lockedChoice] is set the cards show but
/// can't be switched (native wrapper-entry-point behavior).
Future<WebShareResult?> showWebCreateShareDialog({
  required BuildContext context,
  required String bucket,
  required String pathScope,
  required String storageKey,
  String? fileName,
  String? contentType,
  SnapshotBinding? snapshotBinding,
  WebShareChoice? lockedChoice,
}) {
  return showModalBottomSheet<WebShareResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 560),
    // Drag-to-dismiss is a touch-only gesture, and mid-creation it
    // destroyed an already-created share link (see the PopScope in
    // WebCreateShareDialog.build). The sheet has an explicit close
    // button, which is already disabled while loading.
    enableDrag: false,
    builder: (_) => WebCreateShareDialog(
      bucket: bucket,
      pathScope: pathScope,
      storageKey: storageKey,
      fileName: fileName,
      contentType: contentType,
      snapshotBinding: snapshotBinding,
      lockedChoice: lockedChoice,
    ),
  );
}

/// Open the share sheet for a TAG (native showCreateTagShareDialog
/// parity: recipient/public choices, temporal-only).
Future<WebShareResult?> showWebCreateTagShareDialog({
  required BuildContext context,
  required String tagId,
  required String tagName,
}) {
  return showModalBottomSheet<WebShareResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 560),
    // See the file-share sheet above — same reason.
    enableDrag: false,
    builder: (_) => WebCreateShareDialog(
      bucket: '',
      pathScope: '',
      storageKey: '',
      tagId: tagId,
      tagName: tagName,
    ),
  );
}

/// Confirmation dialog shown after a share/link has been created —
/// mirror of the native showShareCreatedDialog (same titles, info rows
/// and explicit Copy Link button), plus a warning row when the share
/// could not be recorded in the cloud shares manifest.
Future<void> showWebShareCreatedDialog({
  required BuildContext context,
  required WebShareResult result,
}) async {
  final token = result.token;
  final url = result.url;

  String title;
  String description;
  IconData infoIcon;
  Color infoColor;
  String infoText;

  switch (result.choice) {
    case WebShareChoice.public:
      title = 'Link Created!';
      description = 'Anyone with this link can view the shared content.';
      infoIcon = LucideIcons.link;
      infoColor = Colors.blue;
      infoText = 'Public link';
      break;
    case WebShareChoice.password:
      title = 'Password Link Created!';
      description =
          'Share this link. Recipients will need the password you set to access.';
      infoIcon = LucideIcons.lock;
      infoColor = Colors.orange;
      infoText = 'Password protected';
      break;
    case WebShareChoice.recipient:
      title = 'Share Created!';
      description =
          'Share link created successfully. Send this link to the recipient — '
          'it opens in their FxFiles app:';
      infoIcon = LucideIcons.shield;
      infoColor = Theme.of(context).colorScheme.primary;
      infoText = 'Permission: ${token.permissions.displayName}';
      break;
  }

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          const Icon(LucideIcons.checkCircle, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(child: Text(title)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(description),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                url,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Theme.of(ctx).colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(infoIcon, size: 16, color: infoColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    infoText,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (token.expiresAt != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(LucideIcons.clock,
                      size: 16, color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Expires: ${_formatRelativeExpiry(token.expiresAt!)}',
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey[700]),
                    ),
                  ),
                ],
              ),
            ],
            if (result.notIncludedCount > 0) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(LucideIcons.info,
                      size: 16, color: AppColors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${result.notIncludedCount} older file(s) not '
                      'included — re-upload them to add them to this '
                      'share.',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            // The record write now runs in the BACKGROUND (the link above
            // is already valid and is shown immediately), so this warning
            // waits on it instead of gating the link on it. Nothing is
            // rendered while it's still in flight — a transient failure
            // usually succeeds on retry, and flashing a scary warning that
            // then disappears is worse than showing it a few seconds late.
            FutureBuilder<bool>(
              future: result.persisted,
              builder: (_, snap) {
                if (snap.data != false) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.warnFaint,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.warnBorder),
                    ),
                    child: const Row(
                      children: [
                        Icon(LucideIcons.alertTriangle,
                            size: 16, color: AppColors.warning),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'The link works, but it could not be recorded in '
                            'your shares list — it won\'t show in the app\'s '
                            'Sharing tab and can\'t be revoked early.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: url));
            ScaffoldMessenger.of(ctx).showSnackBar(
              const SnackBar(content: Text('Link copied to clipboard')),
            );
            Navigator.pop(ctx);
          },
          icon: const Icon(LucideIcons.copy),
          label: const Text('Copy Link'),
        ),
      ],
    ),
  );
}

String _formatRelativeExpiry(DateTime dt) {
  final now = DateTime.now();
  final diff = dt.difference(now);
  if (diff.isNegative) return 'expired';
  if (diff.inMinutes < 1) return 'in <1m';
  if (diff.inHours < 1) return 'in ${diff.inMinutes}m';
  if (diff.inDays < 1) return 'in ${diff.inHours}h';
  return 'in ${diff.inDays}d';
}
