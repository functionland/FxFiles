import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Full-screen picker for the device's system contacts. Multi-select
/// with checkboxes, live search by name. Returns the selected
/// [Contact]s to the caller (which then converts to CSV via
/// `ContactsCsvWriter`).
///
/// Permission flow: requests READ_CONTACTS on first open via
/// `FlutterContacts.requestPermission(readonly: true)`. Denial shows
/// an inline help block with a button to open system settings.
class PhoneContactsPickerScreen extends StatefulWidget {
  const PhoneContactsPickerScreen({super.key});

  @override
  State<PhoneContactsPickerScreen> createState() =>
      _PhoneContactsPickerScreenState();
}

class _PhoneContactsPickerScreenState
    extends State<PhoneContactsPickerScreen> {
  List<Contact>? _all;
  final _selected = <String>{}; // contact ids
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _permissionDenied = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() => _searchQuery = _searchCtrl.text.trim().toLowerCase());
    });
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final granted =
          await FlutterContacts.requestPermission(readonly: true);
      if (!granted) {
        if (mounted) setState(() => _permissionDenied = true);
        return;
      }
      final contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
        sorted: true,
      );
      // Keep only contacts with at least a name OR a phone OR an email —
      // empty entries (e.g. legacy stub contacts) just clutter the list.
      final useful = contacts.where((c) {
        final hasName = c.displayName.trim().isNotEmpty ||
            c.name.first.trim().isNotEmpty ||
            c.name.last.trim().isNotEmpty;
        return hasName || c.phones.isNotEmpty || c.emails.isNotEmpty;
      }).toList();
      if (!mounted) return;
      setState(() => _all = useful);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e.toString());
    }
  }

  List<Contact> get _filtered {
    final all = _all ?? const [];
    if (_searchQuery.isEmpty) return all;
    return all.where((c) {
      final hay = (c.displayName +
              c.phones.map((p) => p.number).join(' ') +
              c.emails.map((e) => e.address).join(' '))
          .toLowerCase();
      return hay.contains(_searchQuery);
    }).toList();
  }

  void _toggle(Contact c) {
    setState(() {
      if (_selected.contains(c.id)) {
        _selected.remove(c.id);
      } else {
        _selected.add(c.id);
      }
    });
  }

  void _selectAllVisible() {
    setState(() {
      for (final c in _filtered) {
        _selected.add(c.id);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selected.clear());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick contacts'),
        actions: [
          if (_all != null && _all!.isNotEmpty)
            TextButton(
              onPressed: _selected.isEmpty
                  ? _selectAllVisible
                  : _clearSelection,
              child: Text(_selected.isEmpty
                  ? 'Select all'
                  : 'Clear (${_selected.length})'),
            ),
          TextButton(
            onPressed: _selected.isEmpty ? null : _confirm,
            child: const Text('Done'),
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_permissionDenied) return _buildPermissionDenied(theme);
    if (_loadError != null) return _buildError(theme);
    final all = _all;
    if (all == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (all.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No usable contacts on this device.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final filtered = _filtered;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              prefixIcon: const Icon(LucideIcons.search, size: 18),
              hintText: 'Search ${all.length} contacts…',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    'No matches for "$_searchQuery"',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                )
              : ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 64),
                  itemBuilder: (_, i) {
                    final c = filtered[i];
                    final isSelected = _selected.contains(c.id);
                    final subtitle = _subtitleFor(c);
                    return CheckboxListTile(
                      value: isSelected,
                      onChanged: (_) => _toggle(c),
                      title: Text(
                        c.displayName.isEmpty
                            ? '(no name)'
                            : c.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: subtitle.isEmpty
                          ? null
                          : Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                    );
                  },
                ),
        ),
        if (_selected.isNotEmpty)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: theme.dividerColor),
              ),
              color: theme.colorScheme.surfaceContainerHigh,
            ),
            child: Row(
              children: [
                Text(
                  '${_selected.length} selected',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _confirm,
                  icon: const Icon(LucideIcons.check, size: 16),
                  label: const Text('Use as recipients'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _subtitleFor(Contact c) {
    final parts = <String>[];
    if (c.phones.isNotEmpty) parts.add(c.phones.first.number);
    if (c.emails.isNotEmpty) parts.add(c.emails.first.address);
    return parts.join(' · ');
  }

  Widget _buildPermissionDenied(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.userX, size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            'Contacts permission denied',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'FxFiles needs read-only access to your contacts to import them '
            'as recipients. Contacts are never modified or uploaded.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => ph.openAppSettings(),
            child: const Text('Open settings'),
          ),
          TextButton(
            onPressed: () {
              setState(() => _permissionDenied = false);
              _load();
            },
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  Widget _buildError(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          'Failed to load contacts: $_loadError',
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      ),
    );
  }

  void _confirm() {
    final all = _all ?? const <Contact>[];
    final picked = all.where((c) => _selected.contains(c.id)).toList();
    Navigator.of(context).pop(picked);
  }
}
