// Covers the prompt-injection seam that actually makes the contact form appear:
// buildPreviewPrompt -> _buildAiPrompt expands the `ContactForm:` header into
// the authorization block + verbatim snippet, and strips the raw JSON from the
// echoed user request. (buildPreviewPrompt is pure string work — no Hive/network.)

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/contact_form_config.dart';
import 'package:fula_files/core/services/website_service.dart';

void main() {
  group('buildPreviewPrompt — contact form injection', () {
    const cfg = ContactFormConfig(
      enabled: true,
      channel: ContactFormChannel.whatsapp,
      destination: '15551234567',
      fields: [
        ContactFormField(label: 'Name', required: true),
        ContactFormField(
          label: 'Topics',
          type: ContactFormFieldType.multiSelect,
          options: ['Sales', 'Support'],
        ),
      ],
    );

    String build({ContactFormConfig? form}) =>
        WebsiteService.instance.buildPreviewPrompt(
          websiteName: 'My Site',
          category: 'Shop',
          styles: const ['Minimal'],
          palette: 'Warm',
          body: 'Make it pop.',
          contactForm: form,
        );

    test('injects the CONTACT FORM block + verbatim snippet when enabled', () {
      final prompt = build(form: cfg);
      expect(prompt, contains('=== CONTACT FORM'));
      expect(prompt, contains('CLIENT-SIDE')); // the "NO forms" override
      expect(prompt, contains('id="cf"')); // the verbatim snippet
      expect(prompt, contains('var DEST="15551234567"'));
      expect(prompt, contains('"Name" — single-line text input (required)'));
    });

    test('does not echo the raw ContactForm JSON under User request', () {
      final prompt = build(form: cfg);
      expect(prompt, isNot(contains('ContactForm: {')));
    });

    test('omits the block entirely when no form is configured', () {
      expect(build(form: null), isNot(contains('CONTACT FORM')));
      expect(
        build(form: const ContactFormConfig(enabled: false)),
        isNot(contains('CONTACT FORM')),
      );
    });
  });
}
