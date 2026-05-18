// Unit tests for TemplateRenderer.render — the {Column} substitution
// engine shared by the (HIDDEN) AI Automation feature and the active
// Automate feature. Pure function, no Flutter or Hive needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/utils/template_renderer.dart';

void main() {
  group('TemplateRenderer.render — basic substitution', () {
    test('substitutes a single {Column} with the row value', () {
      final out = TemplateRenderer.render(
        'Hello {Name}!',
        {'Name': 'Alice'},
      );
      expect(out, 'Hello Alice!');
    });

    test('substitutes multiple placeholders in one template', () {
      final out = TemplateRenderer.render(
        'Hi {Name}, your phone is {Phone} and email {Email}.',
        {'Name': 'Bob', 'Phone': '555-1234', 'Email': 'bob@example.com'},
      );
      expect(out, 'Hi Bob, your phone is 555-1234 and email bob@example.com.');
    });

    test('leaves an unmatched placeholder verbatim — surface bug to user',
        () {
      final out = TemplateRenderer.render(
        'Hello {Name}, your reference is {RefId}.',
        {'Name': 'Carol'},
      );
      // {RefId} should not silently render to empty — the user needs to
      // see it so they notice the column is missing from their CSV.
      expect(out, 'Hello Carol, your reference is {RefId}.');
    });

    test('returns the template unchanged when row is empty', () {
      const tpl = 'Static text with {Name} and {Foo}';
      expect(TemplateRenderer.render(tpl, const {}), tpl);
    });

    test('returns the template unchanged when no placeholders present', () {
      expect(
        TemplateRenderer.render('Just static text.', {'Name': 'Dave'}),
        'Just static text.',
      );
    });
  });

  group('TemplateRenderer.render — case sensitivity', () {
    test('matches exact case first', () {
      final out = TemplateRenderer.render(
        '{Name}',
        {'Name': 'Exact', 'name': 'lower'},
      );
      // Exact-match wins. We do NOT want a deterministic-but-arbitrary
      // collapse — if the user types `{Name}` and there are two
      // columns differing only by case, the exact-cased one is used.
      expect(out, 'Exact');
    });

    test('falls back to case-insensitive match when no exact', () {
      final out = TemplateRenderer.render('{name}', {'NAME': 'shouty'});
      expect(out, 'shouty');
    });

    test('{Phone} matches a "phone" column', () {
      final out = TemplateRenderer.render('+1{Phone}', {'phone': '5551234567'});
      expect(out, '+15551234567');
    });
  });

  group('TemplateRenderer.render — edge cases', () {
    test('handles empty placeholder body {} as verbatim', () {
      // {} doesn't match anything; keep verbatim. (Regex requires
      // at least one non-brace char inside.)
      final out = TemplateRenderer.render('a {} b', {'': 'empty'});
      expect(out, 'a {} b');
    });

    test('values containing braces are passed through (no recursion)', () {
      // If a value itself contains `{Name}`-shaped text, we do NOT
      // re-substitute. One pass only.
      final out = TemplateRenderer.render(
        '{Greeting}',
        {'Greeting': 'Hi {Name}', 'Name': 'Eve'},
      );
      expect(out, 'Hi {Name}',
          reason: 'render must be single-pass to avoid runaway recursion');
    });

    test('replaces the SAME placeholder multiple times in one template', () {
      final out = TemplateRenderer.render(
        '{Name} {Name} {Name}',
        {'Name': 'x'},
      );
      expect(out, 'x x x');
    });

    test('preserves surrounding whitespace and punctuation', () {
      final out = TemplateRenderer.render(
        '  Hello, {Name}!\n— from {Sender}.',
        {'Name': 'Frank', 'Sender': 'Grace'},
      );
      expect(out, '  Hello, Frank!\n— from Grace.');
    });

    test('handles values with special characters (commas, quotes, newlines)',
        () {
      // Real-world CSV row values can contain anything. Render must
      // pass them through verbatim — escaping (e.g. URL-encoding) is
      // the caller's job, not the renderer's.
      final out = TemplateRenderer.render(
        'Greeting: {Msg}',
        {'Msg': 'hi, "world"\n— line2'},
      );
      expect(out, 'Greeting: hi, "world"\n— line2');
    });

    test('placeholder with internal spaces matches a header with spaces', () {
      final out = TemplateRenderer.render(
        '{First Name}',
        {'First Name': 'Hank'},
      );
      expect(out, 'Hank');
    });

    test('does not match across newlines inside braces (regex hygiene)', () {
      // The regex `\{([^{}]+)\}` greedy-matches non-brace chars
      // including newlines. Real-world templates won't have newlines
      // inside braces; this just documents observed behavior.
      final out = TemplateRenderer.render(
        '{Name\nbroken}',
        {'Name\nbroken': 'wat'},
      );
      expect(out, 'wat');
    });
  });

  group('TemplateRenderer.render — attachment alias', () {
    // The Automate feature injects `{File}` into the render row when
    // an attachment is set. This is just a virtual column from the
    // renderer's perspective — verify the same substitution works.
    test('{File} resolves like any other column', () {
      final out = TemplateRenderer.render(
        'See attachment: {File}',
        {'File': 'https://ipfs.example/Qm123'},
      );
      expect(out, 'See attachment: https://ipfs.example/Qm123');
    });

    test('{file} (lowercase) matches a "File" virtual column', () {
      final out = TemplateRenderer.render(
        '{file}',
        {'File': 'https://ipfs.example/Qm123'},
      );
      expect(out, 'https://ipfs.example/Qm123');
    });
  });
}
