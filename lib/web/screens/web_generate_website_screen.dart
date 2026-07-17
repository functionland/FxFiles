import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/models/contact_form_config.dart';
import 'package:fula_files/core/services/website_service.dart';
import 'package:fula_files/core/services/website_prompt_builder.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/google_forms_service.dart';
import 'package:fula_files/web/services/web_website_service.dart';

/// Result returned when the user taps Publish — same shape as the
/// native GenerateWebsitePromptResult.
typedef WebGeneratePromptResult = ({
  String websiteName,
  String category,
  List<String> styles,
  List<String> languages,
  String palette,
  String prompt,
  bool enableTracking,
  ContactFormConfig? contactForm,
});

class _PaletteOption {
  final String label;
  final String description;
  final List<Color> colors;
  const _PaletteOption(this.label, this.description, this.colors);
}

// Same labels/order as the native generator (labels are stored verbatim
// in the prompt; hidden instructions key off them).
const List<_PaletteOption> _paletteOptions = [
  _PaletteOption('Auto from attachments', 'Sampled from your files', [
    Color(0xFFEF4444),
    Color(0xFFF59E0B),
    Color(0xFF14B8A6),
    Color(0xFF6366F1),
  ]),
  _PaletteOption('Warm', 'Reds, oranges, golds', [
    Color(0xFFC73838),
    Color(0xFFF59E0B),
    Color(0xFFEAB308),
    Color(0xFFFEDFB1),
  ]),
  _PaletteOption('Cold', 'Blues, teals, slate', [
    Color(0xFF1E40AF),
    Color(0xFF0EA5E9),
    Color(0xFF14B8A6),
    Color(0xFF475569),
  ]),
  _PaletteOption('Grey tone', 'Strictly monochrome', [
    Color(0xFF111827),
    Color(0xFF6B7280),
    Color(0xFFD1D5DB),
    Color(0xFFF9FAFB),
  ]),
];

class _StyleOption {
  final String label;
  final String description;
  final Color bg;
  final Color fg;
  final Color accent;
  const _StyleOption(
      this.label, this.description, this.bg, this.fg, this.accent);
}

const List<_StyleOption> _styleOptions = [
  _StyleOption('Minimal', 'Lots of whitespace', Color(0xFFF5F2EC),
      Color(0xFF1A1A1A), Color(0xFF1A1A1A)),
  _StyleOption('Editorial', 'Magazine-style', Color(0xFFFFFFFF),
      Color(0xFF0E0E0E), Color(0xFFC73838)),
  _StyleOption('Bold', 'Big type, high contrast', Color(0xFF0E0E0E),
      Color(0xFFFFD84D), Color(0xFFFF5C8A)),
  _StyleOption('Playful', 'Soft, rounded, fun', Color(0xFFFFE9D6),
      Color(0xFF3C2417), Color(0xFFFF8A4C)),
  _StyleOption('Glassy', 'Translucent, layered', Color(0xFF0B2E4A),
      Color(0xFFFFFFFF), Color(0xFF7DD3FC)),
  _StyleOption('Monospace', 'Technical, terminal', Color(0xFF0E1A12),
      Color(0xFF7CFFB2), Color(0xFF7CFFB2)),
  _StyleOption('Brutalist', 'Raw, gridded, stark', Color(0xFFFFFFFF),
      Color(0xFF000000), Color(0xFFFF3B00)),
  _StyleOption('Gallery', 'Image-first grid', Color(0xFF1A1A1A),
      Color(0xFFF0EBE0), Color(0xFFF0EBE0)),
];

const List<String> _categoryOptions = [
  'Personal',
  'Real Estate',
  'Automotives',
  'Shop',
  'Corporation',
  'Technology',
  'Resume',
  'Other',
];

/// Mutable per-row state for one contact-form field.
class _ContactFieldRow {
  final TextEditingController label;
  ContactFormFieldType type;
  bool required;
  final TextEditingController options;

  _ContactFieldRow({
    String label = '',
    this.type = ContactFormFieldType.text,
    this.required = false,
    String options = '',
  })  : label = TextEditingController(text: label),
        options = TextEditingController(text: options);

  void dispose() {
    label.dispose();
    options.dispose();
  }

  ContactFormField toField() => ContactFormField(
        label: label.text.trim(),
        type: type,
        required: required,
        options: type == ContactFormFieldType.multiSelect
            ? options.text
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList()
            : const [],
      );
}

/// Mirror of lib/features/websites/screens/generate_website_screen.dart
/// for the web shell — same fields, strings, hidden-instruction keys
/// and result shape; pops the payload for the detail screen to publish.
class WebGenerateWebsiteScreen extends StatefulWidget {
  final String defaultName;
  final List<AssetNote> assetNotes;

  // Recreate prefills (native parity): seed every field from a prior
  // generation's parsed prompt.
  final String? initialName;
  final String? initialCategory;
  final List<String>? initialStyles;
  final String? initialPalette;
  final String? initialPrompt;
  final bool initialEnableTracking;
  final ContactFormConfig? initialContactForm;
  final List<String>? initialLanguages;

  const WebGenerateWebsiteScreen({
    super.key,
    required this.defaultName,
    this.assetNotes = const [],
    this.initialName,
    this.initialCategory,
    this.initialStyles,
    this.initialPalette,
    this.initialPrompt,
    this.initialEnableTracking = false,
    this.initialContactForm,
    this.initialLanguages,
  });

  @override
  State<WebGenerateWebsiteScreen> createState() =>
      _WebGenerateWebsiteScreenState();
}

class _WebGenerateWebsiteScreenState extends State<WebGenerateWebsiteScreen> {
  late final TextEditingController _nameController = TextEditingController(
      text: (widget.initialName?.isNotEmpty ?? false)
          ? widget.initialName!
          : widget.defaultName);
  late final TextEditingController _promptController =
      TextEditingController(text: widget.initialPrompt ?? '');
  late String _category = _categoryOptions.contains(widget.initialCategory)
      ? widget.initialCategory!
      : _categoryOptions.first;
  late String _selectedStyle = () {
    final first = widget.initialStyles?.firstOrNull;
    return _styleOptions.any((o) => o.label == first)
        ? first!
        : _styleOptions.first.label;
  }();
  late String _palette =
      _paletteOptions.any((o) => o.label == widget.initialPalette)
          ? widget.initialPalette!
          : _paletteOptions.first.label;
  late bool _enableTracking = widget.initialEnableTracking;

  late final List<String> _selectedLanguages = () {
    final known = websiteLanguageAutonyms.keys.toSet();
    final init = (widget.initialLanguages ?? const <String>[])
        .where(known.contains)
        .take(3)
        .toList();
    return init.isEmpty ? <String>['English'] : init;
  }();

  late bool _contactFormEnabled = widget.initialContactForm?.enabled ?? false;
  late ContactFormChannel _channel =
      widget.initialContactForm?.channel ?? ContactFormChannel.whatsapp;
  late final TextEditingController _destinationController =
      TextEditingController(text: widget.initialContactForm?.destination ?? '');
  late final TextEditingController _emailSubjectController =
      TextEditingController(
          text: widget.initialContactForm?.emailSubject ?? '');
  late final TextEditingController _titleController =
      TextEditingController(text: widget.initialContactForm?.title ?? '');
  late final List<_ContactFieldRow> _fields = () {
    final initial = widget.initialContactForm?.fields ?? const [];
    if (initial.isEmpty) return [_ContactFieldRow()];
    return [
      for (final f in initial)
        _ContactFieldRow(
          label: f.label,
          type: f.type,
          required: f.required,
          options: f.options.join(', '),
        ),
    ];
  }();

  ({int costFula, int costFulaWithTracking})? _pricing;

  @override
  void initState() {
    super.initState();
    WebWebsiteService.instance.fetchPricing().then((p) {
      if (mounted && p != null) setState(() => _pricing = p);
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _promptController.dispose();
    _destinationController.dispose();
    _emailSubjectController.dispose();
    _titleController.dispose();
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  ContactFormConfig _currentContactForm() => ContactFormConfig(
        enabled: _contactFormEnabled,
        channel: _channel,
        destination: _destinationController.text.trim(),
        emailSubject: _emailSubjectController.text.trim(),
        title: _titleController.text.trim(),
        fields: _fields.map((r) => r.toField()).toList(),
      );

  /// Same loose checks as the native screen (TargetUriBuilder lives in
  /// a dart:io-tainted file, so the 4-line phone rule is copied here).
  String? _validateContactForm(ContactFormConfig cfg) {
    final dest = cfg.destination.trim();
    if (cfg.channel == ContactFormChannel.whatsapp) {
      final digits = dest.replaceAll(RegExp(r'\D'), '');
      if (digits.length < 7 || digits.length > 15) {
        return 'Enter a valid WhatsApp number (7–15 digits, with country code).';
      }
    } else if (cfg.channel == ContactFormChannel.email) {
      final at = dest.indexOf('@');
      final emailOk =
          at > 0 && at != dest.length - 1 && dest.indexOf('.', at) > at + 1;
      if (!emailOk) {
        return 'Enter a valid destination email address.';
      }
    }
    final usable = cfg.usableFields;
    if (usable.isEmpty) {
      return 'Add at least one form field with a label.';
    }
    for (final f in usable) {
      if (f.type == ContactFormFieldType.multiSelect && f.options.isEmpty) {
        return 'Multi-select field "${f.label}" needs at least one option.';
      }
    }
    return null;
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    var contactForm = _currentContactForm();
    if (contactForm.enabled) {
      final error = _validateContactForm(contactForm);
      if (error != null) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error)));
        }
        return;
      }

      if (contactForm.channel == ContactFormChannel.sheets) {
        bool isLoadingShown = false;
        try {
          final granted = await AuthService.instance.requestFormsScope();
          if (!mounted) return;
          if (!granted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('Google Forms permission is required.')),
            );
            return;
          }

          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => const Center(child: CircularProgressIndicator()),
          );
          isLoadingShown = true;

          final token = await AuthService.instance.getGoogleAccessToken();
          if (!mounted) return;
          if (token == null) {
            if (isLoadingShown) Navigator.of(context).pop();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('Failed to get Google authorization token.')),
            );
            return;
          }

          final responderUri = await GoogleFormsService.instance.createForm(
            title: contactForm.title,
            fields: contactForm.usableFields,
            accessToken: token,
          );

          if (!mounted) return;
          if (isLoadingShown) Navigator.of(context).pop(); // dismiss loading

          contactForm = ContactFormConfig(
            enabled: contactForm.enabled,
            channel: contactForm.channel,
            destination: responderUri,
            emailSubject: contactForm.emailSubject,
            title: contactForm.title,
            fields: contactForm.fields,
          );
        } catch (e) {
          if (!mounted) return;
          if (isLoadingShown) Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error creating form: $e')),
          );
          return;
        }
      }
    }

    if (mounted) {
      Navigator.of(context).pop<WebGeneratePromptResult>((
        websiteName: name,
        category: _category,
        styles: <String>[_selectedStyle],
        languages: _selectedLanguages,
        palette: _palette,
        prompt: _promptController.text.trim(),
        enableTracking: _enableTracking,
        contactForm: contactForm.enabled ? contactForm : null,
      ));
    }
  }

  void _showPromptPreview() {
    final fullPrompt = buildWebsiteAiPrompt(
      composeEnrichedWebsitePrompt(
        websiteName: _nameController.text.trim(),
        category: _category,
        styles: <String>[_selectedStyle],
        languages: _selectedLanguages,
        palette: _palette,
        body: _promptController.text.trim(),
        contactForm: _contactFormEnabled ? _currentContactForm() : null,
      ),
      assetNotes: widget.assetNotes,
      cidsAvailable: false,
    );
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Full prompt preview'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 480),
          child: SingleChildScrollView(
            child: SelectableText(
              fullPrompt,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: fullPrompt));
              Navigator.pop(ctx);
            },
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nameEmpty = _nameController.text.trim().isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Generate Website')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _nameController,
                maxLength: 60,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Website Name',
                  hintText: 'e.g. "My Portfolio"',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final c in _categoryOptions)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => setState(() => _category = v ?? _category),
              ),
              const SizedBox(height: 16),
              Text('Style · pick one',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              SizedBox(
                height: 96,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _styleOptions.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (ctx, i) {
                    final o = _styleOptions[i];
                    final selected = _selectedStyle == o.label;
                    return InkWell(
                      onTap: () => setState(() => _selectedStyle = o.label),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: 130,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: o.bg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: selected
                                ? AppColors.primary
                                : theme.dividerColor,
                            width: selected ? 2 : 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 40,
                              height: 6,
                              color: o.accent,
                            ),
                            const Spacer(),
                            Text(o.label,
                                style: TextStyle(
                                    color: o.fg,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700)),
                            Text(o.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: o.fg.withValues(alpha: 0.75),
                                    fontSize: 10)),
                            if (selected) ...[
                              const SizedBox(height: 2),
                              const Icon(LucideIcons.checkCircle2,
                                  size: 14, color: AppColors.primary),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Text('Color palette · pick one',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              SizedBox(
                height: 84,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _paletteOptions.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (ctx, i) {
                    final o = _paletteOptions[i];
                    final selected = _palette == o.label;
                    return InkWell(
                      onTap: () => setState(() => _palette = o.label),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: 150,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: selected
                                ? AppColors.primary
                                : theme.dividerColor,
                            width: selected ? 2 : 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                for (final c in o.colors)
                                  Expanded(
                                    child: Container(height: 22, color: c),
                                  ),
                              ],
                            ),
                            const Spacer(),
                            Text(o.label,
                                style: const TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w600)),
                            Text(o.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(fontSize: 10)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              _languagesSection(theme),
              const SizedBox(height: 16),
              TextField(
                controller: _promptController,
                maxLength: 9000,
                minLines: 4,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: 'Your creative direction',
                  hintText:
                      'Add anything specific about content, layout, or theme '
                      '— leave blank to use only the category and styles '
                      'above.',
                  helperText: 'Category- and style-specific instructions plus '
                      'technical constraints (static site, IPFS hosting, '
                      'responsive design) are added automatically.',
                  helperMaxLines: 3,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Preview full prompt',
                    icon: const Icon(LucideIcons.eye, size: 18),
                    onPressed: _showPromptPreview,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _trackingToggle(theme),
              const SizedBox(height: 8),
              _contactFormSection(theme),
              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: nameEmpty ? null : _submit,
                style:
                    FilledButton.styleFrom(backgroundColor: AppColors.primary),
                icon: const Icon(LucideIcons.sparkles, size: 18),
                label: const Text('Publish'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleLanguage(String lang, bool selected) {
    setState(() {
      if (selected) {
        if (!_selectedLanguages.contains(lang) &&
            _selectedLanguages.length < 3) {
          _selectedLanguages.add(lang);
        }
      } else {
        _selectedLanguages.remove(lang);
        if (_selectedLanguages.isEmpty) _selectedLanguages.add('English');
      }
    });
  }

  Widget _languagesSection(ThemeData theme) {
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final atCap = _selectedLanguages.length >= 3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Languages · pick up to 3',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          'Choosing more than one adds a language switcher to the generated '
          'site.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in websiteLanguageAutonyms.entries)
              _languageChip(theme, entry.key, entry.value, atCap),
          ],
        ),
      ],
    );
  }

  Widget _languageChip(
      ThemeData theme, String lang, String autonym, bool atCap) {
    final selected = _selectedLanguages.contains(lang);
    final disabled = !selected && atCap;
    final label = lang == autonym ? lang : '$lang · $autonym';
    return FilterChip(
      avatar: Icon(
        Icons.language,
        size: 16,
        color: disabled ? theme.disabledColor : null,
      ),
      showCheckmark: false,
      selectedColor: AppColors.primary.withValues(alpha: 0.18),
      label: Text(
        label,
        // Non-Latin autonyms (العربية, हिन्दी, 中文, 日本語…) render via a
        // fallback font whose glyphs overflow the tight default line box and
        // get clipped at the chip's bottom edge. A roomier, evenly-distributed
        // line height gives every script vertical room; Latin is unaffected.
        style: const TextStyle(
          height: 1.5,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
      selected: selected,
      onSelected: disabled ? null : (sel) => _toggleLanguage(lang, sel),
    );
  }

  Widget _trackingToggle(ThemeData theme) {
    final pricing = _pricing;
    final surcharge = pricing != null
        ? pricing.costFulaWithTracking - pricing.costFula
        : null;
    final surchargeLabel =
        (surcharge != null && surcharge > 0) ? ' (+$surcharge FULA)' : '';
    final effectiveCost = pricing != null
        ? (_enableTracking ? pricing.costFulaWithTracking : pricing.costFula)
        : null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text('Enable click tracking$surchargeLabel'),
            subtitle: const Text(
              'Adds a privacy-friendly script (no cookies, no PII) so you '
              'can see view and visitor counts next to this generation. '
              'Off by default.',
              style: TextStyle(fontSize: 11),
            ),
            value: _enableTracking,
            onChanged: (v) => setState(() => _enableTracking = v),
          ),
          if (effectiveCost != null)
            Row(
              children: [
                const Icon(LucideIcons.coins,
                    size: 14, color: AppColors.primary),
                const SizedBox(width: 6),
                Text('Cost: $effectiveCost FULA',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _contactFormSection(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Add a contact form'),
            subtitle: const Text(
              'Visitors fill it in and tap Send — it opens WhatsApp or '
              'their mail app with the message pre-composed. No server, '
              'nothing collected by us.',
              style: TextStyle(fontSize: 11),
            ),
            value: _contactFormEnabled,
            onChanged: (v) => setState(() {
              _contactFormEnabled = v;
              // Default the message header to the website name, but only when
              // the creator hasn't typed one — keeps it editable and clearable.
              if (v && _titleController.text.trim().isEmpty) {
                _titleController.text = _nameController.text.trim();
              }
            }),
          ),
          if (_contactFormEnabled) ...[
            const SizedBox(height: 8),
            SegmentedButton<ContactFormChannel>(
              segments: const [
                ButtonSegment(
                  value: ContactFormChannel.whatsapp,
                  label: Text('WhatsApp'),
                ),
                ButtonSegment(
                  value: ContactFormChannel.email,
                  label: Text('Email'),
                ),
                ButtonSegment(
                  value: ContactFormChannel.sheets,
                  label: Text('Sheets'),
                ),
              ],
              selected: {_channel},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _channel = s.first),
            ),
            if (_channel != ContactFormChannel.sheets) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _destinationController,
                decoration: InputDecoration(
                  labelText: _channel == ContactFormChannel.whatsapp
                      ? 'WhatsApp number'
                      : 'Destination email',
                  hintText: _channel == ContactFormChannel.whatsapp
                      ? 'e.g. +1 555 123 4567'
                      : 'you@example.com',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
            if (_channel == ContactFormChannel.email) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _emailSubjectController,
                decoration: const InputDecoration(
                  labelText: 'Email subject (optional)',
                  hintText: 'e.g. New enquiry from your website',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _titleController,
              decoration: InputDecoration(
                labelText: _channel == ContactFormChannel.sheets
                    ? 'Google Form title (optional)'
                    : 'Message header (optional)',
                hintText: 'e.g. your website name',
                helperText: _channel == ContactFormChannel.sheets
                    ? 'The title displayed at the top of the Google Form.'
                    : 'Added as "#Title: …" atop each message. Defaults to the website name; clear to omit.',
                helperMaxLines: 3,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('Form fields',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () =>
                      setState(() => _fields.add(_ContactFieldRow())),
                  icon: const Icon(LucideIcons.plus, size: 14),
                  label: const Text('Add field'),
                ),
              ],
            ),
            for (var i = 0; i < _fields.length; i++) _fieldRow(theme, i),
          ],
        ],
      ),
    );
  }

  Widget _fieldRow(ThemeData theme, int index) {
    final row = _fields[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: row.label,
                  decoration: const InputDecoration(
                    labelText: 'Label',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<ContactFormFieldType>(
                  initialValue: row.type,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: ContactFormFieldType.text, child: Text('Text')),
                    DropdownMenuItem(
                        value: ContactFormFieldType.multiline,
                        child: Text('Multi-line')),
                    DropdownMenuItem(
                        value: ContactFormFieldType.number,
                        child: Text('Number')),
                    DropdownMenuItem(
                        value: ContactFormFieldType.email,
                        child: Text('Email')),
                    DropdownMenuItem(
                        value: ContactFormFieldType.multiSelect,
                        child: Text('Multi-select')),
                  ],
                  onChanged: (v) => setState(() => row.type = v ?? row.type),
                ),
              ),
              IconButton(
                tooltip: 'Remove field',
                icon: const Icon(LucideIcons.x, size: 16),
                onPressed: _fields.length <= 1
                    ? null
                    : () => setState(() {
                          _fields.removeAt(index).dispose();
                        }),
              ),
            ],
          ),
          if (row.type == ContactFormFieldType.multiSelect)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: TextField(
                controller: row.options,
                decoration: const InputDecoration(
                  labelText: 'Options (comma-separated)',
                  hintText: 'e.g. Sales, Support, Press',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: row.required,
                  onChanged: (v) => setState(() => row.required = v ?? false),
                ),
                const Text('Required', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
