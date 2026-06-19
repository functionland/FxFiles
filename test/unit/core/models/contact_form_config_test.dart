// Unit tests for ContactFormConfig — the plain-Dart (no Hive) model that is
// serialized to a single-line JSON `ContactForm:` header inside a generation's
// stored prompt. The round-trip and single-line guarantees are load-bearing
// for retry/Recreate and for the header-line regex, so they're asserted here.

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/contact_form_config.dart';

void main() {
  group('ContactFormConfig round-trip', () {
    test('whatsapp config with fields survives encode/decode', () {
      const cfg = ContactFormConfig(
        enabled: true,
        channel: ContactFormChannel.whatsapp,
        destination: '+1 (555) 123-4567',
        fields: [
          ContactFormField(label: 'Name', required: true),
          ContactFormField(label: 'Message', type: ContactFormFieldType.multiline),
        ],
      );

      final decoded = ContactFormConfig.tryParse(cfg.encode())!;

      expect(decoded.enabled, isTrue);
      expect(decoded.channel, ContactFormChannel.whatsapp);
      expect(decoded.destination, '+1 (555) 123-4567');
      expect(decoded.fields, hasLength(2));
      expect(decoded.fields[0].label, 'Name');
      expect(decoded.fields[0].required, isTrue);
      expect(decoded.fields[1].type, ContactFormFieldType.multiline);
    });

    test('multiSelect options are preserved', () {
      const cfg = ContactFormConfig(
        enabled: true,
        fields: [
          ContactFormField(
            label: 'Interested in',
            type: ContactFormFieldType.multiSelect,
            options: ['Sales', 'Support', 'Press'],
          ),
        ],
      );

      final decoded = ContactFormConfig.tryParse(cfg.encode())!;
      expect(decoded.fields.single.type, ContactFormFieldType.multiSelect);
      expect(decoded.fields.single.options, ['Sales', 'Support', 'Press']);
    });

    test('email subject round-trips; empty subject is omitted from JSON', () {
      const withSubject = ContactFormConfig(
        enabled: true,
        channel: ContactFormChannel.email,
        destination: 'me@example.com',
        emailSubject: 'New lead',
      );
      expect(withSubject.encode(), contains('emailSubject'));
      expect(ContactFormConfig.tryParse(withSubject.encode())!.emailSubject,
          'New lead');

      const noSubject = ContactFormConfig(
        enabled: true,
        channel: ContactFormChannel.email,
        destination: 'me@example.com',
      );
      expect(noSubject.encode(), isNot(contains('emailSubject')));
    });

    test('title round-trips; empty title is omitted from JSON', () {
      const withTitle = ContactFormConfig(
        enabled: true,
        destination: '15551234567',
        title: 'My Shop',
        fields: [ContactFormField(label: 'Name')],
      );
      expect(withTitle.encode(), contains('title'));
      expect(ContactFormConfig.tryParse(withTitle.encode())!.title, 'My Shop');

      const noTitle = ContactFormConfig(
        enabled: true,
        destination: '15551234567',
        fields: [ContactFormField(label: 'Name')],
      );
      expect(noTitle.encode(), isNot(contains('title')));
      expect(ContactFormConfig.tryParse(noTitle.encode())!.title, '');
    });

    test('encode() is single-line even when a label contains a newline', () {
      const cfg = ContactFormConfig(
        enabled: true,
        fields: [ContactFormField(label: 'Line1\nLine2')],
      );
      // The header-line regex is `^ContactForm:\s*(.*)$` (multiLine, `.` does
      // not cross newlines), so the encoded value must contain no raw newline.
      expect(cfg.encode(), isNot(contains('\n')));
      // ...and the newline still survives decode (escaped, not lost).
      expect(ContactFormConfig.tryParse(cfg.encode())!.fields.single.label,
          'Line1\nLine2');
    });
  });

  group('ContactFormConfig tolerance', () {
    test('tryParse returns null on empty/garbage input', () {
      expect(ContactFormConfig.tryParse(''), isNull);
      expect(ContactFormConfig.tryParse('   '), isNull);
      expect(ContactFormConfig.tryParse('not json'), isNull);
      expect(ContactFormConfig.tryParse('[1,2,3]'), isNull);
    });

    test('unknown enum names fall back to defaults', () {
      final decoded = ContactFormConfig.fromJson({
        'enabled': true,
        'channel': 'telegram', // not a valid channel
        'fields': [
          {'label': 'X', 'type': 'color'} // not a valid field type
        ],
      });
      expect(decoded.channel, ContactFormChannel.whatsapp);
      expect(decoded.fields.single.type, ContactFormFieldType.text);
    });

    test('usableFields drops blank-labelled fields', () {
      const cfg = ContactFormConfig(
        enabled: true,
        fields: [
          ContactFormField(label: 'Keep'),
          ContactFormField(label: '   '),
          ContactFormField(label: ''),
        ],
      );
      expect(cfg.usableFields, hasLength(1));
      expect(cfg.usableFields.single.label, 'Keep');
    });
  });
}
