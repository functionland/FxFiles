import 'package:flutter/material.dart';

import 'package:fula_files/shared/legal/terms_content.dart';

/// The Terms text itself: every section of [kTermsSections] plus the
/// last-updated line. Shared by the native first-run gate, the web gate and
/// the read-only screens both settings pages link to.
class TermsOfServiceBody extends StatelessWidget {
  const TermsOfServiceBody({super.key, this.controller});

  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      controller: controller,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final section in kTermsSections)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    section.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(section.body, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Text(
            'Last updated: $kTermsLastUpdated',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

/// Full-screen Terms gate: the Accept button unlocks once the reader has
/// reached the end of the text. [onAccept] records the acceptance.
class TermsAcceptanceScreen extends StatefulWidget {
  const TermsAcceptanceScreen({
    super.key,
    required this.onAccept,
    this.isUpdate = false,
  });

  final Future<void> Function() onAccept;

  /// True when the user accepted an earlier version: the heading says the
  /// Terms changed rather than asking as if for the first time.
  final bool isUpdate;

  @override
  State<TermsAcceptanceScreen> createState() => _TermsAcceptanceScreenState();
}

class _TermsAcceptanceScreenState extends State<TermsAcceptanceScreen> {
  final ScrollController _scrollController = ScrollController();
  bool _hasScrolledToBottom = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_checkScrolledToBottom);
    // A window tall enough to show everything never scrolls, so the listener
    // would never fire and Accept would stay disabled for good.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkScrolledToBottom());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_checkScrolledToBottom);
    _scrollController.dispose();
    super.dispose();
  }

  void _checkScrolledToBottom() {
    if (_hasScrolledToBottom || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 50) {
      setState(() => _hasScrolledToBottom = true);
    }
  }

  Future<void> _accept() async {
    setState(() => _saving = true);
    try {
      await widget.onAccept();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    children: [
                      Icon(
                        Icons.description_outlined,
                        size: 48,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.isUpdate
                            ? 'Updated Terms of Service'
                            : 'Terms of Service',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.isUpdate
                            ? 'Our terms have changed. Please read and accept them to continue.'
                            : 'Please read and accept our terms to continue',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      border: Border.all(color: theme.dividerColor),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: TermsOfServiceBody(controller: _scrollController),
                    ),
                  ),
                ),
                if (!_hasScrolledToBottom)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.arrow_downward,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Scroll to read all terms',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _hasScrolledToBottom && !_saving
                              ? _accept
                              : null,
                          child: const Text('I Accept the Terms of Service'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'By clicking "Accept", you acknowledge that you have read, understood, and agree to be bound by these terms.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Read-only Terms, opened from the settings screens.
class TermsOfServicePage extends StatelessWidget {
  const TermsOfServicePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Terms of Service')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: const TermsOfServiceBody(),
        ),
      ),
    );
  }
}
