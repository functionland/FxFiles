import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'package:crypto/crypto.dart';

import 'package:fula_files/core/models/contact_form_config.dart';
import 'package:fula_files/core/models/file_tag.dart';
import 'package:fula_files/core/models/website_generation.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/ipfs_gateway_helper.dart';
import 'package:fula_files/core/services/ipns_pointer_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';
import 'package:fula_files/core/utils/contact_form_snippet.dart';
import 'package:fula_files/core/utils/file_type_utils.dart' as file_utils;
import 'package:fula_files/core/utils/platform_capabilities.dart';

/// One user-supplied note attached to a website asset. Threaded through the
/// preview and generation flows so the AI prompt can reference the file by
/// its filename and (after upload) its IPFS CID.
typedef AssetNote = ({String fileName, String? cid, String comment});

/// Live pricing for a website generation. The two values come from the AI
/// service's `/api/v1/pricing` endpoint and are configured server-side via
/// the `GENERATION_COST_FULA` / `GENERATION_COST_FULA_WITH_TRACKING` env vars.
/// Used by the UI to show the user what a generation will cost before they
/// publish, and to react when the click-tracking toggle flips.
typedef WebsitePricing = ({int costFula, int costFulaWithTracking});

/// Service that orchestrates the website generation pipeline:
/// upload assets (unencrypted) → parse content (ML Kit) → call AI → store result
class WebsiteService {
  WebsiteService._();
  static final WebsiteService instance = WebsiteService._();

  late Box<WebsiteGeneration> _generationsBox;
  late Box<String> _assetCommentsBox;
  bool _isInitialized = false;

  /// True once the Hive boxes are open. Callers that synchronously read from
  /// the service (e.g. UI build methods reading asset comments) MUST check
  /// this and await [init] first — otherwise a silent empty read followed by
  /// a write can overwrite previously-persisted data.
  bool get isInitialized => _isInitialized;

  final _statusController = StreamController<WebsiteGeneration>.broadcast();
  Stream<WebsiteGeneration> get statusStream => _statusController.stream;

  static const _uuid = Uuid();
  static const String _assetBucket = 'website-assets';
  static const String _websiteMetadataBucket = 'website-metadata';
  static const int _maxParsedContentBytes = 100000; // 100KB backend limit

  // Per-type per-file size caps. Limits aligned with what Anthropic's
  // Messages API accepts (5MB images, 32MB PDFs); the rest sit below the
  // request-size budget. See `_maxFileSizeBytesForExt` for the lookup.
  static const int _maxImageBytes = 5 * 1024 * 1024;        //  5MB
  static const int _maxBinaryDocBytes = 32 * 1024 * 1024;   // 32MB (pdf/docx/xlsx/pptx)
  static const int _maxTextBytes = 10 * 1024 * 1024;        // 10MB (txt/md/csv/json/html/xml)

  // Per-job aggregate caps. Backend mirrors these as defence in depth.
  static const int _maxFilesPerJob = 10;
  static const int _maxTotalUploadBytes = 50 * 1024 * 1024; // 50MB total

  /// Return the per-file size cap for [ext]. Returns 0 for extensions we
  /// can't usefully forward to Claude — caller skips those files.
  static int _maxFileSizeBytesForExt(String ext) {
    switch (ext.toLowerCase()) {
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.gif':
      case '.webp':
        return _maxImageBytes;
      case '.pdf':
      case '.docx':
      case '.xlsx':
      case '.pptx':
        return _maxBinaryDocBytes;
      case '.txt':
      case '.md':
      case '.csv':
      case '.json':
      case '.html':
      case '.htm':
      case '.xml':
        return _maxTextBytes;
      default:
        return 0;
    }
  }

  // Cloud sync state
  bool _metaBucketChecked = false;
  bool _metaBucketExists = false;
  DateTime? _lastSyncTime;
  bool _syncScheduled = false;
  static const Duration _syncDebounce = Duration(seconds: 5);

  // Default endpoints (used when nothing is configured in SecureStorage)
  static const String _defaultAiEndpoint = 'https://ai.cloud.fx.land';
  static const String _defaultApiGateway = 'https://s3.cloud.fx.land';
  static const String _defaultAnalyticsEndpoint =
      'https://analytics.fx.land';

  /// System instructions auto-prepended to every user prompt.
  /// These ensure the backend produces compact, valid output.
  static const String _systemInstructions = '''
=== SYSTEM CONSTRAINTS (auto-added, do not repeat) ===
Output budget: Your TOTAL JSON response must be UNDER 40KB (~10,000 tokens). Plan accordingly — do NOT start generating a large site that will get cut off mid-output.

File strategy:
- Generate 1-3 files MAX (index.html, style.css, optionally script.js).
- For simple sites, inline CSS in a <style> tag to save file count and output size.
- Write clean but concise code. Avoid verbose comments or redundant CSS resets.

Hosting constraints (IPFS — static only):
- Use ONLY relative paths for internal refs (e.g. href="./style.css", src="./script.js").
- NO external CDN links, NO server-side code, NO forms with action URLs.
- All provided asset URLs are already hosted — use them exactly as-is (img src="https://...").

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

  /// Hidden category-specific instructions, injected as a separate system block
  /// when the stored prompt has a `Category:` line matching one of these keys.
  /// Not shown to the user — drives generator behavior at backend send time.
  /// Common rule: use ONLY information that is explicitly provided in the
  /// prompt or attached files; do not fabricate names, prices, stats, claims,
  /// testimonials, or any other content. Omit fields when data is missing.
  static const Map<String, String> _categoryInstructions = {
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

  /// Hidden style-specific instructions, injected per selected style. Multiple
  /// styles can apply at once. Not shown to the user. Keys are kept stable so
  /// older generations stored with `Interactive` / `Theme support` continue to
  /// receive their hidden instruction blocks when re-opened via "Recreate".
  static const Map<String, String> _styleInstructions = {
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

  /// Hidden palette-specific instructions, injected when the stored prompt
  /// contains a `Palette:` line matching one of these keys. Not shown to the
  /// user — drives generator behaviour at backend send time. Keys must match
  /// the labels in `paletteOptions` in generate_website_screen.dart.
  static const Map<String, String> _paletteInstructions = {
    'Auto from attachments':
        'Derive the entire color palette directly from the attached images and assets — sample dominant tones, accents, and background colors from photos, logos, or graphics provided, and apply them consistently across backgrounds, text, accents, and UI elements so the site feels like a unified extension of the supplied imagery. If no usable images are attached, fall back to a tasteful palette appropriate to the chosen category.',
    'Warm':
        'Use a warm color palette grounded in reds, oranges, terracotta, golds, ambers, and creamy off-whites. Pair warm accents with deep brown or charcoal text for contrast. Do not use cool blues, greens, or purples as primary or secondary colors — limit any cool tones, if present at all, to small functional accents.',
    'Cold':
        'Use a cool/cold color palette grounded in blues, teals, slate greys, deep purples, and crisp whites. Pair cool accents with near-black or deep navy text for contrast. Do not use warm reds, oranges, or yellows as primary or secondary colors — limit any warm tones, if present at all, to small functional accents.',
    'Grey tone':
        'Use a strictly monochromatic grey palette across the entire site: a single neutral hue family ranging from near-black through mid-greys to near-white. Establish hierarchy through tonal contrast and typography rather than through color. A single subtle, desaturated accent may be used very sparingly for primary actions; otherwise keep every surface, text run, border, and graphic in grayscale.',
  };

  static final RegExp _categoryLinePattern =
      RegExp(r'^Category:\s*(.*)$', multiLine: true);
  static final RegExp _stylesLinePattern =
      RegExp(r'^Styles:\s*(.*)$', multiLine: true);
  static final RegExp _paletteLinePattern =
      RegExp(r'^Palette:\s*(.*)$', multiLine: true);
  static final RegExp _contactFormLinePattern =
      RegExp(r'^ContactForm:\s*(.*)$', multiLine: true);

  /// A single user-supplied note about one attached asset. [cid] is null
  /// when the preview is rendered before upload — the section then explains
  /// that the live prompt will key by CID instead of just filename.
  static String _formatAssetNote({
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

  /// Render the "asset notes" section that's appended to the AI prompt.
  /// Returns an empty string if there are no notes.
  static String _buildAssetNotesSection({
    required List<AssetNote> notes,
    required bool cidsAvailable,
  }) {
    final populated = notes
        .where((n) => n.comment.trim().isNotEmpty)
        .toList(growable: false);
    if (populated.isEmpty) return '';

    final buffer = StringBuffer()
      ..writeln('=== ATTACHED ASSET NOTES (auto-added) ===')
      ..writeln(
          'The user attached per-asset notes describing intent or emphasis '
          'for specific files. Each note identifies the asset by file name'
          '${cidsAvailable ? ' and IPFS CID' : ''}; the matching file is also '
          'in the attached `assets` list with the same identifier. Use these '
          'notes to inform layout, emphasis, copy tone, and section choices '
          'when designing the website. If a note conflicts with other '
          'instructions, prefer the note since it reflects the user\'s '
          'specific intent for that file.');
    if (!cidsAvailable) {
      buffer.writeln(
          '(Preview note: the production prompt sent at generation time '
          'also includes the CID for each entry below.)');
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

  /// Build the auto-added CONTACT FORM block: an explicit client-side-form
  /// authorization (overriding the "NO forms" system constraint), the field
  /// spec, and the verbatim HTML+JS snippet the generator must embed unchanged.
  static String _buildContactFormBlock(ContactFormConfig cfg) {
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

  static String _fieldControlLabel(ContactFormFieldType t) {
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

  /// Build the prompt sent to the AI: system constraints, optional hidden
  /// category/style/palette blocks, optional contact-form block, optional
  /// per-asset user notes, then `User request:` and the stored prompt.
  String _buildAiPrompt(
    String storedPrompt, {
    List<AssetNote> assetNotes = const [],
    bool cidsAvailable = true,
  }) {
    final buffer = StringBuffer(_systemInstructions);

    final categoryMatch = _categoryLinePattern.firstMatch(storedPrompt);
    final category = categoryMatch?.group(1)?.trim() ?? '';
    final categoryHidden = _categoryInstructions[category];
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
          if (_styleInstructions[s] != null) _styleInstructions[s]!,
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
    final paletteHidden = _paletteInstructions[palette];
    if (paletteHidden != null && paletteHidden.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('=== PALETTE PREFERENCE (auto-added) ===')
        ..writeln(paletteHidden)
        ..writeln('=== END PALETTE PREFERENCE ===');
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
        ..writeln(_buildContactFormBlock(contactForm));
    }

    final notesSection = _buildAssetNotesSection(
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
        .trimRight();
    buffer
      ..writeln()
      ..writeln('User request:')
      ..write(echoPrompt);
    return buffer.toString();
  }

  /// Build the exact prompt that will be sent to the AI backend, given the
  /// generator screen's selections. Mirrors the enriched-prompt header format
  /// produced by the screen's caller (`Website Name:` / `Category:` / optional
  /// `Styles:` / `Palette:`) before passing through [_buildAiPrompt]. Used by
  /// the screen's "preview full prompt" eye icon. [assetNotes] is rendered
  /// inside the prompt only when present; CIDs are not yet known at preview
  /// time so the section explicitly says so.
  String buildPreviewPrompt({
    required String websiteName,
    required String category,
    required List<String> styles,
    required String palette,
    required String body,
    List<AssetNote> assetNotes = const [],
    ContactFormConfig? contactForm,
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
    if (contactForm != null && contactForm.enabled) {
      buffer.writeln('ContactForm: ${contactForm.encode()}');
    }
    buffer
      ..writeln()
      ..write(body);
    return _buildAiPrompt(
      buffer.toString().trim(),
      assetNotes: assetNotes,
      cidsAvailable: false,
    );
  }

  /// Initialize Hive box and register adapters
  Future<void> init() async {
    if (_isInitialized) return;

    try {
      if (!Hive.isAdapterRegistered(25)) {
        Hive.registerAdapter(WebsiteGenerationAdapter());
      }
      if (!Hive.isAdapterRegistered(26)) {
        Hive.registerAdapter(WebsiteGenStatusAdapter());
      }
      if (!Hive.isAdapterRegistered(27)) {
        Hive.registerAdapter(WebsiteAssetAdapter());
      }

      _generationsBox = await Hive.openBox<WebsiteGeneration>('website_generations');
      _assetCommentsBox = await Hive.openBox<String>('website_asset_comments');
      _isInitialized = true;
      debugPrint(
          'WebsiteService initialized with ${_generationsBox.length} generations, '
          '${_assetCommentsBox.length} asset comments');
    } catch (e) {
      debugPrint('Failed to initialize WebsiteService: $e');
    }
  }

  // ============================================================================
  // GENERATION QUERIES
  // ============================================================================

  /// Get all generations for a specific website tag
  List<WebsiteGeneration> getGenerationsForTag(String tagId) {
    if (!_isInitialized) return [];
    return _generationsBox.values
        .where((g) => g.tagId == tagId)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Get all generations
  List<WebsiteGeneration> getAllGenerations() {
    if (!_isInitialized) return [];
    return _generationsBox.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Delete all generations for a tag
  Future<void> deleteGenerationsForTag(String tagId) async {
    if (!_isInitialized) await init();
    final toRemove = _generationsBox.values
        .where((g) => g.tagId == tagId)
        .map((g) => g.id)
        .toList();
    for (final id in toRemove) {
      await _generationsBox.delete(id);
    }
    // Also clear any per-asset comments for this website.
    await deleteAssetCommentsForTag(tagId);
  }

  // ============================================================================
  // ASSET COMMENTS (per-website-asset user notes)
  // ============================================================================

  /// Composite key for the comments box.
  String _assetCommentKey(String tagId, String taggedFileId) =>
      '$tagId|$taggedFileId';

  /// Returns the stored comment for a website asset, or null if none.
  String? getAssetComment(String tagId, String taggedFileId) {
    if (!_isInitialized) return null;
    final value = _assetCommentsBox.get(_assetCommentKey(tagId, taggedFileId));
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// Persist (or clear, when empty) a comment for a website asset.
  Future<void> setAssetComment(
      String tagId, String taggedFileId, String comment) async {
    if (!_isInitialized) await init();
    final key = _assetCommentKey(tagId, taggedFileId);
    final trimmed = comment.trim();
    if (trimmed.isEmpty) {
      await _assetCommentsBox.delete(key);
    } else {
      await _assetCommentsBox.put(key, trimmed);
    }
  }

  /// Delete one asset's comment (called when the asset is removed from a
  /// website).
  Future<void> deleteAssetComment(String tagId, String taggedFileId) async {
    if (!_isInitialized) return;
    await _assetCommentsBox.delete(_assetCommentKey(tagId, taggedFileId));
  }

  /// All comments for a tag, returned as `taggedFileId → comment`.
  Map<String, String> getAssetCommentsForTag(String tagId) {
    if (!_isInitialized) return const {};
    final prefix = '$tagId|';
    final result = <String, String>{};
    for (final key in _assetCommentsBox.keys) {
      if (key is String && key.startsWith(prefix)) {
        final value = _assetCommentsBox.get(key);
        if (value != null && value.isNotEmpty) {
          result[key.substring(prefix.length)] = value;
        }
      }
    }
    return result;
  }

  /// Delete every comment for a website (called when the website is deleted).
  Future<void> deleteAssetCommentsForTag(String tagId) async {
    if (!_isInitialized) return;
    final prefix = '$tagId|';
    final toRemove = <String>[
      for (final key in _assetCommentsBox.keys)
        if (key is String && key.startsWith(prefix)) key,
    ];
    for (final key in toRemove) {
      await _assetCommentsBox.delete(key);
    }
  }

  // ============================================================================
  // PRICING
  // ============================================================================

  /// Fallback pricing used when the server is unreachable or returns junk.
  /// Kept in sync with `pinning-service/ai`'s defaults
  /// (`GENERATION_COST_FULA=1000`, `GENERATION_COST_FULA_WITH_TRACKING=1500`)
  /// so the UI shows a plausible number rather than an empty/zero state.
  static const WebsitePricing _fallbackPricing =
      (costFula: 1000, costFulaWithTracking: 1500);

  WebsitePricing? _cachedPricing;

  /// Fetch the current FULA cost for a website generation from the AI
  /// service. The result is cached in-memory for the session so the
  /// `generate_website_screen` can read it synchronously after the first
  /// load, and so flipping the tracking toggle doesn't trigger a new HTTP
  /// call (both values arrive in one response).
  ///
  /// Never throws. If the endpoint is missing (older server) or unreachable,
  /// returns [_fallbackPricing]. The endpoint itself is no-auth so this
  /// works before the user has logged in.
  ///
  /// [forceRefresh] bypasses the in-memory cache.
  Future<WebsitePricing> fetchPricing({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedPricing != null) return _cachedPricing!;

    final aiEndpoint = await SecureStorageService.instance
            .read(SecureStorageKeys.aiEndpointUrl) ??
        _defaultAiEndpoint;

    try {
      final response = await http
          .get(Uri.parse('$aiEndpoint/api/v1/pricing'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final base = body['generationCostFula'];
        final tracked = body['generationCostFulaWithTracking'];
        if (base is num && tracked is num && base >= 0 && tracked >= 0) {
          _cachedPricing = (
            costFula: base.toInt(),
            costFulaWithTracking: tracked.toInt(),
          );
          return _cachedPricing!;
        }
      }
    } catch (_) {
      // Swallow — pricing display is best-effort. Falling back to defaults
      // is preferable to blocking the publish flow on a network glitch.
    }
    _cachedPricing = _fallbackPricing;
    return _cachedPricing!;
  }

  /// Synchronous read of the last-fetched pricing. Returns the fallback if
  /// [fetchPricing] has not been called yet.
  WebsitePricing get cachedPricing => _cachedPricing ?? _fallbackPricing;

  // ============================================================================
  // GENERATION PIPELINE
  // ============================================================================

  /// Start the full website generation pipeline. [enableTracking] is the
  /// user's per-generation opt-in for click analytics: the AI backend honours
  /// it by injecting the analytics-ping `<script>` into the generated HTML
  /// before pinning to IPFS, and the in-app UI shows view/visitor counts only
  /// for generations where it was true.
  Future<WebsiteGeneration> startGeneration({
    required String tagId,
    required String tagName,
    required String prompt,
    required List<TaggedFile> files,
    bool enableTracking = false,
  }) async {
    if (!_isInitialized) await init();

    // Sanitize tagName for use as S3 key prefix
    final websiteName = tagName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

    // Snapshot per-asset user comments at generation start so subsequent
    // edits don't retroactively change in-flight prompts.
    final commentsByTaggedFileId = getAssetCommentsForTag(tagId);

    // Build asset list
    final assets = files
        .where((f) => f.localPath != null)
        .map((f) => WebsiteAsset(
              localPath: f.localPath!,
              fileName: f.fileName,
              type: file_utils.classifyFileType(f.fileName),
              comment: commentsByTaggedFileId[f.id],
            ))
        .toList();

    // Create generation record
    final generation = WebsiteGeneration(
      id: _uuid.v4(),
      tagId: tagId,
      tagName: tagName,
      prompt: prompt,
      status: WebsiteGenStatus.uploading,
      statusMessage: 'Starting upload...',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      totalAssets: assets.length,
      uploadedAssets: 0,
      assets: assets,
      trackingEnabled: enableTracking,
    );

    await _generationsBox.put(generation.id, generation);
    _statusController.add(generation);

    // Run pipeline asynchronously
    _runPipeline(generation, websiteName);

    return generation;
  }

  /// Run the full pipeline: upload → parse → generate
  Future<void> _runPipeline(WebsiteGeneration generation, String websiteName) async {
    try {
      // Phase 1: Upload assets
      await _uploadPhase(generation, websiteName);

      // Phase 2: Parse content
      await _parsePhase(generation);

      // Phase 3: Call AI endpoint
      await _generatePhase(generation);
    } catch (e) {
      generation.status = WebsiteGenStatus.error;
      generation.errorMessage = e.toString();
      generation.updatedAt = DateTime.now();
      await _generationsBox.put(generation.id, generation);
      _statusController.add(generation);
      debugPrint('Website generation failed: $e');
    }
  }

  /// Phase 1: Upload each asset unencrypted to S3
  Future<void> _uploadPhase(WebsiteGeneration generation, String websiteName) async {
    // M4: Create bucket once at the start of upload phase
    await _ensureBucket();

    int failedCount = 0;
    int uploadedCount = 0;
    int totalUploadedBytes = 0;
    final skipReasons = <String>[];

    for (var i = 0; i < generation.assets.length; i++) {
      final asset = generation.assets[i];
      final ext = p.extension(asset.fileName).toLowerCase();
      final perTypeCap = _maxFileSizeBytesForExt(ext);

      // Defensive: extensions we can't forward to Claude (no native block,
      // no text-extraction path). Skip with a clear reason.
      if (perTypeCap == 0) {
        debugPrint('Asset ${asset.fileName} unsupported type ($ext), skipping');
        asset.uploaded = false;
        failedCount++;
        skipReasons.add('${asset.fileName}: unsupported type');
        continue;
      }

      // 10-file cap per job — once we've uploaded the cap, skip the rest.
      if (uploadedCount >= _maxFilesPerJob) {
        debugPrint('Asset ${asset.fileName} skipped (10-file cap reached)');
        asset.uploaded = false;
        failedCount++;
        skipReasons.add('${asset.fileName}: 10-file cap reached');
        continue;
      }

      // Read file size, apply per-type and total caps before upload.
      final int fileSize;
      try {
        fileSize = File(asset.localPath).lengthSync();
      } catch (e) {
        debugPrint('Cannot stat asset ${asset.fileName}: $e');
        asset.uploaded = false;
        failedCount++;
        skipReasons.add('${asset.fileName}: cannot read');
        continue;
      }

      if (fileSize > perTypeCap) {
        final mb = (fileSize / (1024 * 1024)).toStringAsFixed(1);
        final capMb = (perTypeCap / (1024 * 1024)).toStringAsFixed(0);
        debugPrint('Asset ${asset.fileName} too large (${mb}MB > ${capMb}MB cap), skipping');
        asset.uploaded = false;
        failedCount++;
        skipReasons.add('${asset.fileName}: ${mb}MB exceeds ${capMb}MB cap for $ext');
        continue;
      }

      if (totalUploadedBytes + fileSize > _maxTotalUploadBytes) {
        final mb = (fileSize / (1024 * 1024)).toStringAsFixed(1);
        final usedMb = (totalUploadedBytes / (1024 * 1024)).toStringAsFixed(1);
        debugPrint('Asset ${asset.fileName} skipped (would exceed 50MB total: ${usedMb}MB used, ${mb}MB more)');
        asset.uploaded = false;
        failedCount++;
        skipReasons.add('${asset.fileName}: 50MB total cap reached');
        continue;
      }

      generation.statusMessage = 'Uploading asset ${i + 1}/${generation.totalAssets}...';
      generation.updatedAt = DateTime.now();
      await _generationsBox.put(generation.id, generation);
      _statusController.add(generation);

      try {
        final cid = await _uploadAssetUnencrypted(
          asset.localPath,
          asset.fileName,
          websiteName,
        );
        asset.cid = cid;
        asset.gatewayUrl = await _buildGatewayUrl(cid);
        asset.uploaded = true;
        uploadedCount++;
        totalUploadedBytes += fileSize;
        generation.uploadedAssets = uploadedCount;
        await _generationsBox.put(generation.id, generation);
        _statusController.add(generation);
      } catch (e) {
        debugPrint('Failed to upload asset ${asset.fileName}: $e');
        asset.uploaded = false;
        failedCount++;
        skipReasons.add('${asset.fileName}: upload failed');
      }
    }

    // M2: Inform user about failed/skipped assets
    if (failedCount > 0) {
      final summary = skipReasons.length <= 3
          ? skipReasons.join('; ')
          : '${skipReasons.take(3).join('; ')} (+${skipReasons.length - 3} more)';
      generation.statusMessage =
          '$failedCount of ${generation.totalAssets} assets skipped — $summary';
      generation.updatedAt = DateTime.now();
      await _generationsBox.put(generation.id, generation);
      _statusController.add(generation);
    }
  }

  /// Phase 2: Parse content from each asset using ML Kit
  Future<void> _parsePhase(WebsiteGeneration generation) async {
    generation.status = WebsiteGenStatus.parsing;
    generation.statusMessage = 'Parsing content...';
    generation.updatedAt = DateTime.now();
    await _generationsBox.put(generation.id, generation);
    _statusController.add(generation);

    for (final asset in generation.assets) {
      try {
        final content = await _parseContent(asset.localPath, asset.type);
        if (content != null && content.isNotEmpty) {
          // M6: Truncate to backend's 100KB limit per asset
          asset.parsedContent = content.length > _maxParsedContentBytes
              ? content.substring(0, _maxParsedContentBytes)
              : content;
        }
      } catch (e) {
        debugPrint('Failed to parse content for ${asset.fileName}: $e');
      }
    }

    await _generationsBox.put(generation.id, generation);
    _statusController.add(generation);
  }

  /// Phase 3: Call AI endpoint to generate the website
  Future<void> _generatePhase(WebsiteGeneration generation) async {
    generation.status = WebsiteGenStatus.generating;
    generation.statusMessage = 'Generating website...';
    generation.updatedAt = DateTime.now();
    await _generationsBox.put(generation.id, generation);
    _statusController.add(generation);

    // H4: Filter out assets where gatewayUrl is null or empty
    final uploadedAssets = generation.assets.where((a) => a.uploaded).toList();
    final validAssets = uploadedAssets
        .where((a) => a.gatewayUrl != null && a.gatewayUrl!.isNotEmpty)
        .toList();
    final droppedCount = uploadedAssets.length - validAssets.length;
    if (droppedCount > 0) {
      debugPrint('Warning: Dropped $droppedCount assets with empty gateway URLs');
    }

    final assetPayloads = validAssets.map((a) => a.toAiPayload()).toList();

    // Build the user-note table now that CIDs are known. Only assets with a
    // non-empty comment contribute a row.
    final assetNotes = <AssetNote>[
      for (final a in validAssets)
        if (a.comment != null && a.comment!.trim().isNotEmpty)
          (fileName: a.fileName, cid: a.cid, comment: a.comment!),
    ];

    // M3: _callAiEndpoint sets resultCid and resultGatewayUrl on generation
    await _callAiEndpoint(
      generation.prompt,
      assetPayloads,
      generation,
      assetNotes: assetNotes,
    );

    generation.status = WebsiteGenStatus.completed;
    generation.statusMessage = 'Website generated successfully';
    generation.updatedAt = DateTime.now();
    await _generationsBox.put(generation.id, generation);
    _statusController.add(generation);

    // Sync completed generation to cloud
    _scheduleSyncToCloud();

    // Stable per-group link: re-point the group's IPNS name at the new CID so a
    // link the user shared once now serves this generation. Best-effort and
    // non-blocking — a publish failure must never fail or delay the generation
    // (the link simply updates on the next successful publish).
    _publishStableLink(generation);

    // Best-effort: if a contact form was requested, confirm it actually
    // rendered in the published HTML and warn (without auto-respending FULA) if
    // it didn't. Fire-and-forget — never blocks or fails the generation.
    _verifyContactFormRendered(generation);
  }

  /// Warning written to [WebsiteGeneration.statusMessage] when the post-publish
  /// check can't find the contact form in the live site. The leading ⚠️ is the
  /// signal the generation card uses to render it as a warning (no Hive schema
  /// change needed). Kept as a constant so the write is idempotent.
  static const String contactFormMissingWarning =
      '⚠️ The contact form may not have rendered — open the site to check, or '
      'use Recreate to generate it again.';

  /// Best-effort check that a requested contact form actually rendered in the
  /// published site. The app never sees the AI's HTML directly, but the result
  /// is public on IPFS, so we fetch the page and look for the form marker
  /// (`id="cf"`). We intentionally check only the marker, not the JS tokens:
  /// the generator may inline the script or split it into a separate file, so
  /// requiring the JS would false-warn on a good site. On a miss we annotate
  /// [generation.statusMessage] with [contactFormMissingWarning] and let the
  /// user decide to Recreate — we never auto-regenerate (that would silently
  /// spend FULA) and never fail the generation over a best-effort network check.
  void _verifyContactFormRendered(WebsiteGeneration generation) {
    final match = _contactFormLinePattern.firstMatch(generation.prompt);
    final cfg = match != null
        ? ContactFormConfig.tryParse(match.group(1) ?? '')
        : null;
    if (cfg == null || !cfg.enabled || cfg.usableFields.isEmpty) return;

    final url = generation.gatewayUrl;
    if (url == null || url.isEmpty) return;

    Future<void> run() async {
      // Allow a few attempts for IPFS gateway propagation before concluding
      // the form is missing.
      for (var attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) {
          await Future.delayed(const Duration(seconds: 3));
        }
        try {
          final res = await http
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 15));
          if (res.statusCode != 200) continue;
          // Look only for the form marker. The script may be inlined or split
          // into a separate script.js (both permitted by the generator), so we
          // deliberately do NOT require the JS tokens — that would false-warn on
          // a perfectly good externalized-script site.
          if (res.body.contains('id="cf"')) return;
        } catch (_) {
          // Network/propagation hiccup — retry.
        }
      }
      // Exhausted attempts without finding the form. Surface a warning.
      if (generation.statusMessage != contactFormMissingWarning) {
        generation.statusMessage = contactFormMissingWarning;
        generation.updatedAt = DateTime.now();
        await _generationsBox.put(generation.id, generation);
        _statusController.add(generation);
      }
    }

    unawaited(run());
  }

  /// Fire-and-forget IPNS publish of the group's stable link to the latest CID.
  /// Errors are swallowed (logged) so they never affect the generation flow.
  void _publishStableLink(WebsiteGeneration generation) {
    final cid = generation.resultCid;
    if (cid == null || cid.isEmpty) return;
    IpnsPointerService.instance.publishLatest(generation.tagId, cid).then((_) {
      // Nudge listeners so the freshly-published link surfaces in the UI.
      _statusController.add(generation);
    }).catchError((Object e) {
      debugPrint('Stable-link IPNS publish failed (non-fatal): $e');
    });
  }

  // ============================================================================
  // UPLOAD (direct HTTP, bypasses fula_client encryption)
  // ============================================================================

  /// Ensure the S3 bucket exists (called once per upload batch)
  Future<void> _ensureBucket() async {
    final apiGateway = await SecureStorageService.instance
            .read(SecureStorageKeys.apiGatewayUrl) ??
        _defaultApiGateway;
    final jwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
    if (jwt == null || jwt.isEmpty) return;

    try {
      await http.put(
        Uri.parse('$apiGateway/$_assetBucket'),
        headers: {'Authorization': 'Bearer $jwt'},
      );
    } catch (e) {
      debugPrint('Bucket creation note: $e');
    }
  }

  /// Upload a file unencrypted to S3 via direct HTTP PUT
  Future<String> _uploadAssetUnencrypted(
    String localPath,
    String fileName,
    String websiteName,
  ) async {
    final apiGateway = await SecureStorageService.instance
            .read(SecureStorageKeys.apiGatewayUrl) ??
        _defaultApiGateway;
    final jwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);

    if (jwt == null || jwt.isEmpty) {
      throw Exception('No API key configured. Please set your API key in Settings.');
    }

    final key = '$websiteName/$fileName';
    final fileBytes = await File(localPath).readAsBytes();
    final contentType = lookupMimeType(localPath) ?? 'application/octet-stream';

    // Upload the file
    final response = await http.put(
      Uri.parse('$apiGateway/$_assetBucket/$key'),
      headers: {
        'Authorization': 'Bearer $jwt',
        'Content-Type': contentType,
      },
      body: fileBytes,
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
          'Upload failed (${response.statusCode}): ${response.body}');
    }

    // The etag header contains the IPFS CID
    final etag = response.headers['etag'];
    if (etag == null || etag.isEmpty) {
      throw Exception('Upload succeeded but no CID returned in etag header');
    }

    // Clean etag (remove quotes if present)
    return etag.replaceAll('"', '');
  }

  // ============================================================================
  // CONTENT PARSING (ML Kit)
  // ============================================================================

  /// Parse content from a file based on its type
  Future<String?> _parseContent(String localPath, String type) async {
    switch (type) {
      case 'image':
        return _parseImage(localPath);
      case 'document':
        return _parseDocument(localPath);
      case 'video':
        return _parseVideo(localPath);
      case 'audio':
        return _parseAudio(localPath);
      default:
        return null;
    }
  }

  /// Parse image: use ImageLabeler for content description + TextRecognizer for any text
  Future<String?> _parseImage(String localPath) async {
    // ML Kit is only available on mobile platforms
    if (!PlatformCapabilities.isMobile) {
      return 'Image: ${p.basename(localPath)}';
    }

    final results = <String>[];

    try {
      final inputImage = InputImage.fromFilePath(localPath);

      // Image labeling
      final labeler = ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.5));
      try {
        final labels = await labeler.processImage(inputImage);
        if (labels.isNotEmpty) {
          results.add('Labels: ${_formatLabels(labels)}');
        }
      } finally {
        await labeler.close();
      }

      // Text recognition
      final textRecognizer = TextRecognizer();
      try {
        final recognizedText = await textRecognizer.processImage(inputImage);
        if (recognizedText.text.isNotEmpty) {
          // Limit text length
          final text = recognizedText.text.length > 500
              ? '${recognizedText.text.substring(0, 500)}...'
              : recognizedText.text;
          results.add('Text: $text');
        }
      } finally {
        await textRecognizer.close();
      }
    } catch (e) {
      debugPrint('Image parsing error for $localPath: $e');
    }

    return results.isEmpty ? null : results.join('\n');
  }

  /// Parse document: read text content directly
  Future<String?> _parseDocument(String localPath) async {
    try {
      final ext = p.extension(localPath).toLowerCase();

      // For text-based files, read directly
      if (['.txt', '.md', '.json', '.xml', '.yaml', '.yml', '.log', '.csv', '.html', '.css', '.js']
          .contains(ext)) {
        final content = await File(localPath).readAsString();
        // Limit content length
        return content.length > 2000
            ? '${content.substring(0, 2000)}...'
            : content;
      }

      // For PDF and image-based documents, try text recognition
      if (['.pdf'].contains(ext)) {
        return 'PDF document: ${p.basename(localPath)}';
      }

      // For other document types with embedded images (docx etc.), try text recognition on first page
      if (PlatformCapabilities.isMobile && ['.png', '.jpg', '.jpeg', '.bmp', '.webp'].contains(ext)) {
        final inputImage = InputImage.fromFilePath(localPath);
        final textRecognizer = TextRecognizer();
        try {
          final recognizedText = await textRecognizer.processImage(inputImage);
          if (recognizedText.text.isNotEmpty) {
            return recognizedText.text.length > 2000
                ? '${recognizedText.text.substring(0, 2000)}...'
                : recognizedText.text;
          }
        } finally {
          await textRecognizer.close();
        }
      }

      return 'Document: ${p.basename(localPath)}';
    } catch (e) {
      debugPrint('Document parsing error for $localPath: $e');
      return 'Document: ${p.basename(localPath)}';
    }
  }

  /// Parse video: extract a thumbnail frame and label it
  Future<String?> _parseVideo(String localPath) async {
    // ML Kit labeling is only available on mobile
    if (!PlatformCapabilities.isMobile) {
      return 'Video: ${p.basename(localPath)}';
    }

    try {
      // Extract thumbnail frame
      final thumbnailBytes = await VideoThumbnail.thumbnailData(
        video: localPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 512,
        maxHeight: 512,
        quality: 75,
      );

      if (thumbnailBytes == null) {
        return 'Video: ${p.basename(localPath)}';
      }

      // Save thumbnail to temp file for ML Kit
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(p.join(tempDir.path, 'website_video_thumb_${_uuid.v4()}.jpg'));
      await tempFile.writeAsBytes(thumbnailBytes);

      try {
        final inputImage = InputImage.fromFilePath(tempFile.path);
        final labeler = ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.5));
        try {
          final labels = await labeler.processImage(inputImage);
          if (labels.isNotEmpty) {
            return 'Video content: ${_formatLabels(labels)}';
          }
        } finally {
          await labeler.close();
        }
      } finally {
        // Clean up temp file
        try {
          await tempFile.delete();
        } catch (_) {}
      }

      return 'Video: ${p.basename(localPath)}';
    } catch (e) {
      debugPrint('Video parsing error for $localPath: $e');
      return 'Video: ${p.basename(localPath)}';
    }
  }

  /// Parse audio: return metadata (filename, type)
  Future<String?> _parseAudio(String localPath) async {
    final fileName = p.basename(localPath);
    final ext = p.extension(localPath).toLowerCase().replaceAll('.', '');
    return 'Audio file: $fileName (format: $ext)';
  }

  // ============================================================================
  // ANALYTICS (opt-in click tracking on generated sites)
  // ============================================================================
  //
  // Backend contract (implement at the URL configured under
  // [SecureStorageKeys.analyticsEndpointUrl], default
  // `https://analytics.cloud.fx.land`). The design is **stateless and
  // CID-keyed**: when the user opts in, the AI generation backend appends
  // a fixed inline `<script>` to the produced HTML before pinning to IPFS.
  // The script self-discovers the IPFS CID from `window.location` (works
  // for subdomain-style `{cid}.ipfs.<gateway>` and path-style
  // `<gateway>/ipfs/{cid}/`) and POSTs that CID to /track. No tokens, no
  // registration, no auth headers anywhere — anyone with the CID can
  // submit pings or read counts, which is fine because the URL IS the CID.
  //
  //   POST /api/v1/track
  //     Body   : {"cid": "<bafy...|Qm...>", "event": "pageview",
  //               "ref": "<document.referrer || ''>"}
  //     Headers: Origin / Referer SHOULD end with `.ipfs.dweb.link` (or
  //              another allow-listed gateway).
  //     Behaviour:
  //       - Reject if `cid` doesn't match a basic CID shape.
  //       - Lazily create a record for `cid` on first sight; increment
  //         pageview count.
  //       - Compute a daily-rotating-salt hash of (IP || UA) and add it to
  //         the per-day unique-visitor set so repeat visits inside a day
  //         collapse to one.
  //       - Never persist raw IP, full UA, or cookies/localStorage.
  //     Abuse  : per-CID-per-IP rate limit, known-bot UA filter, cap on
  //              total distinct CIDs to bound storage.
  //
  //   GET /api/v1/stats/{cid}
  //     No auth header.
  //     Response: {"pageviews": <int>, "uniqueVisitors": <int>}
  //     Returns 404 (or empty counts) for CIDs no `/track` ping has hit yet.
  //
  // Spoofing posture: the CID is public (it's the URL). Anyone can submit
  // arbitrary pings or read counts. Treat counts as approximate.

  /// Aggregate analytics for a generated website, keyed by its IPFS CID.
  /// [pageviews] is a total count; [uniqueVisitors] is approximated via a
  /// daily-rotating salt hash of (IP || UA) and is therefore not exact
  /// across days. Returns null on transport error so the UI can render an
  /// "unavailable" state.
  Future<({int pageviews, int uniqueVisitors})?> fetchAnalytics(
      String cid) async {
    if (cid.isEmpty) return null;
    final analyticsEndpoint = await SecureStorageService.instance
            .read(SecureStorageKeys.analyticsEndpointUrl) ??
        _defaultAnalyticsEndpoint;

    try {
      final response = await http.get(
        Uri.parse('$analyticsEndpoint/api/v1/stats/$cid'),
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 404) {
        return (pageviews: 0, uniqueVisitors: 0);
      }
      if (response.statusCode != 200) {
        debugPrint(
            'fetchAnalytics($cid) failed: ${response.statusCode} '
            '${response.body}');
        return null;
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return (
        pageviews: (body['pageviews'] as num?)?.toInt() ?? 0,
        uniqueVisitors: (body['uniqueVisitors'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      debugPrint('fetchAnalytics($cid) error: $e');
      return null;
    }
  }

  // ============================================================================
  // AI ENDPOINT
  // ============================================================================

  /// Call the AI endpoint to generate a website (async polling model).
  /// Sets resultCid and resultGatewayUrl directly on [generation].
  Future<void> _callAiEndpoint(
    String prompt,
    List<Map<String, dynamic>> assets,
    WebsiteGeneration generation, {
    List<AssetNote> assetNotes = const [],
  }) async {
    final aiEndpoint = await SecureStorageService.instance
            .read(SecureStorageKeys.aiEndpointUrl) ??
        _defaultAiEndpoint;
    final jwt =
        await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);

    if (jwt == null || jwt.isEmpty) {
      throw Exception('No API key configured');
    }

    // 1. POST /api/v1/generate → get jobId (202 Accepted)
    // H2: Add timeout to prevent indefinite hang
    final http.Response response;
    try {
      response = await http.post(
        Uri.parse('$aiEndpoint/api/v1/generate'),
        headers: {
          'Authorization': 'Bearer $jwt',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
        'prompt': _buildAiPrompt(prompt, assetNotes: assetNotes),
        'assets': assets,
        // Opt-in click-tracking. Backend honours by injecting the analytics
        // ping script into the generated HTML before pinning. The script
        // is stateless — it self-discovers the IPFS CID from
        // `window.location` and reports against that, so no token is
        // exchanged here.
        'enable_tracking': generation.trackingEnabled,
      }),
      ).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw Exception('Request timed out. Please try again.');
    }

    // H1: Handle 402 with fallback for missing fields
    if (response.statusCode == 402) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final required = body['required'];
      final balance = body['balance'];
      if (required != null && balance != null) {
        throw Exception(
          'Insufficient credits: need $required FULA, have $balance FULA',
        );
      } else {
        throw Exception('Insufficient credits. Please top up your FULA balance.');
      }
    }
    if (response.statusCode == 429) {
      throw Exception('Rate limit exceeded. Please try again later.');
    }
    if (response.statusCode != 202) {
      throw Exception(
        'Generation request failed (${response.statusCode}): ${response.body}',
      );
    }

    final jobId =
        (jsonDecode(response.body) as Map<String, dynamic>)['jobId'] as String;

    // 2. Poll /api/v1/status/:jobId with exponential backoff (L1)
    Duration pollInterval = const Duration(seconds: 2);
    const maxPollInterval = Duration(seconds: 10);
    const timeout = Duration(minutes: 5);
    final deadline = DateTime.now().add(timeout);
    int consecutiveErrors = 0;

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollInterval);

      // L1: Exponential backoff — increase interval up to max
      if (pollInterval < maxPollInterval) {
        pollInterval = Duration(
          milliseconds: (pollInterval.inMilliseconds * 1.5)
              .toInt()
              .clamp(0, maxPollInterval.inMilliseconds),
        );
      }

      final statusResponse = await http.get(
        Uri.parse('$aiEndpoint/api/v1/status/$jobId'),
        headers: {'Authorization': 'Bearer $jwt'},
      );

      // H3: Handle poll errors — break on auth/not-found, count consecutive failures
      if (statusResponse.statusCode != 200) {
        consecutiveErrors++;
        if (statusResponse.statusCode == 401 ||
            statusResponse.statusCode == 403) {
          throw Exception('Authentication expired. Please log in again.');
        }
        if (statusResponse.statusCode == 404) {
          throw Exception('Generation job not found.');
        }
        if (consecutiveErrors >= 5) {
          throw Exception(
            'Status check failed after $consecutiveErrors consecutive errors',
          );
        }
        continue;
      }

      consecutiveErrors = 0;

      final status =
          jsonDecode(statusResponse.body) as Map<String, dynamic>;
      final serverStatus = status['status'] as String?;
      final statusMsg = status['statusMessage'] as String?;

      // Relay server-side status to UI
      if (statusMsg != null) {
        generation.statusMessage = statusMsg;
        generation.updatedAt = DateTime.now();
        await _generationsBox.put(generation.id, generation);
        _statusController.add(generation);
      }

      if (serverStatus == 'completed') {
        // M3: Store CID and gateway URL separately
        generation.resultCid = status['resultCid'] as String?;
        generation.resultGatewayUrl = status['gatewayUrl'] as String?;
        return;
      }
      if (serverStatus == 'error') {
        throw Exception(
          (status['errorMessage'] as String?) ?? 'Generation failed',
        );
      }
      // Still pending/generating/publishing — continue polling
    }

    throw Exception('Generation timed out after 5 minutes');
  }

  // ============================================================================
  // HELPERS
  // ============================================================================

  /// Build an IPFS gateway URL from a CID
  Future<String> _buildGatewayUrl(String cid) async {
    final gateway = await SecureStorageService.instance
            .read(SecureStorageKeys.ipfsGatewayUrl) ??
        IpfsGatewayHelper.defaultTemplate;
    return IpfsGatewayHelper.buildUrl(gateway, cid);
  }

  /// L4: Format ML Kit labels into a readable string
  String _formatLabels(List<ImageLabel> labels) {
    return labels
        .take(10)
        .map((l) => '${l.label} (${(l.confidence * 100).toInt()}%)')
        .join(', ');
  }

  // ============================================================================
  // CLOUD SYNC
  // ============================================================================

  void _scheduleSyncToCloud() {
    if (_syncScheduled) return;
    _syncScheduled = true;

    Future.delayed(_syncDebounce, () async {
      _syncScheduled = false;
      await syncToCloud();
    });
  }

  /// Ensure the website metadata bucket exists
  Future<bool> _ensureMetadataBucketExists() async {
    if (_metaBucketChecked && _metaBucketExists) return true;

    try {
      await FulaApiService.instance.createBucket(_websiteMetadataBucket);
      _metaBucketExists = true;
      _metaBucketChecked = true;
      return true;
    } catch (e) {
      final errorStr = e.toString();

      if (errorStr.contains('BucketAlreadyExists') ||
          errorStr.contains('BucketAlreadyOwnedByYou')) {
        _metaBucketExists = true;
        _metaBucketChecked = true;
        return true;
      }

      try {
        await FulaApiService.instance.listObjects(_websiteMetadataBucket);
        _metaBucketExists = true;
        _metaBucketChecked = true;
        return true;
      } catch (listError) {
        final listErrorStr = listError.toString();
        if (listErrorStr.contains('AccountProblem') ||
            listErrorStr.contains('AccessDenied') ||
            listErrorStr.contains('QuotaExceeded')) {
          _metaBucketExists = false;
          _metaBucketChecked = true;
          return false;
        }

        _metaBucketExists = false;
        _metaBucketChecked = false;
        return false;
      }
    }
  }

  /// Get user ID for cloud storage key
  Future<String?> _getUserId() async {
    try {
      final publicKey = await AuthService.instance.getPublicKeyString();
      if (publicKey == null || publicKey.isEmpty) return null;

      final bytes = utf8.encode(publicKey);
      final hash = sha256.convert(bytes);
      return hash.toString().substring(0, 16);
    } catch (e) {
      debugPrint('WebsiteService: Failed to get user ID: $e');
      return null;
    }
  }

  /// Sync all completed generations to cloud
  Future<void> syncToCloud() async {
    if (_metaBucketChecked && !_metaBucketExists) return;
    if (!FulaApiService.instance.isConfigured) return;

    final now = DateTime.now();
    if (_lastSyncTime != null &&
        now.difference(_lastSyncTime!) < const Duration(seconds: 2)) {
      return;
    }
    _lastSyncTime = now;

    if (!await _ensureMetadataBucketExists()) return;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;

      final userId = await _getUserId();
      if (userId == null) return;

      // Only sync completed generations
      final completed = _generationsBox.values
          .where((g) => g.status == WebsiteGenStatus.completed)
          .map((g) => g.toJson())
          .toList();

      final jsonStr = jsonEncode({'generations': completed, 'updatedAt': DateTime.now().toIso8601String()});
      final data = Uint8List.fromList(utf8.encode(jsonStr));

      final key = '.fula/websites/$userId.json';
      await FulaApiService.instance.encryptAndUpload(
        _websiteMetadataBucket,
        key,
        data,
        encryptionKey,
        contentType: 'application/json',
      );

      debugPrint('Website generations synced to cloud: ${completed.length} generations');
    } catch (e) {
      debugPrint('WebsiteService: syncToCloud error: $e');
      final errorStr = e.toString();

      if (errorStr.contains('NoSuchBucket') || errorStr.contains('bucket not found')) {
        _metaBucketChecked = false;
        _metaBucketExists = false;
        return;
      }

      if (errorStr.contains('AccountProblem') ||
          errorStr.contains('QuotaExceeded') ||
          errorStr.contains('AccessDenied')) {
        _metaBucketExists = false;
        _metaBucketChecked = true;
      }
    }
  }

  /// Restore generations from cloud after reinstall
  Future<void> restoreFromCloud() async {
    if (!_isInitialized) await init();
    if (!FulaApiService.instance.isConfigured) return;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;

      final userId = await _getUserId();
      if (userId == null) return;

      final key = '.fula/websites/$userId.json';
      final data = await FulaApiService.instance.downloadAndDecrypt(
        _websiteMetadataBucket,
        key,
        encryptionKey,
      );

      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final generationsList = json['generations'] as List<dynamic>? ?? [];

      if (_generationsBox.isEmpty || generationsList.isNotEmpty) {
        // Preserve any in-progress local generations
        final localInProgress = _generationsBox.values
            .where((g) => g.status != WebsiteGenStatus.completed)
            .toList();

        await _generationsBox.clear();

        // Restore completed generations from cloud
        for (final genJson in generationsList) {
          final gen = WebsiteGeneration.fromJson(genJson as Map<String, dynamic>);
          await _generationsBox.put(gen.id, gen);
        }

        // Re-add local in-progress generations
        for (final gen in localInProgress) {
          await _generationsBox.put(gen.id, gen);
        }

        debugPrint('Restored ${generationsList.length} website generations from cloud');
      }
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('NoSuchKey') || errorStr.contains('Object not found') || errorStr.contains('404')) {
        debugPrint('Website restore: no cloud data found (new user or never synced)');
      } else {
        debugPrint('Failed to restore website generations from cloud: $e');
      }
    }

    // Stable-link pointers + their signing keys live in a sibling encrypted
    // blob; restore them alongside website data so a fresh install / new device
    // keeps the same shareable IPNS links and can keep updating them.
    await IpnsPointerService.instance.restoreFromCloud();
  }

  /// Dispose resources
  void dispose() {
    _statusController.close();
  }
}
