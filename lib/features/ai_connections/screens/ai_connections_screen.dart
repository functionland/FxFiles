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
        onPressed: state.isBusy ? null : () => _onConnectPressed(context, ref),
        icon: const Icon(LucideIcons.plus),
        label: const Text('Connect'),
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
            'Pair an AI client (via MCP) with your encrypted AI workspace.\n'
            '• Connect an AI — generates a one-time bundle you paste into a '
            'local AI client (Claude Desktop, a CLI). Shown only once.\n'
            '• Connect a hosted AI — sign in to your own hosted Worker so a web '
            'AI (Claude.ai, ChatGPT) can reach your workspace through it.\n'
            'Either way, only the public key is saved here — no secrets.',
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
                    final isHosted = c.kind == AiConnectionKind.hosted;
                    return ListTile(
                      leading: Icon(
                        isHosted ? LucideIcons.cloud : LucideIcons.bot,
                      ),
                      title: Row(
                        children: [
                          Flexible(child: Text(c.label)),
                          if (isHosted) ...[
                            const SizedBox(width: 8),
                            const _HostedChip(),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        'Added ${_formatDate(c.createdAt)}\n'
                        'Key ${_shortKey(c.mcpPublicKeyB64)}'
                        '${isHosted && c.workerUrl != null ? '\n${c.workerUrl}' : ''}',
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

  /// The "Connect" entry point — choose between the local paste-bundle flow and
  /// the hosted-Worker flow (H5).
  Future<void> _onConnectPressed(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<_ConnectChoice>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.bot),
              title: const Text('Connect an AI'),
              subtitle: const Text(
                'Local client (Claude Desktop, a CLI) — copy a one-time bundle.',
              ),
              onTap: () => Navigator.of(context).pop(_ConnectChoice.local),
            ),
            ListTile(
              leading: const Icon(LucideIcons.cloud),
              title: const Text('Connect a hosted AI'),
              subtitle: const Text(
                'Web AI (Claude.ai, ChatGPT) — sign in to your hosted Worker.',
              ),
              onTap: () => Navigator.of(context).pop(_ConnectChoice.hosted),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case _ConnectChoice.local:
        await _onCreatePressed(context, ref);
      case _ConnectChoice.hosted:
        await _onCreateHostedPressed(context, ref);
    }
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

  /// Hosted-connect (H5): prompt for the Worker URL (https) + a label, then run
  /// the OAuth + capability-delivery flow via the provider.
  Future<void> _onCreateHostedPressed(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final details = await _promptForHostedDetails(context);
    if (details == null) return;

    if (!context.mounted) return;
    // Surface that an external sign-in is about to open.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Opening hosted AI sign-in…'),
        duration: Duration(seconds: 2),
      ),
    );

    final ok = await ref.read(aiConnectionsProvider.notifier).createHostedConnection(
          label: details.label,
          workerUrl: details.workerUrl,
        );

    if (!context.mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected ${details.label}.')),
      );
    } else {
      final err = ref.read(aiConnectionsProvider).error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err ?? 'Failed to connect the hosted AI.'),
        ),
      );
    }
  }

  /// Prompt for the hosted Worker URL + a label. Validates the URL is https
  /// before returning; returns null if the user cancels.
  Future<_HostedDetails?> _promptForHostedDetails(BuildContext context) {
    final urlController = TextEditingController();
    final labelController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<_HostedDetails>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect a hosted AI'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: urlController,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Hosted Worker URL',
                  hintText: 'https://fula-mcp.<you>.workers.dev',
                ),
                validator: (v) {
                  final t = (v ?? '').trim();
                  final uri = Uri.tryParse(t);
                  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
                    return 'Enter a valid https:// URL';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: labelController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Claude.ai',
                ),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Enter a name' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(context).pop(
                  _HostedDetails(
                    workerUrl: urlController.text.trim(),
                    label: labelController.text.trim(),
                  ),
                );
              }
            },
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
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
    // HONEST, HARD-FAIL disconnect (L1d). Disconnect performs a SERVER-SIDE
    // connection revoke and removes the local record ONLY when that revoke
    // succeeds: the service POSTs `/api/mcp/connections/:id/revoke` (by the
    // persisted connectionId, session-JWT auth). On success the gateway cuts the
    // AI's access within ~30s and the AI cannot self-renew. It REQUIRES reaching
    // the server — if the revoke fails (offline / signed out / server error) the
    // record is KEPT and the AI still has access until a successful disconnect.
    // Records created before L1d (no connectionId) have no server connection to
    // revoke and are removed locally. The copy below states exactly this; it
    // must stay truthful (do NOT claim access always ends at token expiry — that
    // is false once the connection holds a refresh token).
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Disconnect ${connection.label}?'),
        content: const Text(
          'This revokes the AI\'s access on the server — it loses access within '
          'about 30 seconds and cannot reconnect on its own. This needs to reach '
          'the server: if it fails, the AI still has access until you '
          'successfully disconnect. Files it already stored stay in your library.',
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
    if (confirmed != true) return;

    final ok = await ref
        .read(aiConnectionsProvider.notifier)
        .deleteConnection(connection.id);

    if (!context.mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Disconnected ${connection.label}.')),
      );
    } else {
      // Hard-fail: the connection is still in the list. Surface the truthful
      // error so the user does not believe a failed disconnect succeeded.
      final err = ref.read(aiConnectionsProvider).error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            err ??
                "Couldn't disconnect — the AI may still have access. "
                    'Check your connection and try again.',
          ),
        ),
      );
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
            'Tap Connect to pair a local or hosted AI client.',
            style: TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// Which connect flow the user picked from the "Connect" chooser.
enum _ConnectChoice { local, hosted }

/// The validated inputs for a hosted-connect attempt.
class _HostedDetails {
  const _HostedDetails({required this.workerUrl, required this.label});
  final String workerUrl;
  final String label;
}

/// A small "Hosted" badge shown on hosted connection rows.
class _HostedChip extends StatelessWidget {
  const _HostedChip();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'Hosted',
        style: TextStyle(
          fontSize: 11,
          color: scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
