// Unit tests for buildContactFormSnippet — the client-side <form>+<script>
// embedded into generated websites. The deep-link logic is ported from
// TargetUriBuilder; these tests pin the load-bearing tokens (wa.me digits-only,
// mailto subject/body, encodeURIComponent) and the verifier sentinels.

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/models/contact_form_config.dart';
import 'package:fula_files/core/utils/contact_form_snippet.dart';

void main() {
  group('buildContactFormSnippet — sentinels', () {
    test('always emits the verifier sentinels id="cf" and encodeURIComponent', () {
      const cfg = ContactFormConfig(
        enabled: true,
        destination: '15551234567',
        fields: [ContactFormField(label: 'Name')],
      );
      final html = buildContactFormSnippet(cfg);
      expect(html, contains('id="cf"'));
      expect(html, contains('encodeURIComponent'));
      // Client-side only: no action attribute, no server submission.
      expect(html, isNot(contains('action=')));
    });
  });

  group('buildContactFormSnippet — WhatsApp channel', () {
    const cfg = ContactFormConfig(
      enabled: true,
      channel: ContactFormChannel.whatsapp,
      destination: '+1 (555) 123-4567',
      fields: [ContactFormField(label: 'Name', required: true)],
    );

    test('builds a wa.me URL and strips non-digits at send time', () {
      final html = buildContactFormSnippet(cfg);
      expect(html, contains("'https://wa.me/'"));
      expect(html, contains(r"DEST.replace(/\D/g,'')")); // digits-only
      expect(html, contains("d.slice(0,2)==='00'")); // drop 00 prefix
      expect(html, contains('d.length<7||d.length>15')); // 7–15 bound
      // The raw destination is embedded as a JS string literal; the JS
      // normalizes it (so formatting in the creator's input is fine).
      expect(html, contains(r'var DEST="+1 (555) 123-4567"'));
      expect(html, isNot(contains('mailto:')));
    });

    test('required field carries data-req', () {
      final html = buildContactFormSnippet(cfg);
      expect(html, contains('data-label="Name"'));
      expect(html, contains('data-req="1"'));
    });
  });

  group('buildContactFormSnippet — Email channel', () {
    const cfg = ContactFormConfig(
      enabled: true,
      channel: ContactFormChannel.email,
      destination: 'hello@example.com',
      emailSubject: 'New enquiry',
      fields: [ContactFormField(label: 'Message', type: ContactFormFieldType.multiline)],
    );

    test('builds a mailto URL with encoded subject and body', () {
      final html = buildContactFormSnippet(cfg);
      expect(html, contains("'mailto:'+to"));
      expect(html, contains('DEST.split(')); // address sanitized
      expect(html, contains('encodeURIComponent(subj)'));
      expect(html, contains('encodeURIComponent(body)'));
      expect(html, contains('var DEST="hello@example.com"'));
      expect(html, contains('"New enquiry"'));
      expect(html, isNot(contains('wa.me')));
    });
  });

  group('buildContactFormSnippet — field rendering', () {
    test('each field type renders the right control', () {
      const cfg = ContactFormConfig(
        enabled: true,
        destination: '15551234567',
        fields: [
          ContactFormField(label: 'Short', type: ContactFormFieldType.text),
          ContactFormField(label: 'Long', type: ContactFormFieldType.multiline),
          ContactFormField(label: 'Qty', type: ContactFormFieldType.number),
          ContactFormField(label: 'Mail', type: ContactFormFieldType.email),
          ContactFormField(
            label: 'Topics',
            type: ContactFormFieldType.multiSelect,
            options: ['A', 'B'],
          ),
        ],
      );
      final html = buildContactFormSnippet(cfg);
      expect(html, contains('type="text"'));
      expect(html, contains('<textarea'));
      expect(html, contains('type="number"'));
      expect(html, contains('type="email"'));
      expect(html, contains('data-multi="1"'));
      expect(html, contains('value="A"'));
      expect(html, contains('value="B"'));
    });

    test('blank-labelled fields are skipped', () {
      const cfg = ContactFormConfig(
        enabled: true,
        destination: '15551234567',
        fields: [
          ContactFormField(label: 'Keep'),
          ContactFormField(label: '  '),
        ],
      );
      final html = buildContactFormSnippet(cfg);
      expect('data-label='.allMatches(html).length, 1);
    });

    test('labels with HTML metacharacters are escaped in attributes and text', () {
      const cfg = ContactFormConfig(
        enabled: true,
        destination: '15551234567',
        fields: [ContactFormField(label: 'A & B <"x">')],
      );
      final html = buildContactFormSnippet(cfg);
      expect(html, contains('data-label="A &amp; B &lt;&quot;x&quot;&gt;"'));
      expect(html, isNot(contains('<"x">')));
    });
  });

  group('buildContactFormSnippet — hardening & UX', () {
    test('neutralizes </script> in a creator-supplied subject', () {
      const cfg = ContactFormConfig(
        enabled: true,
        channel: ContactFormChannel.email,
        destination: 'me@example.com',
        emailSubject: 'Hi </script> there',
        fields: [ContactFormField(label: 'Name')],
      );
      final html = buildContactFormSnippet(cfg);
      expect(html, contains(r'Hi <\/script> there'));
      expect(html, isNot(contains('Hi </script>')));
    });

    test('sanitizes the mailto address against header smuggling', () {
      final html = buildContactFormSnippet(const ContactFormConfig(
        enabled: true,
        channel: ContactFormChannel.email,
        destination: 'me@example.com',
        fields: [ContactFormField(label: 'Name')],
      ));
      expect(html, contains(r'DEST.split(/[?#&\s]/)[0]'));
    });

    test('blocks empty submissions and offers a deep-link fallback', () {
      final html = buildContactFormSnippet(const ContactFormConfig(
        enabled: true,
        destination: '15551234567',
        fields: [ContactFormField(label: 'Name')],
      ));
      expect(html, contains('Please fill in the form before sending'));
      expect(html, contains('visibilityState'));
    });

    test('caps free-text input length to keep deep-link URLs valid', () {
      final html = buildContactFormSnippet(const ContactFormConfig(
        enabled: true,
        destination: '15551234567',
        fields: [
          ContactFormField(label: 'Msg', type: ContactFormFieldType.multiline),
        ],
      ));
      expect(html, contains('maxlength="2000"'));
    });
  });
}
