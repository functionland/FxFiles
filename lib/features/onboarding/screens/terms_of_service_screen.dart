import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/features/settings/providers/settings_provider.dart';
import 'package:fula_files/shared/widgets/terms_of_service_view.dart';

/// Native first-run (and Terms-update) gate. The text and the scroll-to-read
/// rule live in the shared [TermsAcceptanceScreen], so native and web show the
/// same Terms.
class TermsOfServiceScreen extends ConsumerWidget {
  final VoidCallback onAccepted;

  /// An earlier version was accepted; present the Terms as an update.
  final bool isUpdate;

  const TermsOfServiceScreen({
    super.key,
    required this.onAccepted,
    this.isUpdate = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TermsAcceptanceScreen(
      isUpdate: isUpdate,
      onAccept: () async {
        await ref.read(settingsProvider.notifier).setTosAccepted(true);
        onAccepted();
      },
    );
  }
}
