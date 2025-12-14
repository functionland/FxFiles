import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/core/models/share_token.dart';
import 'package:fula_files/features/sharing/providers/sharing_provider.dart';

/// Dialog for creating a new share
class CreateShareDialog extends ConsumerStatefulWidget {
  final String pathScope;
  final String bucket;
  final Uint8List dek;

  const CreateShareDialog({
    super.key,
    required this.pathScope,
    required this.bucket,
    required this.dek,
  });

  @override
  ConsumerState<CreateShareDialog> createState() => _CreateShareDialogState();
}

class _CreateShareDialogState extends ConsumerState<CreateShareDialog> {
  final _formKey = GlobalKey<FormState>();
  final _recipientKeyController = TextEditingController();
  final _recipientNameController = TextEditingController();
  final _labelController = TextEditingController();
  
  SharePermissions _permissions = SharePermissions.readOnly;
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
    return AlertDialog(
      title: Row(
        children: [
          const Icon(LucideIcons.share2),
          const SizedBox(width: 8),
          const Expanded(child: Text('Share')),
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
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(LucideIcons.folder, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.pathScope,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
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
                    // Validate format - FULA- prefix or base64
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
                const Text(
                  'Permissions',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                ...SharePermissions.values.map((perm) {
                  final isSelected = perm == _permissions;
                  return ListTile(
                    title: Text(perm.displayName),
                    subtitle: Text(_getPermissionDescription(perm)),
                    leading: Icon(
                      isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: isSelected ? Theme.of(context).colorScheme.primary : null,
                    ),
                    onTap: () => setState(() => _permissions = perm),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  );
                }),
                const SizedBox(height: 16),

                // Expiry
                const Text(
                  'Expiry',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    _ExpiryChip(
                      label: '7 days',
                      days: 7,
                      selected: _expiryDays == 7,
                      onSelected: () => setState(() => _expiryDays = 7),
                    ),
                    _ExpiryChip(
                      label: '30 days',
                      days: 30,
                      selected: _expiryDays == 30,
                      onSelected: () => setState(() => _expiryDays = 30),
                    ),
                    _ExpiryChip(
                      label: '90 days',
                      days: 90,
                      selected: _expiryDays == 90,
                      onSelected: () => setState(() => _expiryDays = 90),
                    ),
                    _ExpiryChip(
                      label: 'Never',
                      days: null,
                      selected: _expiryDays == null,
                      onSelected: () => setState(() => _expiryDays = null),
                    ),
                  ],
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
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red[50],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(LucideIcons.alertCircle, color: Colors.red, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
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
          label: const Text('Create Share'),
        ),
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

  Future<void> _createShare() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final notifier = ref.read(sharesProvider.notifier);
      
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

/// Shows the create share dialog and returns the created token
Future<ShareToken?> showCreateShareDialog({
  required BuildContext context,
  required String pathScope,
  required String bucket,
  required Uint8List dek,
}) async {
  return showDialog<ShareToken>(
    context: context,
    builder: (context) => CreateShareDialog(
      pathScope: pathScope,
      bucket: bucket,
      dek: dek,
    ),
  );
}
