/// The FxFiles Terms of Service and the acknowledgements that point back to
/// them — ONE source, rendered by the native first-run screen, the web shell,
/// and the settings links on both.
///
/// Pure Dart (no Flutter import) so it is unit-testable and shared with the
/// web compile graph.
library;

/// Bump whenever the Terms change in a way every user must see and accept
/// again. Anyone whose recorded acceptance is older is shown the Terms before
/// they can use the app.
///
///   1  the original terms (a plain "accepted" flag, no version recorded)
///   2  2026-09-16: adds "Beta Software and FULA Token"
const int kTermsVersion = 2;

const String kTermsLastUpdated = 'September 16, 2026';

/// Required tick in the popup shown before generating a website or social
/// post. Wording approved by the project owner.
const String kBetaGenerateAcknowledgement =
    'I understand this app is in beta testing, generated content may not be '
    'reliable or accessible, and integration with Fula token is for testing '
    'and demo use.';

/// Required tick in the popup shown before every user-initiated upload.
const String kBetaUploadAcknowledgement =
    'I understand this app is in beta testing, uploaded files may not be '
    'reliably stored or remain accessible (I will keep my own copies of '
    'anything important), and integration with Fula token is for testing and '
    'demo use.';

class TermsSection {
  const TermsSection(this.title, this.body);
  final String title;
  final String body;
}

const List<TermsSection> kTermsSections = [
  TermsSection(
    'Welcome to FxFiles',
    'FxFiles ("the App") is free and open-source software released under the MIT License. '
        'It is maintained by independent open-source contributors who are not affiliated with, '
        'or acting on behalf of, any party or entity.\n\n'
        'These Terms take effect on September 9, 2026. Development carried out before that date '
        'was done as part of Functionland.\n\n'
        'By using the App, '
        'you agree to be bound by these Terms of Service. If you do not agree to these terms, '
        'please do not use the App.',
  ),
  TermsSection(
    '1. Service Description',
    'FxFiles is a file management application that provides cloud storage and synchronization services. '
        'The service is provided on an "as is" and "as available" basis without warranties of any kind.',
  ),
  TermsSection(
    '2. Beta Software and FULA Token',
    'FxFiles is beta software under active testing. Features may change, fail or be discontinued '
        'without notice.\n\n'
        'Content you upload or generate - including files, websites, links, previews and NFTs - may be '
        'unreliable, incomplete, inaccessible or permanently lost, and the third-party networks and '
        'gateways that serve it are outside our control. Do not rely on FxFiles as your only copy of '
        'anything.\n\n'
        'Any integration with the FULA token, including credits, payments, wallets and NFTs, is for '
        'testing and demonstration purposes only, carries no guarantee of value, and is not an '
        'investment or financial product.\n\n'
        'You use FxFiles and any FULA feature at your own risk; the Limitation of Liability, No Warranty '
        'and Indemnification sections of these Terms apply in full.',
  ),
  TermsSection(
    '3. Backup Storage Classification',
    'IMPORTANT: At this point, the Fula network and FxFiles backup storage should be considered either:\n\n'
        '- ARCHIVAL and SECONDARY backup, OR\n'
        '- SHORT-TERM and TEMPORARY backup\n\n'
        'until these terms are updated to mention otherwise.\n\n'
        'You should NOT rely on this service as your sole or primary backup solution. '
        'Always maintain independent backups of your important data.',
  ),
  TermsSection(
    '4. Service Termination',
    'The service may be terminated, suspended, or modified at any time. '
        'In the event of service termination, we will provide a minimum of TWO (2) WEEKS advance notice '
        'via email or in-app notification.\n\n'
        'IT IS YOUR SOLE RESPONSIBILITY to download and migrate your data before the termination date. '
        'No entity or contributor shall be liable for any data loss resulting from service termination.',
  ),
  TermsSection(
    '5. Use at Your Own Risk',
    'You use this App entirely AT YOUR OWN RISK. No entity or contributor shall be liable for any direct, '
        'indirect, incidental, special, consequential, or exemplary damages, including but not limited to:\n\n'
        '- Loss of data or files\n'
        '- Loss of profits or business opportunities\n'
        '- Service interruptions\n'
        '- Device damage or malfunction\n'
        '- Any other damages arising from your use of the App',
  ),
  TermsSection(
    '6. Encryption and Security',
    'The App employs industry-standard encryption algorithms to protect your data. However, '
        'NO ENCRYPTION IS ABSOLUTELY SECURE.\n\n'
        'You acknowledge and agree that:\n\n'
        '- Encryption technology may become vulnerable due to technological advances, newly discovered vulnerabilities, '
        'or unforeseen bugs\n'
        '- If at any point encrypted files become decryptable due to technological advances, security vulnerabilities, '
        'or any other reason, no entity or contributor shall be held responsible\n'
        '- This is an edge technology and security guarantees cannot be absolute\n'
        '- You should not store extremely sensitive information solely relying on this encryption',
  ),
  TermsSection(
    '7. Private Keys and Account Access',
    'IMPORTANT: No copies of your private encryption keys are stored.\n\n'
        'You acknowledge and understand that:\n\n'
        '- Your encryption key is derived from your sign-in credentials (email/Google account)\n'
        '- If you lose access to the email address used to sign in, you may PERMANENTLY LOSE access to your encrypted data\n'
        '- If Google or other authentication providers change their signature creation methods, your key derivation may change, '
        'potentially resulting in loss of access to previously encrypted data\n'
        '- IT IS YOUR RESPONSIBILITY to back up your private key and store it securely\n'
        '- Your private key can be viewed and copied in the App Settings\n'
        '- Your data cannot be recovered if you lose your private key',
  ),
  TermsSection(
    '8. Data Ownership and Responsibility',
    'You retain ownership of all data you upload to the service. You are solely responsible for:\n\n'
        '- Maintaining backups of your important data\n'
        '- Ensuring you have legal rights to upload and store your content\n'
        '- Any consequences of sharing your data with others',
  ),
  TermsSection(
    '9. Limitation of Liability',
    'TO THE MAXIMUM EXTENT PERMITTED BY LAW, no entity, contributor, or their affiliates, officers, directors, '
        'employees, and agents shall not be liable for any claims, damages, losses, or expenses arising '
        'from or related to:\n\n'
        '- Your use or inability to use the App\n'
        '- Unauthorized access to your data\n'
        '- Data loss, corruption, or encryption failures\n'
        '- Service interruptions or termination\n'
        '- Third-party actions or services\n'
        '- Any other matter relating to the service',
  ),
  TermsSection(
    '10. Internal NFT Wallet Disclaimer',
    'IMPORTANT: This App is NOT a wallet application. The App includes an internal NFT wallet solely '
        'for the purpose of holding NFTs generated by the App.\n\n'
        'You acknowledge and agree that:\n\n'
        '- The internal NFT wallet should ONLY be used to hold NFTs generated by the App and nothing else\n'
        '- You must NOT transfer tokens (cryptocurrency, ERC-20 tokens, or any other digital assets) to the internal wallet\n'
        '- If you transfer tokens to the internal wallet, any and all responsibility is solely yours\n'
        '- No entity or contributor is responsible for any loss as a cause of keeping, '
        'transferring, or holding tokens in the internal wallet\n'
        '- The internal wallet is not designed, audited, or intended for general-purpose asset storage',
  ),
  TermsSection(
    '11. No Warranty',
    'THE APP IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO '
        'WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND NON-INFRINGEMENT.\n\n'
        'We do not warrant that:\n'
        '- The App will meet your requirements\n'
        '- The App will be uninterrupted, timely, secure, or error-free\n'
        '- Any errors will be corrected',
  ),
  TermsSection(
    '12. Indemnification',
    'You agree that no entity, contributor, or maintainer bears liability for any claims, '
        'damages, losses, or expenses arising from your use of the App or violation of these terms.',
  ),
  TermsSection(
    '13. Changes to Terms',
    'We reserve the right to modify these terms at any time. Continued use of the App after changes '
        'constitutes acceptance of the modified terms.',
  ),
  TermsSection(
    '14. Contact',
    'For questions about these Terms of Service, please open a GitHub issue or discussion at github.com/functionland/FxFiles/issues',
  ),
];

/// An accepted Terms version as stored as text (web localStorage), or null
/// when absent or not a valid version.
int? parseAcceptedTermsVersion(String? raw) {
  if (raw == null) return null;
  final version = int.tryParse(raw.trim());
  return (version == null || version < 1) ? null : version;
}

/// Whether the user must (re)accept the Terms before using the app.
///
/// [acceptedVersion] is the version recorded at acceptance, or null when none
/// was recorded. [legacyAccepted] is the pre-versioning boolean: acceptance
/// recorded that way was of version 1, so it no longer satisfies a newer
/// version.
bool termsAcceptanceRequired({
  required int? acceptedVersion,
  required bool legacyAccepted,
}) {
  final effective = acceptedVersion ?? (legacyAccepted ? 1 : 0);
  return effective < kTermsVersion;
}
