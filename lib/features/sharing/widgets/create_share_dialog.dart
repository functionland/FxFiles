import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/core/models/sync_state.dart';
import 'package:fula_files/core/services/local_storage_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/features/sharing/providers/sharing_provider.dart';

/// Dialog for creating a share link for a specific recipient
class CreateShareForRecipientDialog extends ConsumerStatefulWidget {
  final String pathScope;
  final String bucket;
  final Uint8List dek;
  final String? fileName;
  final String? contentType;
  final String? localPath; // Local file path to fetch CID from SyncState

  const CreateShareForRecipientDialog({
    super.key,
    required this.pathScope,
    required this.bucket,
    required this.dek,
    this.fileName,
    this.contentType,
    this.localPath,
  });

  @override
  ConsumerState<CreateShareForRecipientDialog> createState() =>
      _CreateShareForRecipientDialogState();
}

class _CreateShareForRecipientDialogState
    extends ConsumerState<CreateShareForRecipientDialog> {
  final _formKey = GlobalKey<FormState>();
  final _recipientKeyController = TextEditingController();
  final _recipientNameController = TextEditingController();
  final _labelController = TextEditingController();

  SharePermissions _permissions = SharePermissions.readOnly;
  ShareMode _shareMode = ShareMode.snapshot;
  int? _expiryDays = 7;
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _recipientKeyController.dispose();
    _recipientNameController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _pasteRecipientKey() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      setState(() {
        _recipientKeyController.text = data.text!.trim();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(LucideIcons.userPlus),
          const SizedBox(width: 8),
          const Expanded(child: Text('Create Link For...')),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Path being shared
                _PathDisplay(pathScope: widget.pathScope),
                const SizedBox(height: 16),

                // Recipient Name
                TextFormField(
                  controller: _recipientNameController,
                  decoration: const InputDecoration(
                    labelText: 'Recipient Name',
                    hintText: 'e.g., John, Team Lead',
                    prefixIcon: Icon(LucideIcons.user),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a name';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Recipient Share ID
                TextFormField(
                  controller: _recipientKeyController,
                  decoration: InputDecoration(
                    labelText: 'Recipient\'s Share ID',
                    hintText: 'FULA-xxx... or paste their key',
                    prefixIcon: const Icon(LucideIcons.fingerprint),
                    helperText: 'Ask them for their Share ID from Settings',
                    suffixIcon: IconButton(
                      icon: const Icon(LucideIcons.clipboard),
                      tooltip: 'Paste from clipboard',
                      onPressed: _pasteRecipientKey,
                    ),
                  ),
                  maxLines: 1,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter the recipient\'s Share ID';
                    }
                    final trimmed = value.trim();
                    if (trimmed.toUpperCase().startsWith('FULA-')) {
                      if (trimmed.length < 10) {
                        return 'Invalid Share ID format';
                      }
                    } else if (trimmed.length < 20) {
                      return 'Invalid key format';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Permissions
                _PermissionsSelector(
                  value: _permissions,
                  onChanged: (v) => setState(() => _permissions = v),
                ),
                const SizedBox(height: 16),

                // Share Mode
                _ShareModeSelector(
                  value: _shareMode,
                  onChanged: (v) => setState(() => _shareMode = v),
                ),
                const SizedBox(height: 16),

                // Expiry
                _ExpirySelector(
                  value: _expiryDays,
                  onChanged: (v) => setState(() => _expiryDays = v),
                  showNever: true,
                ),
                const SizedBox(height: 16),

                // Label (optional)
                TextFormField(
                  controller: _labelController,
                  decoration: const InputDecoration(
                    labelText: 'Label (optional)',
                    hintText: 'e.g., Project files',
                    prefixIcon: Icon(LucideIcons.tag),
                  ),
                ),

                // Error message
                if (_error != null) _ErrorDisplay(error: _error!),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _isLoading ? null : _createShare,
          icon: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(LucideIcons.share2),
          label: const Text('Create Link'),
        ),
      ],
    );
  }

  /// Check if a string is a valid IPFS CID
  /// CIDv1: bafy... (dag-pb), bafk... (raw), bafz... (dag-cbor), etc.
  /// CIDv0: Qm... (base58)
  bool _isValidCid(String value) {
    // CIDv1 base32: starts with 'baf' and is typically 50+ chars
    if (value.startsWith('baf') && value.length >= 50) {
      return true;
    }
    // CIDv0 base58: starts with 'Qm' and is 46 chars
    if (value.startsWith('Qm') && value.length == 46) {
      return true;
    }
    return false;
  }

  /// Get CID from SyncState (ETag contains CID after gateway update)
  Future<String?> _getCidForFile() async {
    if (widget.localPath == null) return null;

    final syncState = LocalStorageService.instance.getSyncState(widget.localPath!);
    if (syncState == null || syncState.status != SyncStatus.synced) return null;

    // ETag now contains the CID (bafybeig..., bafkr4i..., or Qm...)
    final etag = syncState.etag;
    if (etag != null && _isValidCid(etag)) {
      return etag;
    }

    // Fallback: fetch from API if local etag doesn't have CID
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
    return null;
  }

  Future<void> _createShare() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final notifier = ref.read(sharesProvider.notifier);

      // Get CID for SnapshotBinding (needed for both modes to embed in URL)
      final cid = await _getCidForFile();
      final syncState = widget.localPath != null
          ? LocalStorageService.instance.getSyncState(widget.localPath!)
          : null;

      SnapshotBinding? snapshotBinding;
      if (cid != null && syncState != null) {
        snapshotBinding = SnapshotBinding(
          contentHash: syncState.etag ?? cid,
          size: syncState.localSize ?? 0,
          modifiedAt: syncState.lastSyncedAt?.millisecondsSinceEpoch ??
              DateTime.now().millisecondsSinceEpoch,
          storageKey: cid, // IPFS CID for gateway to fetch
        );
      }

      final token = await notifier.createShare(
        pathScope: widget.pathScope,
        bucket: widget.bucket,
        recipientPublicKeyBase64: _recipientKeyController.text.trim(),
        recipientName: _recipientNameController.text.trim(),
        dek: widget.dek,
        permissions: _permissions,
        expiryDays: _expiryDays,
        label: _labelController.text.trim().isNotEmpty
            ? _labelController.text.trim()
            : null,
        shareMode: _shareMode,
        snapshotBinding: snapshotBinding,
        fileName: widget.fileName,
        contentType: widget.contentType,
      );

      if (!mounted) return;

      if (token != null) {
        Navigator.pop(context, token);
      } else {
        final error = ref.read(sharesProvider).error;
        setState(() {
          _error = error ?? 'Failed to create share';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }
}

/// Dialog for creating a public link that anyone can access
class CreatePublicLinkDialog extends ConsumerStatefulWidget {
  final String pathScope;
  final String bucket;
  final Uint8List dek;
  final String? fileName;
  final String? contentType;
  final String? localPath; // Local file path to fetch CID from SyncState

  const CreatePublicLinkDialog({
    super.key,
    required this.pathScope,
    required this.bucket,
    required this.dek,
    this.fileName,
    this.contentType,
    this.localPath,
  });

  @override
  ConsumerState<CreatePublicLinkDialog> createState() =>
      _CreatePublicLinkDialogState();
}

class _CreatePublicLinkDialogState
    extends ConsumerState<CreatePublicLinkDialog> {
  final _labelController = TextEditingController();

  ShareMode _shareMode = ShareMode.snapshot;
  ShareExpiry _expiry = ShareExpiry.oneWeek;
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(LucideIcons.link),
          const SizedBox(width: 8),
          const Expanded(child: Text('Create Link')),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Info box
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.info, color: Colors.blue[700], size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Anyone with this link can view the file',
                        style: TextStyle(color: Colors.blue[700]),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Path being shared
              _PathDisplay(pathScope: widget.pathScope),
              const SizedBox(height: 16),

              // Share Mode
              _ShareModeSelector(
                value: _shareMode,
                onChanged: (v) => setState(() => _shareMode = v),
              ),
              const SizedBox(height: 16),

              // Expiry
              const Text(
                'Link Expires',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ShareExpiry.values.map((exp) {
                  return ChoiceChip(
                    label: Text(exp.displayName),
                    selected: _expiry == exp,
                    onSelected: (_) => setState(() => _expiry = exp),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),

              // Label (optional)
              TextFormField(
                controller: _labelController,
                decoration: const InputDecoration(
                  labelText: 'Label (optional)',
                  hintText: 'e.g., Project files',
                  prefixIcon: Icon(LucideIcons.tag),
                ),
              ),

              // Error message
              if (_error != null) _ErrorDisplay(error: _error!),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _isLoading ? null : _createLink,
          icon: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(LucideIcons.link),
          label: const Text('Create Link'),
        ),
      ],
    );
  }

  /// Check if a string is a valid IPFS CID
  bool _isValidCid(String value) {
    // CIDv1 base32: starts with 'baf' (bafy, bafk, bafz, etc.) and is typically 50+ chars
    if (value.startsWith('baf') && value.length >= 50) {
      return true;
    }
    // CIDv0 base58: starts with 'Qm' and is 46 chars
    if (value.startsWith('Qm') && value.length == 46) {
      return true;
    }
    return false;
  }

  /// Get CID from SyncState (ETag contains CID after gateway update)
  Future<String?> _getCidForFile() async {
    if (widget.localPath == null) return null;

    final syncState = LocalStorageService.instance.getSyncState(widget.localPath!);
    if (syncState == null || syncState.status != SyncStatus.synced) return null;

    // ETag now contains the CID (bafybeig..., bafkr4i..., or Qm...)
    final etag = syncState.etag;
    if (etag != null && _isValidCid(etag)) {
      return etag;
    }

    // Fallback: fetch from API if local etag doesn't have CID
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
    return null;
  }

  Future<void> _createLink() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final notifier = ref.read(sharesProvider.notifier);

      // Get CID for SnapshotBinding (needed for both modes to embed in URL)
      final cid = await _getCidForFile();
      final syncState = widget.localPath != null
          ? LocalStorageService.instance.getSyncState(widget.localPath!)
          : null;

      SnapshotBinding? snapshotBinding;
      if (cid != null && syncState != null) {
        snapshotBinding = SnapshotBinding(
          contentHash: syncState.etag ?? cid,
          size: syncState.localSize ?? 0,
          modifiedAt: syncState.lastSyncedAt?.millisecondsSinceEpoch ??
              DateTime.now().millisecondsSinceEpoch,
          storageKey: cid, // IPFS CID for gateway to fetch
        );
      }

      final result = await notifier.createPublicLink(
        pathScope: widget.pathScope,
        bucket: widget.bucket,
        dek: widget.dek,
        expiryDays: _expiry.days,
        label: _labelController.text.trim().isNotEmpty
            ? _labelController.text.trim()
            : null,
        shareMode: _shareMode,
        snapshotBinding: snapshotBinding,
        fileName: widget.fileName,
        contentType: widget.contentType,
      );

      if (!mounted) return;

      if (result != null) {
        Navigator.pop(context, result);
      } else {
        final error = ref.read(sharesProvider).error;
        setState(() {
          _error = error ?? 'Failed to create link';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }
}

/// Dialog for creating a password-protected link
class CreatePasswordLinkDialog extends ConsumerStatefulWidget {
  final String pathScope;
  final String bucket;
  final Uint8List dek;
  final String? fileName;
  final String? contentType;
  final String? localPath; // Local file path to fetch CID from SyncState

  const CreatePasswordLinkDialog({
    super.key,
    required this.pathScope,
    required this.bucket,
    required this.dek,
    this.fileName,
    this.contentType,
    this.localPath,
  });

  @override
  ConsumerState<CreatePasswordLinkDialog> createState() =>
      _CreatePasswordLinkDialogState();
}

class _CreatePasswordLinkDialogState
    extends ConsumerState<CreatePasswordLinkDialog> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _labelController = TextEditingController();

  ShareMode _shareMode = ShareMode.snapshot;
  ShareExpiry _expiry = ShareExpiry.oneWeek;
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(LucideIcons.lock),
          const SizedBox(width: 8),
          const Expanded(child: Text('Create Link with Password')),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Info box
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(LucideIcons.shieldCheck,
                          color: Colors.orange[700], size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Recipients need both the link AND password to view',
                          style: TextStyle(color: Colors.orange[700]),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Path being shared
                _PathDisplay(pathScope: widget.pathScope),
                const SizedBox(height: 16),

                // Password
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    hintText: 'Enter a strong password',
                    prefixIcon: const Icon(LucideIcons.key),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword
                          ? LucideIcons.eye
                          : LucideIcons.eyeOff),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a password';
                    }
                    if (value.length < 4) {
                      return 'Password must be at least 4 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Confirm Password
                TextFormField(
                  controller: _confirmPasswordController,
                  obscureText: _obscurePassword,
                  decoration: const InputDecoration(
                    labelText: 'Confirm Password',
                    hintText: 'Re-enter password',
                    prefixIcon: Icon(LucideIcons.keyRound),
                  ),
                  validator: (value) {
                    if (value != _passwordController.text) {
                      return 'Passwords do not match';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Share Mode
                _ShareModeSelector(
                  value: _shareMode,
                  onChanged: (v) => setState(() => _shareMode = v),
                ),
                const SizedBox(height: 16),

                // Expiry
                const Text(
                  'Link Expires',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ShareExpiry.values.map((exp) {
                    return ChoiceChip(
                      label: Text(exp.displayName),
                      selected: _expiry == exp,
                      onSelected: (_) => setState(() => _expiry = exp),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                // Label (optional)
                TextFormField(
                  controller: _labelController,
                  decoration: const InputDecoration(
                    labelText: 'Label (optional)',
                    hintText: 'e.g., Confidential files',
                    prefixIcon: Icon(LucideIcons.tag),
                  ),
                ),

                // Error message
                if (_error != null) _ErrorDisplay(error: _error!),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _isLoading ? null : _createLink,
          icon: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(LucideIcons.lock),
          label: const Text('Create Link'),
        ),
      ],
    );
  }

  /// Check if a string is a valid IPFS CID
  bool _isValidCid(String value) {
    // CIDv1 base32: starts with 'baf' (bafy, bafk, bafz, etc.) and is typically 50+ chars
    if (value.startsWith('baf') && value.length >= 50) {
      return true;
    }
    // CIDv0 base58: starts with 'Qm' and is 46 chars
    if (value.startsWith('Qm') && value.length == 46) {
      return true;
    }
    return false;
  }

  /// Get CID from SyncState (ETag contains CID after gateway update)
  Future<String?> _getCidForFile() async {
    if (widget.localPath == null) return null;

    final syncState = LocalStorageService.instance.getSyncState(widget.localPath!);
    if (syncState == null || syncState.status != SyncStatus.synced) return null;

    // ETag now contains the CID (bafybeig..., bafkr4i..., or Qm...)
    final etag = syncState.etag;
    if (etag != null && _isValidCid(etag)) {
      return etag;
    }

    // Fallback: fetch from API if local etag doesn't have CID
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
    return null;
  }

  Future<void> _createLink() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final notifier = ref.read(sharesProvider.notifier);

      // Get CID for SnapshotBinding (needed for both modes to embed in URL)
      final cid = await _getCidForFile();
      final syncState = widget.localPath != null
          ? LocalStorageService.instance.getSyncState(widget.localPath!)
          : null;

      SnapshotBinding? snapshotBinding;
      if (cid != null && syncState != null) {
        snapshotBinding = SnapshotBinding(
          contentHash: syncState.etag ?? cid,
          size: syncState.localSize ?? 0,
          modifiedAt: syncState.lastSyncedAt?.millisecondsSinceEpoch ??
              DateTime.now().millisecondsSinceEpoch,
          storageKey: cid, // IPFS CID for gateway to fetch
        );
      }

      final result = await notifier.createPasswordProtectedLink(
        pathScope: widget.pathScope,
        bucket: widget.bucket,
        dek: widget.dek,
        expiryDays: _expiry.days,
        password: _passwordController.text,
        label: _labelController.text.trim().isNotEmpty
            ? _labelController.text.trim()
            : null,
        shareMode: _shareMode,
        snapshotBinding: snapshotBinding,
        fileName: widget.fileName,
        contentType: widget.contentType,
      );

      if (!mounted) return;

      if (result != null) {
        Navigator.pop(context, result);
      } else {
        final error = ref.read(sharesProvider).error;
        setState(() {
          _error = error ?? 'Failed to create link';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }
}

// ============================================================================
// SHARED WIDGETS
// ============================================================================

class _PathDisplay extends StatelessWidget {
  final String pathScope;

  const _PathDisplay({required this.pathScope});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.folder, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              pathScope,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionsSelector extends StatelessWidget {
  final SharePermissions value;
  final ValueChanged<SharePermissions> onChanged;

  const _PermissionsSelector({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Permissions',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        ...SharePermissions.values.map((perm) {
          final isSelected = perm == value;
          return ListTile(
            title: Text(perm.displayName),
            subtitle: Text(_getPermissionDescription(perm)),
            leading: Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color:
                  isSelected ? Theme.of(context).colorScheme.primary : null,
            ),
            onTap: () => onChanged(perm),
            contentPadding: EdgeInsets.zero,
            dense: true,
          );
        }),
      ],
    );
  }

  String _getPermissionDescription(SharePermissions perm) {
    switch (perm) {
      case SharePermissions.readOnly:
        return 'View and download files';
      case SharePermissions.readWrite:
        return 'View, download, and upload files';
      case SharePermissions.full:
        return 'Full access including delete';
    }
  }
}

class _ShareModeSelector extends StatelessWidget {
  final ShareMode value;
  final ValueChanged<ShareMode> onChanged;

  const _ShareModeSelector({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Version Access',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        ...ShareMode.values.map((mode) {
          final isSelected = mode == value;
          return ListTile(
            title: Text(mode.displayName),
            subtitle: Text(mode.description),
            leading: Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color:
                  isSelected ? Theme.of(context).colorScheme.primary : null,
            ),
            onTap: () => onChanged(mode),
            contentPadding: EdgeInsets.zero,
            dense: true,
          );
        }),
      ],
    );
  }
}

class _ExpirySelector extends StatelessWidget {
  final int? value;
  final ValueChanged<int?> onChanged;
  final bool showNever;

  const _ExpirySelector({
    required this.value,
    required this.onChanged,
    this.showNever = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Expiry',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _ExpiryChip(
              label: '7 days',
              days: 7,
              selected: value == 7,
              onSelected: () => onChanged(7),
            ),
            _ExpiryChip(
              label: '30 days',
              days: 30,
              selected: value == 30,
              onSelected: () => onChanged(30),
            ),
            _ExpiryChip(
              label: '90 days',
              days: 90,
              selected: value == 90,
              onSelected: () => onChanged(90),
            ),
            if (showNever)
              _ExpiryChip(
                label: 'Never',
                days: null,
                selected: value == null,
                onSelected: () => onChanged(null),
              ),
          ],
        ),
      ],
    );
  }
}

class _ExpiryChip extends StatelessWidget {
  final String label;
  final int? days;
  final bool selected;
  final VoidCallback onSelected;

  const _ExpiryChip({
    required this.label,
    required this.days,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
    );
  }
}

class _ErrorDisplay extends StatelessWidget {
  final String error;

  const _ErrorDisplay({required this.error});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorColor = theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: errorColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.alertCircle, color: errorColor, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                error,
                style: TextStyle(color: errorColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// DIALOG HELPERS
// ============================================================================

/// Shows dialog for creating a share for a specific recipient
Future<ShareToken?> showCreateShareForRecipientDialog({
  required BuildContext context,
  required String pathScope,
  required String bucket,
  required Uint8List dek,
  String? fileName,
  String? contentType,
  String? localPath,
}) async {
  return showDialog<ShareToken>(
    context: context,
    builder: (context) => CreateShareForRecipientDialog(
      pathScope: pathScope,
      bucket: bucket,
      dek: dek,
      fileName: fileName,
      contentType: contentType,
      localPath: localPath,
    ),
  );
}

/// Shows dialog for creating a public link
Future<GeneratedShareLink?> showCreatePublicLinkDialog({
  required BuildContext context,
  required String pathScope,
  required String bucket,
  required Uint8List dek,
  String? fileName,
  String? contentType,
  String? localPath,
}) async {
  return showDialog<GeneratedShareLink>(
    context: context,
    builder: (context) => CreatePublicLinkDialog(
      pathScope: pathScope,
      bucket: bucket,
      dek: dek,
      fileName: fileName,
      contentType: contentType,
      localPath: localPath,
    ),
  );
}

/// Shows dialog for creating a password-protected link
Future<GeneratedShareLink?> showCreatePasswordLinkDialog({
  required BuildContext context,
  required String pathScope,
  required String bucket,
  required Uint8List dek,
  String? fileName,
  String? contentType,
  String? localPath,
}) async {
  return showDialog<GeneratedShareLink>(
    context: context,
    builder: (context) => CreatePasswordLinkDialog(
      pathScope: pathScope,
      bucket: bucket,
      dek: dek,
      fileName: fileName,
      contentType: contentType,
      localPath: localPath,
    ),
  );
}

// Keep backward compatibility
typedef CreateShareDialog = CreateShareForRecipientDialog;

Future<ShareToken?> showCreateShareDialog({
  required BuildContext context,
  required String pathScope,
  required String bucket,
  required Uint8List dek,
}) async {
  return showCreateShareForRecipientDialog(
    context: context,
    pathScope: pathScope,
    bucket: bucket,
    dek: dek,
  );
}
