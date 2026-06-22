import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/features/ai_connections/models/ai_connection.dart';
import 'package:fula_files/features/ai_connections/providers/ai_connections_provider.dart';
import 'package:fula_files/features/ai_connections/screens/ai_activity_screen.dart';

/// P13 — "AI Connections": list saved MCP pairings and create new ones.
///
/// Creating a connection mints a one-time **bundle** (gateway JWT + secrets) and
/// shows it in a copyable, "shown once" dialog. FxFiles persists only the
/// non-secret record (the MCP public key + label); the bundle's secrets are
/// never stored, so the user must copy it before dismissing — losing it means
/// creating a new connection.
class AiConnectionsScreen extends ConsumerWidget {
  const AiConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(aiConnectionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Connections'),
        actions: [
          IconButton(
            // P16 — reach the collective "AI activity" view (what AIs have
            // stored in the shared workspace).
            icon: const Icon(LucideIcons.history),
            tooltip: 'AI activity',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AiActivityScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.isBusy ? null : () => _onCreatePressed(context, ref),
        icon: const Icon(LucideIcons.plus),
        label: const Text('Create'),
      ),
      body: _buildBody(context, ref, state),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AiConnectionsState state,
  ) {
    if (state.isBusy && state.connections.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Pair an AI client (via MCP) with your encrypted AI workspace. '
            'Creating a connection generates a one-time bundle you copy into '
            'your AI client. The bundle is shown only once — only the public '
            'key is saved here.',
            style: TextStyle(fontSize: 13),
          ),
        ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              state.error!,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        Expanded(
          child: state.connections.isEmpty
              ? const _EmptyState()
              : ListView.separated(
                  itemCount: state.connections.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final c = state.connections[i];
                    return ListTile(
                      leading: const Icon(LucideIcons.bot),
                      title: Text(c.label),
                      subtitle: Text(
                        'Added ${_formatDate(c.createdAt)}\n'
                        'Key ${_shortKey(c.mcpPublicKeyB64)}',
                      ),
                      isThreeLine: true,
                      trailing: IconButton(
                        icon: const Icon(LucideIcons.trash2),
                        tooltip: 'Disconnect',
                        onPressed: state.isBusy
                            ? null
                            : () => _onDeletePressed(context, ref, c),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _onCreatePressed(BuildContext context, WidgetRef ref) async {
    final label = await _promptForLabel(context);
    if (label == null || label.trim().isEmpty) return;

    final bundle = await ref
        .read(aiConnectionsProvider.notifier)
        .createConnection(label: label.trim());

    if (!context.mounted) return;
    if (bundle == null) {
      final err = ref.read(aiConnectionsProvider).error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err ?? 'Failed to create AI connection.')),
      );
      return;
    }
    await _showBundleDialog(context, bundle);
  }

  Future<String?> _promptForLabel(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Name this connection'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. Claude Desktop',
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  /// The "shown once" bundle dialog — copyable, with an explicit warning that
  /// the secrets are not stored and won't be shown again.
  Future<void> _showBundleDialog(BuildContext context, String bundle) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: const [
            Icon(LucideIcons.alertTriangle, color: Colors.orange),
            SizedBox(width: 8),
            Expanded(child: Text('Copy your connection bundle')),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'This bundle contains secret keys and is shown ONCE. It is not '
                'stored on this device. Copy it into your AI client now — if you '
                'lose it you must create a new connection.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  bundle,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(LucideIcons.copy),
            label: const Text('Copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: bundle));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Bundle copied to clipboard')),
                );
              }
            },
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _onDeletePressed(
    BuildContext context,
    WidgetRef ref,
    AiConnection connection,
  ) async {
    // HONEST disconnect (P16). Deleting the connection record removes the only
    // copy of this pairing FxFiles holds — but it does NOT instantly cut the AI
    // off. The AI is carrying a short-lived, scoped session JWT and CANNOT
    // renew it (the issuer's refresh endpoint rejects MCP tokens → 401), so it
    // keeps working until that token reaches its `exp` — about an hour by
    // default, at most 24h if the instance configured a longer TTL — and then
    // is permanently locked out. The copy below states exactly that; it must
    // NOT imply instant revocation.
    //
    // FOLLOW-UP (documented, not built here): true ~instant revocation needs a
    // SERVER-SIDE connection-revoke. Three pieces: (1) bind the minted token's
    // `jti` to the connection's `mcp_pub_b64` at mint time; (2) add a
    // `DELETE /api/mcp/tokens/connection/{mcp_pub_b64}` endpoint that blocklists
    // that jti; (3) gate the gateway's check behind a `FULA_MCP_REVOCATION_ENABLED`
    // flag → ~30s revoke once enabled. Until then this disconnect is
    // expiry-bound, and the dialog says so truthfully.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Disconnect ${connection.label}?'),
        content: const Text(
          'This AI loses access when its current session token expires — within '
          'about an hour by default, and up to 24 hours at most. It cannot renew '
          'that token on its own, so it gets no new access after that. Files it '
          'already stored stay in your library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref
          .read(aiConnectionsProvider.notifier)
          .deleteConnection(connection.id);
    }
  }

  static String _shortKey(String b64) {
    if (b64.length <= 12) return b64;
    return '${b64.substring(0, 8)}…${b64.substring(b64.length - 4)}';
  }

  static String _formatDate(DateTime d) {
    final local = d.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.bot,
              size: 48, color: Theme.of(context).disabledColor),
          const SizedBox(height: 12),
          const Text('No AI connections yet'),
          const SizedBox(height: 4),
          const Text(
            'Tap Create to pair an AI client.',
            style: TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}
