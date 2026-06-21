import 'package:flutter_test/flutter_test.dart';
import 'package:fula_files/core/services/website_prompt_builder.dart';

/// Deterministic gate for the website-languages feature (the external advisor
/// bench is unavailable, so these checks carry the verification): the ≤3 cap,
/// the compose→store→parse round-trip incl. the "no line ⇒ English" default,
/// and the AI-prompt block (present for multi, absent for English-only, with an
/// RTL note for Arabic/Farsi and no national flags).
String _compose(List<String> languages) => composeEnrichedWebsitePrompt(
      websiteName: 'Acme',
      category: 'Portfolio',
      styles: const <String>[],
      palette: '',
      body: 'Make it nice.',
      languages: languages,
    );

void main() {
  group('compose — Languages line', () {
    test('English-only is the default → NO Languages line (byte-identical)', () {
      expect(_compose(const ['English']).contains('Languages:'), isFalse);
    });

    test('single non-English writes the line', () {
      expect(_compose(const ['French']), contains('Languages: French'));
    });

    test('multiple writes a comma list', () {
      expect(
        _compose(const ['English', 'French', 'Arabic']),
        contains('Languages: English, French, Arabic'),
      );
    });

    test('caps at 3 even if more are passed', () {
      final stored = _compose(
        const ['English', 'French', 'Spanish', 'Arabic', 'Hindi'],
      );
      final line = stored
          .split('\n')
          .firstWhere((l) => l.startsWith('Languages:'), orElse: () => '');
      expect(line, 'Languages: English, French, Spanish');
    });

    test('blanks/unknowns are dropped', () {
      expect(_compose(const ['English', '  ', 'French']),
          contains('Languages: English, French'));
    });
  });

  group('round-trip — parse', () {
    test('no Languages line ⇒ defaults to [English] (never empty)', () {
      final parsed = parseStoredWebsitePrompt(_compose(const ['English']));
      expect(parsed.languages, const ['English']);
    });

    test('legacy record (no enriched header at all) ⇒ [English]', () {
      final parsed = parseStoredWebsitePrompt('just an old freeform prompt');
      expect(parsed.languages, const ['English']);
    });

    test('single non-English survives', () {
      final parsed = parseStoredWebsitePrompt(_compose(const ['French']));
      expect(parsed.languages, const ['French']);
    });

    test('multiple survive in order', () {
      final parsed =
          parseStoredWebsitePrompt(_compose(const ['English', 'Farsi']));
      expect(parsed.languages, const ['English', 'Farsi']);
    });
  });

  group('buildWebsiteAiPrompt — SITE LANGUAGES block', () {
    test('English-only → no block', () {
      final ai = buildWebsiteAiPrompt(_compose(const ['English']));
      expect(ai.contains('SITE LANGUAGES'), isFalse);
    });

    test('multi → block with autonyms, switcher, no national flags', () {
      final ai =
          buildWebsiteAiPrompt(_compose(const ['English', 'French', 'Arabic']));
      expect(ai, contains('SITE LANGUAGES'));
      expect(ai, contains('Français'));
      expect(ai, contains(websiteLanguageAutonyms['Arabic']!)); // العربية
      expect(ai.toLowerCase(), contains('language-switcher'));
      expect(ai.toLowerCase(), contains('do not use national flags'));
    });

    test('Arabic present → right-to-left instruction', () {
      final ai =
          buildWebsiteAiPrompt(_compose(const ['English', 'Arabic']));
      expect(ai, contains('dir="rtl"'));
    });

    test('LTR-only multi → no rtl instruction', () {
      final ai =
          buildWebsiteAiPrompt(_compose(const ['English', 'French']));
      expect(ai.contains('dir="rtl"'), isFalse);
    });

    test('the raw Languages: line is stripped from the echoed user request',
        () {
      final ai =
          buildWebsiteAiPrompt(_compose(const ['English', 'French']));
      // The hidden block is added, but the machine-readable line must not be
      // echoed back in the "User request:" tail.
      final userReqIdx = ai.indexOf('User request:');
      expect(userReqIdx, greaterThanOrEqualTo(0));
      expect(ai.substring(userReqIdx).contains('Languages:'), isFalse);
    });
  });

  group('buildWebsiteLanguagesBlock — direct', () {
    test('single English → empty', () {
      expect(buildWebsiteLanguagesBlock(const ['English']), isEmpty);
    });

    test('single non-English → "write the ENTIRE website in X"', () {
      final b = buildWebsiteLanguagesBlock(const ['French']);
      expect(b, contains('ENTIRE website in French'));
      expect(b.contains('dir="rtl"'), isFalse); // French is LTR
    });

    test('caps at 3', () {
      final b = buildWebsiteLanguagesBlock(
          const ['English', 'French', 'Spanish', 'Japanese']);
      expect(b.contains('日本語'), isFalse); // 4th language dropped
    });
  });
}
