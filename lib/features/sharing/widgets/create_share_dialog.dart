import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/sharing_service.dart';
import 'package:fula_files/features/sharing/providers/sharing_provider.dart';
import 'package:fula_files/shared/utils/error_messages.dart';

/// Which share backend to invoke.
enum ShareChoice { recipient, password, public }

/// Result wrapper — set field depends on which ShareChoice the user picked.
class ShareCreateResult {
  final ShareToken? recipientToken;
  final GeneratedShareLink? link;
  final ShareChoice choice;

  const ShareCreateResult._({
    this.recipientToken,
    this.link,
    required this.choice,
  });
}

/// Unified bottom-sheet share creation dialog. User picks one of three
/// choices (specific person / protected link / anyone with link) and the
/// sheet dispatches to the matching backend. When `lockedChoice` is set
/// the choice cards are visible but cannot be switched — used by the
/// legacy wrapper entry points.
///
/// When [tagId] is provided the dialog operates in tag-share mode:
///   - pathScope/bucket are unused (tag scope is dynamic)
///   - share mode is forced to temporal (latest) — snapshot is meaningless
///   - password share is hidden (not supported for tag shares in v1)
///   - the header chip shows the tag name
class CreateShareDialog extends ConsumerStatefulWidget {
  final String pathScope;
  final String bucket;
  final Uint8List? dek;
  final String? fileName;
  final String? contentType;
  final String? localPath;
  final ShareChoice? lockedChoice;

  /// When set, this dialog creates a tag share instead of a file/folder share.
  final String? tagId;
  final String? tagName;

  const CreateShareDialog({
    super.key,
    required this.pathScope,
    required this.bucket,
    this.dek,
    this.fileName,
    this.contentType,
    this.localPath,
    this.lockedChoice,
    this.tagId,
    this.tagName,
  });

  @override
  ConsumerState<CreateShareDialog> createState() => _CreateShareDialogState();
}

class _CreateShareDialogState extends ConsumerState<CreateShareDialog> {
  late ShareChoice _choice;
  final _labelController = TextEditingController();
  final _passwordController = TextEditingController();
  final _recipientKeyController = TextEditingController();
  final _recipientNameController = TextEditingController();
  bool _obscurePassword = true;

  ShareMode _shareMode = ShareMode.snapshot;
  int? _expiryDays = 7;
  SharePermissions _permissions = SharePermissions.readOnly;
  bool _isLoading = false;
  String? _error;

  bool get _isTagShare => widget.tagId != null;

  @override
  void initState() {
    super.initState();
    _choice = widget.lockedChoice ?? ShareChoice.recipient;
    if (_isTagShare) {
      // Tag shares are always latest mode (snapshot doesn't apply to a tag).
      _shareMode = ShareMode.temporal;
      // Hide password choice; fall back to recipient if it was the default.
      if (_choice == ShareChoice.password) _choice = ShareChoice.recipient;
      _labelController.text = widget.tagName ?? 'Tag share';
    } else {
      // Default label = file/folder name
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
                    kind: ShareChoice.recipient,
                    title: 'Specific Person',
                    subtitle: 'They should share their FULA ID with you.',
                    badge: _Badge.safest(),
                    selected: _choice == ShareChoice.recipient,
                    disabled: _choiceLocked &&
                        widget.lockedChoice != ShareChoice.recipient,
                    onTap: () => setState(() => _choice = ShareChoice.recipient),
                    icon: LucideIcons.userCheck,
                  ),
                  if (_choice == ShareChoice.recipient) _recipientInputs(),
                  if (!_isTagShare) ...[
                    const SizedBox(height: 8),
                    _ShareChoiceCard(
                      kind: ShareChoice.password,
                      title: 'Protected link',
                      subtitle: 'Protect the link with a password.',
                      selected: _choice == ShareChoice.password,
                      disabled: _choiceLocked &&
                          widget.lockedChoice != ShareChoice.password,
                      onTap: () => setState(() => _choice = ShareChoice.password),
                      icon: LucideIcons.lock,
                    ),
                    if (_choice == ShareChoice.password) _passwordInput(),
                  ],
                  const SizedBox(height: 8),
                  _ShareChoiceCard(
                    kind: ShareChoice.public,
                    title: 'Anyone with the link',
                    subtitle:
                        'If the link is forwarded, they get in too.',
                    badge: _Badge.open(),
                    selected: _choice == ShareChoice.public,
                    disabled: _choiceLocked &&
                        widget.lockedChoice != ShareChoice.public,
                    onTap: () => setState(() => _choice = ShareChoice.public),
                    icon: LucideIcons.link,
                  ),
                  // For tag shares the mode is always "latest" — skip the
                  // segmented selector entirely.
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
    final theme = Theme.of(context);
    final isTag = _isTagShare;
    final chipLabel = isTag ? (widget.tagName ?? 'Tag') : widget.pathScope;
    final chipIcon = isTag ? LucideIcons.tag : LucideIcons.folder;
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
              helperText: 'Ask them to copy it from Settings.',
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
            if (_choice != ShareChoice.public)
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
    // Validate per choice
    final label = _labelController.text.trim().isNotEmpty
        ? _labelController.text.trim()
        : null;

    if (_choice == ShareChoice.recipient) {
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
    } else if (_choice == ShareChoice.password) {
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
      final notifier = ref.read(sharesProvider.notifier);

      // Tag share path — dispatches to the tag-specific service methods.
      if (_isTagShare) {
        final tagId = widget.tagId!;
        if (_choice == ShareChoice.recipient) {
          final token = await notifier.shareTagWithUser(
            tagId: tagId,
            recipientPublicKeyBase64: _recipientKeyController.text.trim(),
            recipientName: _recipientNameController.text.trim(),
            expiryDays: _expiryDays,
            label: label,
          );
          if (!mounted) return;
          if (token == null) {
            final err = ref.read(sharesProvider).error;
            setState(() {
              _isLoading = false;
              _error = err ?? 'Failed to create share';
            });
            return;
          }
          Navigator.pop(
            context,
            ShareCreateResult._(
                recipientToken: token, choice: ShareChoice.recipient),
          );
          return;
        }

        // Public tag link.
        final link = await notifier.createTagPublicLink(
          tagId: tagId,
          expiryDays: _expiryDays ?? 7,
          label: label,
        );
        if (!mounted) return;
        if (link == null) {
          final err = ref.read(sharesProvider).error;
          setState(() {
            _isLoading = false;
            _error = err ?? 'Failed to create link';
          });
          return;
        }
        Navigator.pop(
          context,
          ShareCreateResult._(link: link, choice: ShareChoice.public),
        );
        return;
      }

      // Standard file/folder share path.
      final binding = await _resolveSnapshotBinding();

      if (_choice == ShareChoice.recipient) {
        final token = await notifier.createShare(
          pathScope: widget.pathScope,
          bucket: widget.bucket,
          recipientPublicKeyBase64: _recipientKeyController.text.trim(),
          recipientName: _recipientNameController.text.trim(),
          dek: widget.dek,
          permissions: _permissions,
          expiryDays: _expiryDays,
          label: label,
          shareMode: _shareMode,
          snapshotBinding: binding,
          fileName: widget.fileName,
          contentType: widget.contentType,
        );
        if (!mounted) return;
        if (token == null) {
          final err = ref.read(sharesProvider).error;
          setState(() {
            _isLoading = false;
            _error = err ?? 'Failed to create share';
          });
          return;
        }
        Navigator.pop(
          context,
          ShareCreateResult._(
              recipientToken: token, choice: ShareChoice.recipient),
        );
        return;
      }

      if (_choice == ShareChoice.password) {
        final link = await notifier.createPasswordProtectedLink(
          pathScope: widget.pathScope,
          bucket: widget.bucket,
          dek: widget.dek,
          expiryDays: _expiryDays ?? 7,
          password: _passwordController.text,
          label: label,
          shareMode: _shareMode,
          snapshotBinding: binding,
          fileName: widget.fileName,
          contentType: widget.contentType,
        );
        if (!mounted) return;
        if (link == null) {
          final err = ref.read(sharesProvider).error;
          setState(() {
            _isLoading = false;
            _error = err ?? 'Failed to create link';
          });
          return;
        }
        Navigator.pop(
          context,
          ShareCreateResult._(link: link, choice: ShareChoice.password),
        );
        return;
      }

      // Public
      final link = await notifier.createPublicLink(
        pathScope: widget.pathScope,
        bucket: widget.bucket,
        dek: widget.dek,
        expiryDays: _expiryDays ?? 7,
        label: label,
        shareMode: _shareMode,
        snapshotBinding: binding,
        fileName: widget.fileName,
        contentType: widget.contentType,
      );
      if (!mounted) return;
      if (link == null) {
        final err = ref.read(sharesProvider).error;
        setState(() {
          _isLoading = false;
          _error = err ?? 'Failed to create link';
        });
        return;
      }
      Navigator.pop(
        context,
        ShareCreateResult._(link: link, choice: ShareChoice.public),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = ErrorMessages.forShare(e);
      });
    }
  }

  Future<SnapshotBinding?> _resolveSnapshotBinding() async {
    final cid = await _getCidForFile();
    final syncState = widget.localPath != null
        ? LocalStorageService.instance.getSyncState(widget.localPath!)
        : null;
    if (cid != null && syncState != null) {
      return SnapshotBinding(
        contentHash: syncState.etag ?? cid,
        size: syncState.localSize ?? 0,
        modifiedAt: syncState.lastSyncedAt?.millisecondsSinceEpoch ??
            DateTime.now().millisecondsSinceEpoch,
        storageKey: cid,
      );
    }
    return null;
  }

  bool _isValidCid(String value) {
    if (value.startsWith('baf') && value.length >= 50) return true;
    if (value.startsWith('Qm') && value.length == 46) return true;
    return false;
  }

  Future<String?> _getCidForFile() async {
    if (widget.localPath == null) return null;
    final syncState =
        LocalStorageService.instance.getSyncState(widget.localPath!);
    if (syncState != null && syncState.status == SyncStatus.synced) {
      final etag = syncState.etag;
      if (etag != null && _isValidCid(etag)) return etag;
      if (syncState.bucket != null && syncState.remotePath != null) {
        try {
          final metadata = await FulaApiService.instance.getObjectMetadata(
            syncState.bucket!,
            syncState.remotePath!,
          );
          if (metadata.etag != null && _isValidCid(metadata.etag!)) {
            return metadata.etag;
          }
        } catch (_) {}
      }
    }
    if (FileSystemEntity.isDirectorySync(widget.localPath!)) {
      final children = LocalStorageService.instance
          .getSyncStatesUnderPath(widget.localPath!);
      for (final child in children) {
        if (child.status == SyncStatus.synced &&
            child.etag != null &&
            _isValidCid(child.etag!)) {
          return child.etag;
        }
      }
    }
    return null;
  }
}

// ============================================================================
// Choice card + small support widgets
// ============================================================================

class _Badge {
  final String label;
  final Color color;
  const _Badge._(this.label, this.color);
  factory _Badge.safest() => const _Badge._('Safest', AppColors.primary);
  factory _Badge.open() => const _Badge._('Open', Color(0xFFF59E0B));
}

class _ShareChoiceCard extends StatelessWidget {
  final ShareChoice kind;
  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final bool disabled;
  final _Badge? badge;
  final VoidCallback onTap;

  const _ShareChoiceCard({
    required this.kind,
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
                    color: selected
                        ? AppColors.primary
                        : theme.cardColor,
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
// Legacy-compatible entry points
// ============================================================================

Future<ShareToken?> showCreateShareForRecipientDialog({
  required BuildContext context,
  required String pathScope,
  required String bucket,
  Uint8List? dek,
  String? fileName,
  String? contentType,
  String? localPath,
}) async {
  final result = await showModalBottomSheet<ShareCreateResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CreateShareDialog(
      pathScope: pathScope,
      bucket: bucket,
      dek: dek,
      fileName: fileName,
      contentType: contentType,
      localPath: localPath,
      lockedChoice: ShareChoice.recipient,
    ),
  );
  return result?.recipientToken;
}

Future<GeneratedShareLink?> showCreatePublicLinkDialog({
  required BuildContext context,
  required String pathScope,
  required String bucket,
  Uint8List? dek,
  String? fileName,
  String? contentType,
  String? localPath,
}) async {
  final result = await showModalBottomSheet<ShareCreateResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CreateShareDialog(
      pathScope: pathScope,
      bucket: bucket,
      dek: dek,
      fileName: fileName,
      contentType: contentType,
      localPath: localPath,
      lockedChoice: ShareChoice.public,
    ),
  );
  return result?.link;
}

Future<GeneratedShareLink?> showCreatePasswordLinkDialog({
  required BuildContext context,
  required String pathScope,
  required String bucket,
  Uint8List? dek,
  String? fileName,
  String? contentType,
  String? localPath,
}) async {
  final result = await showModalBottomSheet<ShareCreateResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CreateShareDialog(
      pathScope: pathScope,
      bucket: bucket,
      dek: dek,
      fileName: fileName,
      contentType: contentType,
      localPath: localPath,
      lockedChoice: ShareChoice.password,
    ),
  );
  return result?.link;
}

Future<ShareToken?> showCreateShareDialog({
  required BuildContext context,
  required String pathScope,
  required String bucket,
  Uint8List? dek,
}) {
  return showCreateShareForRecipientDialog(
    context: context,
    pathScope: pathScope,
    bucket: bucket,
  );
}

// ============================================================================
// Tag share entry points
// ============================================================================

/// Open the share sheet for a tag, locked to public-link.
Future<GeneratedShareLink?> showCreateTagPublicLinkDialog({
  required BuildContext context,
  required String tagId,
  required String tagName,
}) async {
  final result = await showModalBottomSheet<ShareCreateResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CreateShareDialog(
      pathScope: '',
      bucket: '',
      tagId: tagId,
      tagName: tagName,
      lockedChoice: ShareChoice.public,
    ),
  );
  return result?.link;
}

/// Open the share sheet for a tag, locked to recipient.
Future<ShareToken?> showCreateTagShareForRecipientDialog({
  required BuildContext context,
  required String tagId,
  required String tagName,
}) async {
  final result = await showModalBottomSheet<ShareCreateResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CreateShareDialog(
      pathScope: '',
      bucket: '',
      tagId: tagId,
      tagName: tagName,
      lockedChoice: ShareChoice.recipient,
    ),
  );
  return result?.recipientToken;
}

/// Open the share sheet for a tag with no locked choice — user picks
/// public vs recipient. (Password is hidden inside the dialog for tag shares.)
Future<ShareCreateResult?> showCreateTagShareDialog({
  required BuildContext context,
  required String tagId,
  required String tagName,
}) {
  return showModalBottomSheet<ShareCreateResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CreateShareDialog(
      pathScope: '',
      bucket: '',
      tagId: tagId,
      tagName: tagName,
    ),
  );
}

// ============================================================================
// Post-share confirmation dialog
// ============================================================================

/// Confirmation dialog shown after a share/link has been created. Matches the
/// UX used by the file/folder share flow in
/// `lib/features/browser/screens/file_browser_screen.dart`
/// (`_showGeneratedShareLinkDialog` and `_showShareLinkDialog`) — the user
/// sees the URL, expiry, and an explicit Copy Link button instead of having
/// the link auto-copied behind their back.
///
/// [result] supplies whether this is a public/password/recipient share, plus
/// either the link object or the recipient token. For recipient shares the
/// URL is reconstructed via `SharingService.generateShareLink`.
Future<void> showShareCreatedDialog({
  required BuildContext context,
  required ShareCreateResult result,
}) async {
  // Resolve the URL and the underlying token depending on the share type.
  String? url;
  ShareToken? token;
  if (result.link != null) {
    url = result.link!.url;
    token = result.link!.token;
  } else if (result.recipientToken != null) {
    token = result.recipientToken;
    url = SharingService.instance.generateShareLink(result.recipientToken!);
  }
  if (url == null) return;

  String title;
  String description;
  IconData infoIcon;
  Color infoColor;
  String infoText;

  switch (result.choice) {
    case ShareChoice.public:
      title = 'Link Created!';
      description = 'Anyone with this link can view the shared content.';
      infoIcon = LucideIcons.link;
      infoColor = Colors.blue;
      infoText = 'Public link';
      break;
    case ShareChoice.password:
      title = 'Password Link Created!';
      description =
          'Share this link. Recipients will need the password you set to access.';
      infoIcon = LucideIcons.lock;
      infoColor = Colors.orange;
      infoText = 'Password protected';
      break;
    case ShareChoice.recipient:
      title = 'Share Created!';
      description =
          'Share link created successfully. Send this link to the recipient:';
      infoIcon = LucideIcons.shield;
      infoColor = Theme.of(context).colorScheme.primary;
      infoText = token != null
          ? 'Permission: ${token.permissions.displayName}'
          : 'Recipient share';
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
      content: Column(
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
              url!,
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
          if (token?.expiresAt != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(LucideIcons.clock, size: 16, color: Colors.orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Expires: ${_formatRelativeExpiry(token!.expiresAt!)}',
                    style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: url!));
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
