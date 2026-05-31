// Guards the Recreate round-trip: a `ContactForm:` JSON header line must parse
// back into a ContactFormConfig AND stay out of the user-editable body.

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/contact_form_config.dart';
import 'package:fula_files/features/websites/widgets/generation_status_card.dart';

void main() {
  test('parseStoredPrompt round-trips a contact form, keeps userBody clean', () {
    const cfg = ContactFormConfig(
      enabled: true,
      channel: ContactFormChannel.email,
      destination: 'me@example.com',
      fields: [ContactFormField(label: 'Name', required: true)],
    );
    final stored = 'Website Name: My Site\n'
        'Category: Shop\n'
        'Palette: Warm\n'
        'ContactForm: ${cfg.encode()}\n'
        '\n'
        'Make it pop.';

    final parsed = parseStoredPrompt(stored);

    expect(parsed.websiteName, 'My Site');
    expect(parsed.category, 'Shop');
    expect(parsed.palette, 'Warm');
    expect(parsed.userBody, 'Make it pop.');
    expect(parsed.userBody, isNot(contains('ContactForm')));
    expect(parsed.contactForm?.enabled, isTrue);
    expect(parsed.contactForm?.channel, ContactFormChannel.email);
    expect(parsed.contactForm?.fields.single.label, 'Name');
  });

  test('parseStoredPrompt returns null contactForm when absent', () {
    final parsed =
        parseStoredPrompt('Website Name: X\nCategory: Other\n\nbody');
    expect(parsed.contactForm, isNull);
    expect(parsed.userBody, 'body');
  });
}
