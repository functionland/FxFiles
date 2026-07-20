import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/contact_form_config.dart';
import 'package:fula_files/core/services/website_prompt_builder.dart';

void main() {
  group('composeEnrichedWebsitePrompt', () {
    test('writes the header lines the hidden-instruction regexes key off',
        () {
      final p = composeEnrichedWebsitePrompt(
        websiteName: 'My Portfolio',
        category: 'Personal',
        styles: ['Minimal', 'Theme support'],
        palette: 'Warm',
        body: 'A site about me.',
      );
      expect(p, startsWith('Website Name: My Portfolio\n'));
      expect(p, contains('\nCategory: Personal\n'));
      expect(p, contains('\nStyles: Minimal, Theme support\n'));
      expect(p, contains('\nPalette: Warm\n'));
      expect(p, endsWith('A site about me.'));
      expect(p.contains('ContactForm:'), isFalse);
    });

    test('includes the ContactForm header only when enabled', () {
      const cfg = ContactFormConfig(
        enabled: true,
        destination: '+1 555 123 4567',
        fields: [ContactFormField(label: 'Name')],
      );
      final p = composeEnrichedWebsitePrompt(
        websiteName: 'X',
        category: 'Other',
        styles: const [],
        palette: '',
        body: 'b',
        contactForm: cfg,
      );
      expect(p, contains('ContactForm: {'));
    });
  });

  group('buildWebsiteContactFormBlock — Google Forms (sheets) channel', () {
    // The form lives in a cross-origin iframe, so the generator cannot style
    // its interior at any cost. These pin the two things the prompt CAN
    // control: that the frame stays inline in the page, and that the generator
    // is steered to style around it rather than waste effort inside it.
    const cfg = ContactFormConfig(
      enabled: true,
      channel: ContactFormChannel.sheets,
      destination: 'https://docs.google.com/forms/d/e/ABC/viewform',
      fields: [ContactFormField(label: 'Name')],
    );

    test('embeds the responder URL as an inline iframe', () {
      final b = buildWebsiteContactFormBlock(cfg);
      expect(
          b,
          contains('<iframe src="https://docs.google.com/forms/d/e/ABC/'
              'viewform?embedded=true"'));
      expect(b, contains('title="Contact form"'));
    });

    test('appends embedded=true with the right separator when the URL '
        'already has a query', () {
      final b = buildWebsiteContactFormBlock(const ContactFormConfig(
        enabled: true,
        channel: ContactFormChannel.sheets,
        destination: 'https://docs.google.com/forms/d/e/ABC/viewform?usp=sf',
      ));
      expect(b, contains('viewform?usp=sf&embedded=true'));
      expect(b.contains('?usp=sf?embedded=true'), isFalse);
    });

    test('forbids putting the form behind a popup or overlay', () {
      final b = buildWebsiteContactFormBlock(cfg).toLowerCase();
      for (final surface in [
        'modal',
        'popup',
        'dialog',
        'lightbox',
        'overlay',
        'drawer',
        'accordion',
      ]) {
        expect(b, contains(surface),
            reason: 'the prompt should name "$surface" as disallowed');
      }
      expect(b, contains('do not put it in a modal'));
      expect(b, contains('new tab'));
    });

    test('requires the form to sit inline in the page flow', () {
      final b = buildWebsiteContactFormBlock(cfg);
      expect(b, contains('PLACEMENT'));
      expect(b.toLowerCase(), contains('inline'));
      expect(b.toLowerCase(), contains('scroll'));
    });

    test('tells the generator it cannot style inside the iframe', () {
      final b = buildWebsiteContactFormBlock(cfg);
      expect(b, contains('STYLING'));
      expect(b, contains('CANNOT reach its contents'));
      // The light-surface steer is the fix for a white form on a dark site.
      expect(b.toLowerCase(), contains('light'));
    });

    test('still forbids substituting a hand-written form', () {
      final b = buildWebsiteContactFormBlock(cfg);
      expect(b, contains('do not generate your own <form> to replace it'));
    });
  });

  group('buildWebsiteAiPrompt', () {
    test('expands hidden category/style/palette blocks from header lines',
        () {
      final stored = composeEnrichedWebsitePrompt(
        websiteName: 'Shop X',
        category: 'Shop',
        styles: ['Bold'],
        palette: 'Cold',
        body: 'Sell things.',
      );
      final full = buildWebsiteAiPrompt(stored);
      expect(full, startsWith('=== SYSTEM CONSTRAINTS'));
      expect(full, contains('=== TYPE-SPECIFIC CONSTRAINTS (auto-added) ==='));
      expect(full, contains(websiteCategoryInstructions['Shop']!));
      expect(full, contains('=== STYLE PREFERENCES (auto-added) ==='));
      expect(full, contains(websiteStyleInstructions['Bold']!));
      expect(full, contains('=== PALETTE PREFERENCE (auto-added) ==='));
      expect(full, contains(websitePaletteInstructions['Cold']!));
      expect(full, contains('User request:\n'));
      expect(full, endsWith('Sell things.'));
    });

    test(
        'expands the contact-form block and strips the raw ContactForm '
        'line from the echoed request', () {
      const cfg = ContactFormConfig(
        enabled: true,
        channel: ContactFormChannel.email,
        destination: 'a@b.co',
        fields: [ContactFormField(label: 'Message')],
      );
      final stored = composeEnrichedWebsitePrompt(
        websiteName: 'X',
        category: 'Other',
        styles: const [],
        palette: '',
        body: 'hello',
        contactForm: cfg,
      );
      final full = buildWebsiteAiPrompt(stored);
      expect(full, contains('=== CONTACT FORM (auto-added'));
      expect(full, contains('id="cf"')); // verbatim snippet marker
      // The echoed user request must not carry the raw JSON line.
      final echo = full.split('User request:\n').last;
      expect(echo.contains('ContactForm:'), isFalse);
    });

    test('per-asset notes section renders with CIDs when available', () {
      final full = buildWebsiteAiPrompt(
        'Website Name: X\nCategory: Other\n\nbody',
        assetNotes: [
          (fileName: 'a.jpg', cid: 'bafyA', comment: 'hero image'),
        ],
      );
      expect(full, contains('=== ATTACHED ASSET NOTES (auto-added) ==='));
      expect(full, contains('- file: a.jpg (CID: bafyA)'));
      expect(full, contains('note: hero image'));
    });
  });

  group('parseWebsiteContactFormLine', () {
    test('round-trips the encoded config', () {
      const cfg = ContactFormConfig(
        enabled: true,
        destination: '+15551234567',
        fields: [ContactFormField(label: 'Name', required: true)],
      );
      final stored = composeEnrichedWebsitePrompt(
        websiteName: 'X',
        category: 'Other',
        styles: const [],
        palette: '',
        body: 'b',
        contactForm: cfg,
      );
      final parsed = parseWebsiteContactFormLine(stored);
      expect(parsed, isNotNull);
      expect(parsed!.enabled, isTrue);
      expect(parsed.destination, '+15551234567');
      expect(parsed.usableFields.single.label, 'Name');
      expect(parseWebsiteContactFormLine('no header here'), isNull);
    });
  });

  group('website upload caps', () {
    test('per-extension caps match the pipeline contract', () {
      expect(websiteMaxFileSizeBytesForExt('.png'), kWebsiteMaxImageBytes);
      expect(websiteMaxFileSizeBytesForExt('.PDF'),
          kWebsiteMaxBinaryDocBytes);
      expect(websiteMaxFileSizeBytesForExt('.md'), kWebsiteMaxTextBytes);
      expect(websiteMaxFileSizeBytesForExt('.exe'), 0);
    });
  });
}
