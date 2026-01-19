import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fula_files/features/settings/providers/settings_provider.dart';

class TermsOfServiceScreen extends ConsumerStatefulWidget {
  final VoidCallback onAccepted;

  const TermsOfServiceScreen({super.key, required this.onAccepted});

  @override
  ConsumerState<TermsOfServiceScreen> createState() => _TermsOfServiceScreenState();
}

class _TermsOfServiceScreenState extends ConsumerState<TermsOfServiceScreen> {
  bool _hasScrolledToBottom = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 50) {
      if (!_hasScrolledToBottom) {
        setState(() => _hasScrolledToBottom = true);
      }
    }
  }

  Future<void> _acceptTerms() async {
    await ref.read(settingsProvider.notifier).setTosAccepted(true);
    widget.onAccepted();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
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
                    'Terms of Service',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Please read and accept our terms to continue',
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
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSection(
                          'Welcome to FxFiles',
                          'By using FxFiles ("the App"), provided by Functionland ("we", "us", "our"), '
                          'you agree to be bound by these Terms of Service. If you do not agree to these terms, '
                          'please do not use the App.',
                        ),
                        _buildSection(
                          '1. Service Description',
                          'FxFiles is a file management application that provides cloud storage and synchronization services. '
                          'The service is provided on an "as is" and "as available" basis without warranties of any kind.',
                        ),
                        _buildSection(
                          '2. Service Termination',
                          'Functionland reserves the right to terminate, suspend, or modify the service at any time. '
                          'In the event of service termination, we will provide a minimum of TWO (2) WEEKS advance notice '
                          'via email or in-app notification.\n\n'
                          'IT IS YOUR SOLE RESPONSIBILITY to download and migrate your data before the termination date. '
                          'Functionland shall not be liable for any data loss resulting from service termination.',
                        ),
                        _buildSection(
                          '3. Use at Your Own Risk',
                          'You use this App entirely AT YOUR OWN RISK. Functionland shall not be liable for any direct, '
                          'indirect, incidental, special, consequential, or exemplary damages, including but not limited to:\n\n'
                          '- Loss of data or files\n'
                          '- Loss of profits or business opportunities\n'
                          '- Service interruptions\n'
                          '- Device damage or malfunction\n'
                          '- Any other damages arising from your use of the App',
                        ),
                        _buildSection(
                          '4. Encryption and Security',
                          'Functionland employs industry-standard encryption algorithms to protect your data. However, '
                          'NO ENCRYPTION IS ABSOLUTELY SECURE.\n\n'
                          'You acknowledge and agree that:\n\n'
                          '- Encryption technology may become vulnerable due to technological advances, newly discovered vulnerabilities, '
                          'or unforeseen bugs\n'
                          '- If at any point encrypted files become decryptable due to technological advances, security vulnerabilities, '
                          'or any other reason, Functionland shall NOT be held responsible\n'
                          '- This is an edge technology and security guarantees cannot be absolute\n'
                          '- You should not store extremely sensitive information solely relying on this encryption',
                        ),
                        _buildSection(
                          '5. Private Keys and Account Access',
                          'IMPORTANT: Functionland does NOT store copies of your private encryption keys.\n\n'
                          'You acknowledge and understand that:\n\n'
                          '- Your encryption key is derived from your sign-in credentials (email/Google account)\n'
                          '- If you lose access to the email address used to sign in, you may PERMANENTLY LOSE access to your encrypted data\n'
                          '- If Google or other authentication providers change their signature creation methods, your key derivation may change, '
                          'potentially resulting in loss of access to previously encrypted data\n'
                          '- IT IS YOUR RESPONSIBILITY to back up your private key and store it securely\n'
                          '- Your private key can be viewed and copied in the App Settings\n'
                          '- Functionland cannot recover your data if you lose your private key',
                        ),
                        _buildSection(
                          '6. Data Ownership and Responsibility',
                          'You retain ownership of all data you upload to the service. You are solely responsible for:\n\n'
                          '- Maintaining backups of your important data\n'
                          '- Ensuring you have legal rights to upload and store your content\n'
                          '- Any consequences of sharing your data with others',
                        ),
                        _buildSection(
                          '7. Limitation of Liability',
                          'TO THE MAXIMUM EXTENT PERMITTED BY LAW, Functionland and its affiliates, officers, directors, '
                          'employees, and agents shall not be liable for any claims, damages, losses, or expenses arising '
                          'from or related to:\n\n'
                          '- Your use or inability to use the App\n'
                          '- Unauthorized access to your data\n'
                          '- Data loss, corruption, or encryption failures\n'
                          '- Service interruptions or termination\n'
                          '- Third-party actions or services\n'
                          '- Any other matter relating to the service',
                        ),
                        _buildSection(
                          '8. No Warranty',
                          'THE APP IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO '
                          'WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND NON-INFRINGEMENT.\n\n'
                          'We do not warrant that:\n'
                          '- The App will meet your requirements\n'
                          '- The App will be uninterrupted, timely, secure, or error-free\n'
                          '- Any errors will be corrected',
                        ),
                        _buildSection(
                          '9. Indemnification',
                          'You agree to indemnify, defend, and hold harmless Functionland and its affiliates from any claims, '
                          'damages, losses, or expenses arising from your use of the App or violation of these terms.',
                        ),
                        _buildSection(
                          '10. Changes to Terms',
                          'We reserve the right to modify these terms at any time. Continued use of the App after changes '
                          'constitutes acceptance of the modified terms.',
                        ),
                        _buildSection(
                          '11. Contact',
                          'For questions about these Terms of Service, please contact us at support@fx.land',
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Last updated: January 2026',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (!_hasScrolledToBottom)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                      onPressed: _hasScrolledToBottom ? _acceptTerms : null,
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
    );
  }

  Widget _buildSection(String title, String content) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            content,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
