import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fula_files/features/ai_connections/providers/ai_connections_provider.dart';

/// P13 — "AI Connections" screen. Lists saved connections and lets the user
/// create a new one (which shows the one-time MCP bundle). The full UI is built
/// in P13 step 6; this skeleton just wires the provider.
class AiConnectionsScreen extends ConsumerWidget {
  const AiConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch so the screen rebuilds as connections load. (UI fleshed out in step 6.)
    ref.watch(aiConnectionsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('AI Connections')),
      body: const Center(child: Text('AI Connections')),
    );
  }
}
