import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/shared/legal/terms_content.dart';

void main() {
  group('Terms content', () {
    test('carries the beta and FULA token section', () {
      final beta = kTermsSections.firstWhere(
        (s) => s.title.contains('Beta Software and FULA Token'),
      );
      expect(beta.body, contains('beta software under active testing'));
      expect(beta.body, contains('Do not rely on FxFiles as your only copy'));
      expect(beta.body,
          contains('for testing and demonstration purposes only'));
      expect(beta.body, contains('not an investment or financial product'));
      expect(beta.body, contains('Limitation of Liability'));
    });

    test('numbered sections run 1..N without gaps or repeats', () {
      final numbers = kTermsSections
          .map((s) => RegExp(r'^(\d+)\. ').firstMatch(s.title)?.group(1))
          .whereType<String>()
          .map(int.parse)
          .toList();
      expect(numbers, List.generate(numbers.length, (i) => i + 1));
    });

    // The existing clauses were moved, not rewritten — spot-check the ones
    // that carry the most weight.
    test('keeps the existing clauses verbatim', () {
      final all = kTermsSections.map((s) => s.body).join('\n');
      expect(all, contains('IMPORTANT: No copies of your private encryption keys are stored.'));
      expect(all, contains('THE APP IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND'));
      expect(all, contains('TO THE MAXIMUM EXTENT PERMITTED BY LAW'));
      expect(all, contains('You must NOT transfer tokens'));
      expect(all, contains('These Terms take effect on September 9, 2026.'));
    });

    test('the acknowledgements say what the owner approved', () {
      expect(kBetaGenerateAcknowledgement,
          'I understand this app is in beta testing, generated content may not be '
          'reliable or accessible, and integration with Fula token is for testing '
          'and demo use.');
      expect(kBetaUploadAcknowledgement, contains('uploaded files may not be reliably stored'));
      expect(kBetaUploadAcknowledgement, contains('keep my own copies'));
      expect(kBetaUploadAcknowledgement,
          contains('integration with Fula token is for testing and demo use'));
    });
  });

  group('termsAcceptanceRequired', () {
    test('nothing recorded -> required', () {
      expect(termsAcceptanceRequired(acceptedVersion: null, legacyAccepted: false), isTrue);
    });

    // Every existing native user holds only the pre-versioning boolean: they
    // accepted version 1 and must see the new section.
    test('legacy acceptance counts as version 1 and is not enough now', () {
      expect(kTermsVersion, greaterThan(1));
      expect(termsAcceptanceRequired(acceptedVersion: null, legacyAccepted: true), isTrue);
    });

    test('the current version satisfies it', () {
      expect(termsAcceptanceRequired(acceptedVersion: kTermsVersion, legacyAccepted: false), isFalse);
      expect(termsAcceptanceRequired(acceptedVersion: kTermsVersion, legacyAccepted: true), isFalse);
    });

    test('an older recorded version does not', () {
      expect(termsAcceptanceRequired(acceptedVersion: kTermsVersion - 1, legacyAccepted: true), isTrue);
    });

    test('a newer recorded version (a later build) is accepted', () {
      expect(termsAcceptanceRequired(acceptedVersion: kTermsVersion + 1, legacyAccepted: false), isFalse);
    });
  });

  group('parseAcceptedTermsVersion', () {
    test('reads stored versions and rejects garbage', () {
      expect(parseAcceptedTermsVersion('2'), 2);
      expect(parseAcceptedTermsVersion(' 3 '), 3);
      expect(parseAcceptedTermsVersion(null), isNull);
      expect(parseAcceptedTermsVersion(''), isNull);
      expect(parseAcceptedTermsVersion('true'), isNull);
      expect(parseAcceptedTermsVersion('0'), isNull);
      expect(parseAcceptedTermsVersion('-1'), isNull);
    });
  });
}
