import 'package:fula_files/core/models/contact_form_config.dart';
import 'package:fula_files/core/utils/contact_form_snippet.dart';

// Pure construction of the AI-website generation prompt + the upload
// caps that gate the pipeline. Platform-neutral and free of service
// dependencies so the native WebsiteService and the web shell send the
// AI backend BYTE-IDENTICAL prompts — the hidden instruction blocks and
// header-line markers (Website Name: / Category: / Styles: / Palette: /
// ContactForm:) are part of the generation contract, and the caps are
// mirrored server-side as defence in depth.

/// A single user-supplied note about one attached asset. [cid] is null
/// when the preview is rendered before upload.
typedef AssetNote = ({String fileName, String? cid, String comment});

// ---------------------------------------------------------------- caps

/// S3 bucket website assets are uploaded to (unencrypted, public-ish).
const String kWebsiteAssetBucket = 'website-assets';

const int kWebsiteMaxParsedContentBytes = 100000; // 100KB backend limit

// Per-type per-file size caps. Limits aligned with what Anthropic's
// Messages API accepts (5MB images, 32MB PDFs); the rest sit below the
// request-size budget.
const int kWebsiteMaxImageBytes = 5 * 1024 * 1024; //  5MB
const int kWebsiteMaxBinaryDocBytes = 32 * 1024 * 1024; // 32MB
const int kWebsiteMaxTextBytes = 10 * 1024 * 1024; // 10MB
// Video is uploaded to S3 for hosting and referenced by URL only — its bytes
// are NEVER sent to the AI backend (unlike images/docs, which are base64'd into
// the request), so this cap governs upload/hosting size, not the request budget.
// Sized to comfortably fit the "100MB+" clips users embed in generated sites
// while leaving headroom under the per-job total for a few other assets.
const int kWebsiteMaxVideoBytes = 150 * 1024 * 1024; // 150MB

// Per-job aggregate caps. Backend mirrors these as defence in depth.
const int kWebsiteMaxFilesPerJob = 10;
// Raised from 50MB to fit one large (100MB+) video plus ~50MB of other assets.
// NOTE: _uploadAssetUnencrypted buffers the whole file in memory before the PUT,
// so a very large video is a memory consideration — most acute on the web build
// (a chunked/streaming upload is the real fix; tracked as a follow-up).
const int kWebsiteMaxTotalUploadBytes = 200 * 1024 * 1024; // 200MB total

/// Per-file size cap for [ext] (dot-prefixed, e.g. '.png'). Returns 0
/// for extensions that can't be usefully forwarded — callers skip them.
int websiteMaxFileSizeBytesForExt(String ext) {
  switch (ext.toLowerCase()) {
    case '.png':
    case '.jpg':
    case '.jpeg':
    case '.gif':
    case '.webp':
      return kWebsiteMaxImageBytes;
    case '.pdf':
    case '.docx':
    case '.xlsx':
    case '.pptx':
      return kWebsiteMaxBinaryDocBytes;
    case '.txt':
    case '.md':
    case '.csv':
    case '.json':
    case '.html':
    case '.htm':
    case '.xml':
      return kWebsiteMaxTextBytes;
    // Browser-playable video only — these embed in an HTML5 <video> and stream
    // from the range-capable gateway. Containers browsers can't reliably play
    // (.mkv/.avi/.wmv/.flv) are intentionally omitted so users don't publish a
    // clip that won't play in a visitor's browser.
    case '.mp4':
    case '.webm':
    case '.mov':
    case '.m4v':
    case '.ogv':
      return kWebsiteMaxVideoBytes;
    default:
      return 0;
  }
}

// ------------------------------------------------------------- prompt

/// System instructions auto-prepended to every user prompt.
const String websiteSystemInstructions = '''
=== SYSTEM CONSTRAINTS (auto-added, do not repeat) ===
Output budget: Your TOTAL JSON response must be UNDER 40KB (~10,000 tokens). Plan accordingly — do NOT start generating a large site that will get cut off mid-output.

File strategy:
- Generate 1-3 files MAX (index.html, style.css, optionally script.js).
- For simple sites, inline CSS in a <style> tag to save file count and output size.
- Write clean but concise code. Avoid verbose comments or redundant CSS resets.

Hosting constraints (IPFS — static only):
- Use ONLY relative paths for internal refs (e.g. href="./style.css", src="./script.js").
- The site must be SELF-CONTAINED: NO server-side code, NO forms with action URLs, and NO external links of any kind — no CDN scripts, styles, fonts, or images — with the SINGLE exception of the YouTube/Vimeo video iframe described below.
- All provided asset URLs are already hosted — use them exactly as-is. For an IMAGE asset use <img src="https://..." style="max-width:100%">. For a VIDEO asset (an attached file whose type is video), NEVER use an <img> — embed a native HTML5 player that streams from the URL:
  <video controls preload="metadata" playsinline style="max-width:100%;height:auto"><source src="https://...ASSET_URL..." type="video/mp4"></video>
  (set the <source> type to match the file: video/mp4 for .mp4/.m4v/.mov, video/webm for .webm, video/ogg for .ogv).
- YOUTUBE/VIMEO EMBED (the ONLY permitted external resource): if the user's request references a YouTube (youtube.com / youtu.be) or Vimeo (vimeo.com) link, embed it as a RESPONSIVE 16:9 iframe, not a plain link. The iframe src MUST be exactly https://www.youtube.com/embed/<id> or https://player.vimeo.com/video/<id> and NO other host; if the user's link is neither YouTube nor Vimeo, do NOT embed it. Extract the id and wrap so it scales:
  <div style="position:relative;width:100%;max-width:720px;margin:auto;aspect-ratio:16/9"><iframe src="https://www.youtube.com/embed/VIDEO_ID" style="position:absolute;inset:0;width:100%;height:100%;border:0" loading="lazy" referrerpolicy="strict-origin-when-cross-origin" allow="accelerometer;clipboard-write;encrypted-media;gyroscope;picture-in-picture" allowfullscreen></iframe></div>
  (youtu.be/ID or youtube.com/watch?v=ID -> https://www.youtube.com/embed/ID ; vimeo.com/ID -> https://player.vimeo.com/video/ID).

Images (CRITICAL — must fit container on every viewport):
- Every image MUST fit fully inside its container on both mobile (narrow portrait) and desktop (wide) — never cropped off, cut, or overflowing the container box.
- Apply max-width:100%; height:auto; display:block on every <img> as the baseline to prevent overflow.
- When the image's aspect ratio does not match the container, pick the BEST fit strategy for that specific image — do not blindly default to one:
  - PREFERRED when a clean matching background color is identifiable: object-fit:contain on the <img> plus a background-color on the container that matches the image's natural background (e.g. #fff for product shots on a white backdrop, #000 for dark/letterbox photos, or a color sampled from the image's edge pixels). This preserves the entire image without visible letterbox bars.
  - When minor cropping is acceptable AND the focal point is roughly centered (e.g. hero banners, decorative photos): object-fit:cover. Do NOT use cover for logos, screenshots, diagrams, or any image where edge content matters.
  - When neither of the above is right: constrain only ONE dimension (width OR height) on the container and let the other flow with the image's natural aspect ratio.
- For images of unknown content/aspect ratio (user-supplied assets), default to object-fit:contain with a neutral background, since contain never crops.
- Set explicit aspect-ratio or min-height on image containers where layout shift would otherwise occur; ensure responsive breakpoints re-check fit (a layout that fits desktop may clip on phone, and vice versa).

Design:
- Mobile-responsive layout with clean typography.
- Visually appealing with good use of whitespace and color.
- The user will provide a "Website Name" and "Category" at the start of their request. Use the website name as the site title/heading. Tailor the layout, color scheme, and content structure to fit the specified category.
=== END SYSTEM CONSTRAINTS ===
''';

/// Hidden category-specific instructions, injected as a separate system
/// block when the stored prompt has a matching `Category:` line.
const Map<String, String> websiteCategoryInstructions = {
  'Resume':
      'It should match a professional style resume format with the information included in prompt and attached files for job hunting in North America solely based on the details that are in the attached file and entered in the prompt and no guessing or made up information should exist. Use a single-page layout with clear sections (summary, experience, education, skills, contact) and ATS-friendly typography.',
  'Shop':
      'Read pricing and details that are attached or in the prompt and only use those information and add to website without any guessing or made up information and pricing. Also for images of products use a touched up version of the images that are in the attached files for each product you add. Render a product grid with consistent card sizing, clear product name, price, and short description for each item; if a detail is missing, omit it rather than guessing.',
  'Personal':
      'A personal website highlighting the individual described in the prompt and attached files. Use only the supplied biography, photos, links, and contact information. Structure with a hero/intro, an about section, highlights or portfolio of work, and a contact block. Do not invent biographical details, social links, education, employers, or contact information that is not explicitly provided.',
  'Real Estate':
      'A real estate listing or agency site. For each property, use the photos and listing details (location, price, beds, baths, square footage, year built, key features) exactly as provided in the attached files and prompt. Do not invent properties, prices, addresses, or specs. If a field is missing for a property, omit that field rather than guessing. Include a clear listings section with consistent cards and a contact block using only the supplied agent/agency information.',
  'Automotives':
      'An automotive listing or dealership site. For each vehicle, use the photos and specs (make, model, year, trim, mileage, price, transmission, drivetrain, key features) exactly as provided in the attached files and prompt. Do not invent vehicles, prices, or specifications. If a field is missing, omit it rather than guessing. Include a clear inventory grid and a contact block using only the supplied dealer/seller information.',
  'Corporation':
      'A professional corporate website. Use the company name, value proposition, services/products, and team/contact information exactly as provided in the attached files and prompt. Structure with a hero, about, services or solutions, and a contact section appropriate to the supplied information. Do not invent services, awards, statistics, partners, testimonials, employee names, or claims that are not explicitly provided. Use a trust-building, business-appropriate visual tone.',
  'Technology':
      'A technology product or service landing page. Use the product name, key features, benefits, and any screenshots/diagrams exactly as provided in the attached files and prompt. Structure with hero (headline + sub-headline + primary CTA only if a target is supplied), key features, how-it-works or use cases, and a closing CTA or contact section. Do not invent features, metrics, integrations, customer logos, testimonials, or pricing that are not explicitly provided.',
  'Other':
      'Use only the information explicitly provided in the prompt and attached files. Do not invent names, dates, prices, statistics, testimonials, or any factual claims. If a typical section would require data that is not supplied, either omit that section or keep it minimal using only what is provided.',
};

/// Hidden style-specific instructions, injected per selected style.
/// Keys are kept stable so older generations stored with `Interactive`
/// / `Theme support` continue to resolve via "Recreate".
const Map<String, String> websiteStyleInstructions = {
  'Minimal':
      'Use a minimalist visual language with generous whitespace, restrained typography, and a quiet color palette — think Google and Apple landing pages. Avoid decorative flourishes, gradients, and shadows unless they serve hierarchy.',
  'Editorial':
      'Lay out the page like a print magazine: confident serif or high-contrast display headings, multi-column body copy where appropriate, pull-quotes, and structured sections separated by hairline rules. Treat imagery with editorial framing (captions, credits) and let typography carry the visual identity.',
  'Bold':
      'Lead with oversized display type, high color contrast, and strong primary blocks. Use thick weights, vivid accent colors, and confident layout choices — sections should feel decisive, not subtle.',
  'Playful':
      'Adopt a soft, friendly visual tone: rounded corners, warm pastel or candy colors, hand-drawn or organic accents, and generous, rounded type. Sections should feel inviting and casual rather than corporate.',
  'Glassy':
      'Apply a translucent, layered visual style: frosted-glass panels with subtle backdrop blur, soft glows, layered cards over a richly colored or gradient background. Use semi-transparent surfaces with thin highlight borders to suggest depth.',
  'Monospace':
      'Use a technical, terminal-inspired aesthetic: monospaced typography throughout, dark background with a single accent color (mint/green/amber on near-black), grid-aligned blocks, and crisp 1px borders. Treat the layout like a well-designed CLI or developer doc.',
  'Brutalist':
      'Embrace raw, gridded, stark design: heavy borders, exposed grid lines, default-feeling typography, high contrast, and unapologetically large blocks. Avoid rounded corners, soft shadows, or decorative ornament — let the structure itself be the visual.',
  'Gallery':
      'Make imagery the protagonist: image-first grid layouts, large media tiles, generous gutters, minimal chrome around photos. Text plays a supporting role — short captions, small metadata, and clear sectioning so the assets dominate the page.',
  'Interactive':
      'Ensure that you add some interesting and interactive elements on the page.',
  'Theme support':
      'Add light/dark theme switch support at the top in a nice way.',
};

/// Hidden palette-specific instructions, injected when the stored
/// prompt contains a matching `Palette:` line.
const Map<String, String> websitePaletteInstructions = {
  'Auto from attachments':
      'Derive the entire color palette directly from the attached images and assets — sample dominant tones, accents, and background colors from photos, logos, or graphics provided, and apply them consistently across backgrounds, text, accents, and UI elements so the site feels like a unified extension of the supplied imagery. If no usable images are attached, fall back to a tasteful palette appropriate to the chosen category.',
  'Warm':
      'Use a warm color palette grounded in reds, oranges, terracotta, golds, ambers, and creamy off-whites. Pair warm accents with deep brown or charcoal text for contrast. Do not use cool blues, greens, or purples as primary or secondary colors — limit any cool tones, if present at all, to small functional accents.',
  'Cold':
      'Use a cool/cold color palette grounded in blues, teals, slate greys, deep purples, and crisp whites. Pair cool accents with near-black or deep navy text for contrast. Do not use warm reds, oranges, or yellows as primary or secondary colors — limit any warm tones, if present at all, to small functional accents.',
  'Grey tone':
      'Use a strictly monochromatic grey palette across the entire site: a single neutral hue family ranging from near-black through mid-greys to near-white. Establish hierarchy through tonal contrast and typography rather than through color. A single subtle, desaturated accent may be used very sparingly for primary actions; otherwise keep every surface, text run, border, and graphic in grayscale.',
};

final RegExp _categoryLinePattern =
    RegExp(r'^Category:\s*(.*)$', multiLine: true);
final RegExp _stylesLinePattern =
    RegExp(r'^Styles:\s*(.*)$', multiLine: true);
final RegExp _paletteLinePattern =
    RegExp(r'^Palette:\s*(.*)$', multiLine: true);
final RegExp _contactFormLinePattern =
    RegExp(r'^ContactForm:\s*(.*)$', multiLine: true);
final RegExp _languagesLinePattern =
    RegExp(r'^Languages:\s*(.*)$', multiLine: true);

String _formatAssetNote({
  required String fileName,
  required String? cid,
  required String comment,
}) {
  final lines = StringBuffer('- file: $fileName');
  if (cid != null && cid.isNotEmpty) {
    lines.write(' (CID: $cid)');
  }
  lines
    ..writeln()
    ..write('  note: ${comment.trim()}');
  return lines.toString();
}

/// Render the "asset notes" section appended to the AI prompt. Empty
/// string when no populated notes exist.
String buildWebsiteAssetNotesSection({
  required List<AssetNote> notes,
  required bool cidsAvailable,
}) {
  final populated =
      notes.where((n) => n.comment.trim().isNotEmpty).toList(growable: false);
  if (populated.isEmpty) return '';

  final buffer = StringBuffer()
    ..writeln('=== ATTACHED ASSET NOTES (auto-added) ===')
    ..writeln('The user attached per-asset notes describing intent or emphasis '
        'for specific files. Each note identifies the asset by file name'
        '${cidsAvailable ? ' and IPFS CID' : ''}; the matching file is also '
        'in the attached `assets` list with the same identifier. Use these '
        'notes to inform layout, emphasis, copy tone, and section choices '
        'when designing the website. If a note conflicts with other '
        'instructions, prefer the note since it reflects the user\'s '
        'specific intent for that file.');
  if (!cidsAvailable) {
    buffer.writeln('(Preview note: the production prompt sent at generation '
        'time also includes the CID for each entry below.)');
  }
  for (final note in populated) {
    buffer.writeln(_formatAssetNote(
      fileName: note.fileName,
      cid: note.cid,
      comment: note.comment,
    ));
  }
  buffer.write('=== END ATTACHED ASSET NOTES ===');
  return buffer.toString();
}

String _fieldControlLabel(ContactFormFieldType t) {
  switch (t) {
    case ContactFormFieldType.text:
      return 'single-line text input';
    case ContactFormFieldType.multiline:
      return 'multi-line text area';
    case ContactFormFieldType.number:
      return 'number input';
    case ContactFormFieldType.email:
      return 'email input';
    case ContactFormFieldType.multiSelect:
      return 'multiple-select (checkboxes)';
  }
}

/// Build the auto-added CONTACT FORM block: an explicit client-side-form
/// authorization (overriding the "NO forms" system constraint), the field
/// spec, and the verbatim HTML+JS snippet the generator must embed unchanged.
String buildWebsiteContactFormBlock(ContactFormConfig cfg) {
  if (cfg.channel == ContactFormChannel.sheets) {
    final b = StringBuffer()
      ..writeln('=== CONTACT FORM (auto-added) ===')
      ..writeln('The user requested a Google Forms-based contact form. The form has already been created.')
      ..writeln('Embed the following Google Form URL as an iframe inside the website.')
      ..writeln('You MUST ensure the iframe is responsive, taking 100% width and a reasonable minimum height (e.g. min-height: 600px).')
      ..writeln('Do NOT generate a custom HTML <form>, just embed this iframe EXACTLY:')
      ..writeln()
      ..writeln('<iframe src="${cfg.destination}?embedded=true" width="100%" height="800" frameborder="0" marginheight="0" marginwidth="0">Loading…</iframe>')
      ..writeln('=== END CONTACT FORM ===');
    return b.toString();
  }

  final isEmail = cfg.channel == ContactFormChannel.email;
  final channelWord = isEmail ? 'Email' : 'WhatsApp';
  final appWord = isEmail ? 'mail app' : 'WhatsApp';
  final linkWord = isEmail ? 'mailto:' : 'wa.me';

  final fieldLines = StringBuffer();
  for (final f in cfg.usableFields) {
    final opts =
        f.type == ContactFormFieldType.multiSelect && f.options.isNotEmpty
            ? ' [options: ${f.options.join(', ')}]'
            : '';
    fieldLines.writeln('- "${f.label.trim()}" — ${_fieldControlLabel(f.type)}'
        '${f.required ? ' (required)' : ''}$opts');
  }

  final b = StringBuffer()
    ..writeln('=== CONTACT FORM (auto-added — overrides the "NO forms with '
        'action URLs" rule) ===')
    ..writeln('Add a contact form to the page. This is an explicit EXCEPTION '
        'to the "NO forms" constraint above: the form is 100% CLIENT-SIDE — '
        'it has NO action attribute, submits to NO server, and makes NO '
        'network request. On submit it composes a $linkWord deep link from the '
        'entered values and navigates to it, so the visitor only taps Send in '
        'their $appWord.')
    ..writeln()
    ..writeln('Channel: $channelWord. The destination is already baked into '
        'the script below.')
    ..writeln('Fields to collect (render in this order, themed to match the '
        'site):')
    ..write(fieldLines.toString())
    ..writeln()
    ..writeln('Embed the following form EXACTLY as given. You MAY restyle it '
        'with CSS / class names / a wrapping container so it matches the '
        "site's palette and typography, and you may place it in a sensible "
        '"Contact" section. You MUST NOT change the <script>, the URL '
        'construction, the phone-number handling, or the encodeURIComponent '
        'calls — copy them verbatim:')
    ..writeln()
    ..writeln(buildContactFormSnippet(cfg))
    ..write('=== END CONTACT FORM ===');
  return b.toString();
}

/// Supported website languages → their autonym (the language's own name).
/// Autonyms are used as the switcher labels in the generated site and shown
/// next to the English name in the FxFiles picker. English is the default.
const Map<String, String> websiteLanguageAutonyms = {
  'English': 'English',
  'French': 'Français',
  'Spanish': 'Español',
  'Arabic': 'العربية',
  'Farsi': 'فارسی',
  'Hindi': 'हिन्दी',
  'Chinese': '中文',
  'Japanese': '日本語',
};

/// Website languages that read right-to-left (need dir="rtl" + mirrored layout).
const Set<String> _rtlWebsiteLanguages = {'Arabic', 'Farsi'};

/// Build the auto-added SITE LANGUAGES block from the selected languages.
/// Returns '' for the default (English-only) case so existing single-language
/// prompts are unchanged. Defensively clamps to 3 (mirrors the picker cap).
String buildWebsiteLanguagesBlock(List<String> languages) {
  final langs = <String>[
    for (final l in languages)
      if (websiteLanguageAutonyms.containsKey(l.trim())) l.trim(),
  ].take(3).toList();
  if (langs.isEmpty || (langs.length == 1 && langs.first == 'English')) return '';

  final b = StringBuffer()..writeln('=== SITE LANGUAGES (auto-added) ===');
  if (langs.length == 1) {
    final lang = langs.first;
    b.writeln('Write the ENTIRE website in $lang '
        '(${websiteLanguageAutonyms[lang]}). ALL visible text — navigation, '
        'headings, body copy, buttons, form labels, alt text, and footer — must '
        'be in $lang; do not leave any text in another language.');
    if (_rtlWebsiteLanguages.contains(lang)) {
      b.writeln('$lang is right-to-left: set dir="rtl" on the <html> element and '
          'mirror the layout accordingly.');
    }
  } else {
    final labelled =
        langs.map((l) => '$l (${websiteLanguageAutonyms[l]})').join(', ');
    final hasRtl = langs.any(_rtlWebsiteLanguages.contains);
    b
      ..writeln('Build a MULTILINGUAL website in these languages: $labelled.')
      ..writeln('- Add a language-switcher dropdown in the site header (e.g. '
          'top-right). Label each option with the language\'s OWN name (the '
          'autonym shown in parentheses above), and include a small neutral icon '
          'next to each name — an inline SVG globe or a Unicode/script glyph, '
          'NOT an external image; do NOT use national flags — they do not map '
          'cleanly to languages.')
      ..writeln('- Default the site to ${langs.first}.')
      ..writeln('- Provide a complete, faithful, human-quality translation of '
          'ALL visible text for EVERY listed language — never leave text '
          'untranslated or mixed between languages.')
      ..writeln('- Because ALL language versions ship together in one static '
          'bundle under the output budget above, keep the site compact so every '
          'language fits in full: prefer fewer, shorter sections, terse headings, '
          'and single-paragraph copy. If it still would not fit, shorten or drop '
          'whole sections UNIFORMLY across every language — never omit a language '
          'or leave any language partially translated.')
      ..writeln('- Switching language updates all visible text instantly, '
          'client-side (no page reload), and persists the choice in localStorage '
          'so it survives refreshes.');
    if (hasRtl) {
      b.writeln('- For right-to-left languages (Arabic / Farsi), set dir="rtl" '
          'and mirror the layout when that language is active; use dir="ltr" '
          'otherwise.');
    }
  }
  b.writeln('Exception to the above: keep proper names, brand names, and the '
      'branded part of product names in their ORIGINAL spelling/script in every '
      'language — do NOT translate or transliterate them (this includes the '
      "website's own name when it is a brand, e.g. a Latin brand name stays "
      'Latin even in an Arabic or Chinese page).');
  b.write('=== END SITE LANGUAGES ===');
  return b.toString();
}

/// Parse the `ContactForm:` header line out of a stored prompt, or null
/// when absent/invalid (used by the post-publish render check too).
ContactFormConfig? parseWebsiteContactFormLine(String storedPrompt) {
  final match = _contactFormLinePattern.firstMatch(storedPrompt);
  return match != null
      ? ContactFormConfig.tryParse(match.group(1) ?? '')
      : null;
}

final RegExp _nameLinePattern =
    RegExp(r'^Website Name:\s*(.*)$', multiLine: true);

/// Inverse of [composeEnrichedWebsitePrompt]: parse a stored prompt
/// back into its components (Recreate flows). Tolerates older records
/// that lack the enriched prefix by returning empty name/category/
/// styles/palette and the original string as the user body.
({
  String websiteName,
  String category,
  List<String> styles,
  List<String> languages,
  String palette,
  String userBody,
  ContactFormConfig? contactForm,
}) parseStoredWebsitePrompt(String stored) {
  final nameMatch = _nameLinePattern.firstMatch(stored);
  final categoryMatch = _categoryLinePattern.firstMatch(stored);
  final contactForm = parseWebsiteContactFormLine(stored);

  if (nameMatch == null || categoryMatch == null) {
    return (
      websiteName: '',
      category: '',
      styles: const <String>[],
      languages: const <String>['English'],
      palette: '',
      userBody: stored.trim(),
      contactForm: contactForm,
    );
  }

  final stylesMatch = _stylesLinePattern.firstMatch(stored);
  final styles = <String>[];
  if (stylesMatch != null) {
    final raw = stylesMatch.group(1)?.trim() ?? '';
    if (raw.isNotEmpty) {
      styles.addAll(
        raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
      );
    }
  }

  final paletteMatch = _paletteLinePattern.firstMatch(stored);
  final palette = paletteMatch?.group(1)?.trim() ?? '';

  // Languages: parse the line, or default to English when absent. Older records
  // AND English-only sites have no Languages line (compose omits the default),
  // so "no line" must resolve to ['English'] — never [] — or Recreate would
  // silently drop the language back to nothing.
  final languagesMatch = _languagesLinePattern.firstMatch(stored);
  final languages = <String>[];
  if (languagesMatch != null) {
    final raw = languagesMatch.group(1)?.trim() ?? '';
    languages.addAll(
      raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
    );
  }
  if (languages.isEmpty) languages.add('English');

  // User body is everything after the first blank line.
  final blankLineIdx = stored.indexOf('\n\n');
  final body =
      blankLineIdx >= 0 ? stored.substring(blankLineIdx + 2).trim() : '';

  return (
    websiteName: nameMatch.group(1)?.trim() ?? '',
    category: categoryMatch.group(1)?.trim() ?? '',
    styles: styles,
    languages: languages,
    palette: palette,
    userBody: body,
    contactForm: contactForm,
  );
}

/// Compose the prompt stored on a generation record: header lines
/// (Website Name / Category / optional Styles / Palette / ContactForm)
/// followed by a blank line and the user's body. Hidden instruction
/// blocks are added later by [buildWebsiteAiPrompt].
String composeEnrichedWebsitePrompt({
  required String websiteName,
  required String category,
  required List<String> styles,
  required String palette,
  required String body,
  ContactFormConfig? contactForm,
  List<String> languages = const <String>['English'],
}) {
  final buffer = StringBuffer()
    ..writeln('Website Name: $websiteName')
    ..writeln('Category: $category');
  if (styles.isNotEmpty) {
    buffer.writeln('Styles: ${styles.join(', ')}');
  }
  if (palette.isNotEmpty) {
    buffer.writeln('Palette: $palette');
  }
  // Languages: only emit when beyond the default (English only), so existing
  // single-language prompts stay byte-identical. The defensive take(3) mirrors
  // the picker's cap so a bad caller can't emit a longer list.
  final langs = <String>[
    for (final l in languages)
      if (l.trim().isNotEmpty) l.trim(),
  ].take(3).toList();
  if (!(langs.isEmpty || (langs.length == 1 && langs.first == 'English'))) {
    buffer.writeln('Languages: ${langs.join(', ')}');
  }
  if (contactForm != null && contactForm.enabled) {
    buffer.writeln('ContactForm: ${contactForm.encode()}');
  }
  buffer
    ..writeln()
    ..write(body);
  return buffer.toString().trim();
}

/// Build the prompt sent to the AI: system constraints, optional hidden
/// category/style/palette blocks, optional contact-form block, optional
/// per-asset user notes, then `User request:` and the stored prompt.
String buildWebsiteAiPrompt(
  String storedPrompt, {
  List<AssetNote> assetNotes = const [],
  bool cidsAvailable = true,
}) {
  final buffer = StringBuffer(websiteSystemInstructions);

  final categoryMatch = _categoryLinePattern.firstMatch(storedPrompt);
  final category = categoryMatch?.group(1)?.trim() ?? '';
  final categoryHidden = websiteCategoryInstructions[category];
  if (categoryHidden != null && categoryHidden.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('=== TYPE-SPECIFIC CONSTRAINTS (auto-added) ===')
      ..writeln(categoryHidden)
      ..writeln('=== END TYPE-SPECIFIC CONSTRAINTS ===');
  }

  final stylesMatch = _stylesLinePattern.firstMatch(storedPrompt);
  final stylesRaw = stylesMatch?.group(1)?.trim() ?? '';
  if (stylesRaw.isNotEmpty) {
    final selected = stylesRaw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final styleLines = <String>[
      for (final s in selected)
        if (websiteStyleInstructions[s] != null)
          websiteStyleInstructions[s]!,
    ];
    if (styleLines.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('=== STYLE PREFERENCES (auto-added) ===');
      for (final line in styleLines) {
        buffer.writeln(line);
      }
      buffer.writeln('=== END STYLE PREFERENCES ===');
    }
  }

  final paletteMatch = _paletteLinePattern.firstMatch(storedPrompt);
  final palette = paletteMatch?.group(1)?.trim() ?? '';
  final paletteHidden = websitePaletteInstructions[palette];
  if (paletteHidden != null && paletteHidden.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('=== PALETTE PREFERENCE (auto-added) ===')
      ..writeln(paletteHidden)
      ..writeln('=== END PALETTE PREFERENCE ===');
  }

  final languagesMatch = _languagesLinePattern.firstMatch(storedPrompt);
  final languagesRaw = languagesMatch?.group(1)?.trim() ?? '';
  if (languagesRaw.isNotEmpty) {
    final langs = languagesRaw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final languagesBlock = buildWebsiteLanguagesBlock(langs);
    if (languagesBlock.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(languagesBlock);
    }
  }

  final contactFormMatch = _contactFormLinePattern.firstMatch(storedPrompt);
  final contactForm = contactFormMatch != null
      ? ContactFormConfig.tryParse(contactFormMatch.group(1) ?? '')
      : null;
  if (contactForm != null &&
      contactForm.enabled &&
      contactForm.usableFields.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln(buildWebsiteContactFormBlock(contactForm));
  }

  final notesSection = buildWebsiteAssetNotesSection(
    notes: assetNotes,
    cidsAvailable: cidsAvailable,
  );
  if (notesSection.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln(notesSection);
  }

  // Echo the user's request, but strip the machine-readable `ContactForm:`
  // line — its spec + verbatim snippet were already expanded above, so
  // echoing the raw JSON would waste output budget and risk the AI rendering
  // it literally on the page.
  final echoPrompt = storedPrompt
      .replaceAll(RegExp(r'^ContactForm:.*$\n?', multiLine: true), '')
      .replaceAll(RegExp(r'^Languages:.*$\n?', multiLine: true), '')
      .trimRight();
  buffer
    ..writeln()
    ..writeln('User request:')
    ..write(echoPrompt);
  return buffer.toString();
}
