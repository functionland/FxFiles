import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:fula_files/app/theme/app_colors.dart';
import 'package:fula_files/core/services/website_service.dart';

/// Result returned by [GenerateWebsiteScreen] when the user taps Publish.
typedef GenerateWebsitePromptResult = ({
  String websiteName,
  String category,
  List<String> styles,
  String palette,
  String prompt,
  bool enableTracking,
});

/// Palette options shown in the generator. Labels are stored verbatim in the
/// generation prompt; the corresponding hidden instruction lives in
/// `WebsiteService._paletteInstructions`. The first entry is the default
/// selection — it tells the AI to derive colors from the user's attached
/// files. Order/labels must stay stable so older "Recreate" flows still
/// resolve correctly.
class _PaletteOption {
  final String label;
  final String description;
  final List<Color> colors; // 4 colors painted as vertical bands in the swatch

  const _PaletteOption({
    required this.label,
    required this.description,
    required this.colors,
  });
}

const List<_PaletteOption> _paletteOptions = [
  // First entry is the default. Swatch uses four unrelated hues to read as
  // "could be anything — I'll match your photos".
  _PaletteOption(
    label: 'Auto from attachments',
    description: 'Sampled from your files',
    colors: [
      Color(0xFFEF4444),
      Color(0xFFF59E0B),
      Color(0xFF14B8A6),
      Color(0xFF6366F1),
    ],
  ),
  _PaletteOption(
    label: 'Warm',
    description: 'Reds, oranges, golds',
    colors: [
      Color(0xFFC73838),
      Color(0xFFF59E0B),
      Color(0xFFEAB308),
      Color(0xFFFEDFB1),
    ],
  ),
  _PaletteOption(
    label: 'Cold',
    description: 'Blues, teals, slate',
    colors: [
      Color(0xFF1E40AF),
      Color(0xFF0EA5E9),
      Color(0xFF14B8A6),
      Color(0xFF475569),
    ],
  ),
  _PaletteOption(
    label: 'Grey tone',
    description: 'Strictly monochrome',
    colors: [
      Color(0xFF111827),
      Color(0xFF6B7280),
      Color(0xFFD1D5DB),
      Color(0xFFF9FAFB),
    ],
  ),
];

/// Style options shown in the generator. Labels are stored verbatim in the
/// generation prompt; corresponding hidden instructions live in
/// [WebsiteService._styleInstructions]. Order, labels, and swatch palette match
/// the design handoff (`STYLE_OPTIONS` in `screens.jsx`).
class _StyleOption {
  final String label;
  final String description;
  final Color bg;
  final Color fg;
  final Color accent;
  final double titleH;

  const _StyleOption({
    required this.label,
    required this.description,
    required this.bg,
    required this.fg,
    required this.accent,
    required this.titleH,
  });
}

const List<_StyleOption> _styleOptions = [
  _StyleOption(
    label: 'Minimal',
    description: 'Lots of whitespace',
    bg: Color(0xFFF5F2EC),
    fg: Color(0xFF1A1A1A),
    accent: Color(0xFF1A1A1A),
    titleH: 10,
  ),
  _StyleOption(
    label: 'Editorial',
    description: 'Magazine-style',
    bg: Color(0xFFFFFFFF),
    fg: Color(0xFF0E0E0E),
    accent: Color(0xFFC73838),
    titleH: 12,
  ),
  _StyleOption(
    label: 'Bold',
    description: 'Big type, high contrast',
    bg: Color(0xFF0E0E0E),
    fg: Color(0xFFFFD84D),
    accent: Color(0xFFFF5C8A),
    titleH: 14,
  ),
  _StyleOption(
    label: 'Playful',
    description: 'Soft, rounded, fun',
    bg: Color(0xFFFFE9D6),
    fg: Color(0xFF3C2417),
    accent: Color(0xFFFF8A4C),
    titleH: 10,
  ),
  _StyleOption(
    label: 'Glassy',
    description: 'Translucent, layered',
    bg: Color(0xFF0B2E4A),
    fg: Color(0xFFFFFFFF),
    accent: Color(0xFF7DD3FC),
    titleH: 9,
  ),
  _StyleOption(
    label: 'Monospace',
    description: 'Technical, terminal',
    bg: Color(0xFF0E1A12),
    fg: Color(0xFF7CFFB2),
    accent: Color(0xFF7CFFB2),
    titleH: 8,
  ),
  _StyleOption(
    label: 'Brutalist',
    description: 'Raw, gridded, stark',
    bg: Color(0xFFFFFFFF),
    fg: Color(0xFF000000),
    accent: Color(0xFFFF3B00),
    titleH: 12,
  ),
  _StyleOption(
    label: 'Gallery',
    description: 'Image-first grid',
    bg: Color(0xFF1A1A1A),
    fg: Color(0xFFF0EBE0),
    accent: Color(0xFFF0EBE0),
    titleH: 7,
  ),
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


/// Full-screen replacement for the previous "Generate website" dialog.
///
/// Pop the screen with the [GenerateWebsitePromptResult] payload to publish,
/// or with `null` (Cancel / system back) to abandon the draft.
class GenerateWebsiteScreen extends StatefulWidget {
  final String defaultName;
  final String? initialName;
  final String? initialCategory;
  final List<String>? initialStyles;
  final String? initialPalette;
  final String? initialPrompt;
  final bool initialEnableTracking;

  /// Per-asset user notes captured in the website detail screen. Used by the
  /// "preview full prompt" eye icon so the user can see exactly what the AI
  /// will receive. Empty when no notes were entered.
  final List<AssetNote> assetNotes;

  const GenerateWebsiteScreen({
    super.key,
    required this.defaultName,
    this.initialName,
    this.initialCategory,
    this.initialStyles,
    this.initialPalette,
    this.initialPrompt,
    this.initialEnableTracking = false,
    this.assetNotes = const [],
  });

  @override
  State<GenerateWebsiteScreen> createState() => _GenerateWebsiteScreenState();
}

class _GenerateWebsiteScreenState extends State<GenerateWebsiteScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _promptController;
  late String _category;
  late String _palette;
  late String _selectedStyle;
  late bool _enableTracking;

  @override
  void initState() {
    super.initState();
    _enableTracking = widget.initialEnableTracking;
    _nameController = TextEditingController(
      text: (widget.initialName != null && widget.initialName!.isNotEmpty)
          ? widget.initialName!
          : widget.defaultName,
    );
    _promptController = TextEditingController(text: widget.initialPrompt ?? '');
    _category = (widget.initialCategory != null &&
            _categoryOptions.contains(widget.initialCategory))
        ? widget.initialCategory!
        : _categoryOptions.first;
    final knownPaletteLabels = _paletteOptions.map((p) => p.label).toSet();
    _palette = (widget.initialPalette != null &&
            knownPaletteLabels.contains(widget.initialPalette))
        ? widget.initialPalette!
        : _paletteOptions.first.label;
    // Single-select style: take the first valid label from any pre-existing
    // styles list (older multi-select records may carry several), else fall
    // back to the first option as the default.
    final knownLabels = _styleOptions.map((s) => s.label).toSet();
    final firstValid = widget.initialStyles
        ?.firstWhere(knownLabels.contains, orElse: () => '');
    _selectedStyle = (firstValid != null && firstValid.isNotEmpty)
        ? firstValid
        : _styleOptions.first.label;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final result = (
      websiteName: name,
      category: _category,
      styles: <String>[_selectedStyle],
      palette: _palette,
      prompt: _promptController.text.trim(),
      enableTracking: _enableTracking,
    );
    Navigator.of(context).pop<GenerateWebsitePromptResult>(result);
  }

  void _showPromptPreview() {
    final fullPrompt = WebsiteService.instance.buildPreviewPrompt(
      websiteName: _nameController.text.trim(),
      category: _category,
      styles: <String>[_selectedStyle],
      palette: _palette,
      body: _promptController.text.trim(),
      assetNotes: widget.assetNotes,
    );

    showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: const Text('Full prompt preview'),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.6,
              maxWidth: 600,
            ),
            child: Scrollbar(
              child: SingleChildScrollView(
                primary: false,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    fullPrompt,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: fullPrompt));
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Prompt copied')),
                );
              },
              icon: const Icon(LucideIcons.copy, size: 16),
              label: const Text('Copy'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nameEmpty = _nameController.text.trim().isEmpty;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Generate Website'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              children: [
                TextField(
                  controller: _nameController,
                  maxLength: 60,
                  decoration: const InputDecoration(
                    labelText: 'Website Name',
                    hintText: 'e.g. "My Portfolio"',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  decoration: const InputDecoration(
                    labelText: 'Category',
                    border: OutlineInputBorder(),
                  ),
                  items: _categoryOptions
                      .map(
                        (c) => DropdownMenuItem(value: c, child: Text(c)),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _category = v);
                  },
                ),
                const SizedBox(height: 24),
                _buildStyleHeader(theme),
                const SizedBox(height: 10),
                _buildStyleCardsRow(),
                const SizedBox(height: 24),
                _buildPaletteHeader(theme),
                const SizedBox(height: 10),
                _buildPaletteCardsRow(),
                const SizedBox(height: 24),
                TextField(
                  controller: _promptController,
                  maxLines: 6,
                  minLines: 4,
                  maxLength: 9000,
                  decoration: const InputDecoration(
                    labelText: 'Your creative direction',
                    hintText:
                        'Add anything specific about content, layout, or theme — leave blank to use only the category and styles above.',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        'Category- and style-specific instructions plus technical constraints (static site, IPFS hosting, responsive design) are added automatically.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color:
                              theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _showPromptPreview,
                      icon: const Icon(LucideIcons.eye, size: 18),
                      tooltip: 'Preview full prompt',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildTrackingToggle(theme),
              ],
            ),
          ),
          _buildFooter(nameEmpty: nameEmpty),
        ],
      ),
    );
  }

  Widget _buildTrackingToggle(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.barChart3,
            size: 18,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    'Enable click tracking',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 10),
                  child: Text(
                    'Adds a privacy-friendly script (no cookies, no PII) so '
                    'you can see view and visitor counts next to this '
                    'generation. Off by default.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: _enableTracking,
            onChanged: (v) => setState(() => _enableTracking = v),
          ),
        ],
      ),
    );
  }

  Widget _buildStyleHeader(ThemeData theme) {
    final secondary = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final tertiary = theme.colorScheme.onSurface.withValues(alpha: 0.5);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          'Style ',
          style: theme.textTheme.labelMedium?.copyWith(color: secondary),
        ),
        Text(
          '· pick one',
          style: theme.textTheme.labelMedium?.copyWith(color: tertiary),
        ),
      ],
    );
  }

  Widget _buildStyleCardsRow() {
    return SizedBox(
      height: 156,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: _styleOptions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final option = _styleOptions[i];
          final selected = _selectedStyle == option.label;
          return _StyleCard(
            option: option,
            selected: selected,
            onTap: () => setState(() => _selectedStyle = option.label),
          );
        },
      ),
    );
  }

  Widget _buildPaletteHeader(ThemeData theme) {
    final secondary = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    final tertiary = theme.colorScheme.onSurface.withValues(alpha: 0.5);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          'Color palette ',
          style: theme.textTheme.labelMedium?.copyWith(color: secondary),
        ),
        Text(
          '· pick one',
          style: theme.textTheme.labelMedium?.copyWith(color: tertiary),
        ),
      ],
    );
  }

  Widget _buildPaletteCardsRow() {
    return SizedBox(
      height: 156,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: _paletteOptions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final option = _paletteOptions[i];
          final selected = _palette == option.label;
          return _PaletteCard(
            option: option,
            selected: selected,
            onTap: () => setState(() => _palette = option.label),
          );
        },
      ),
    );
  }

  Widget _buildFooter({required bool nameEmpty}) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: nameEmpty ? null : _submit,
              icon: const Icon(LucideIcons.sparkles, size: 18),
              label: const Text('Publish'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StyleCard extends StatelessWidget {
  final _StyleOption option;
  final bool selected;
  final VoidCallback onTap;

  const _StyleCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = selected
        ? AppColors.primary
        : theme.colorScheme.outlineVariant;
    final fillColor = selected
        ? AppColors.primary.withValues(alpha: 0.12)
        : theme.colorScheme.surfaceContainerHighest;
    final labelColor = selected
        ? AppColors.primary
        : theme.colorScheme.onSurface;

    return Material(
      color: fillColor,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 140,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor, width: selected ? 1.5 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(9),
                ),
                child: SizedBox(
                  height: 78,
                  child: Stack(
                    children: [
                      _StyleSwatch(option: option),
                      if (selected)
                        const Positioned(
                          top: 6,
                          right: 6,
                          child: _SelectedBadge(),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: labelColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      option.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        height: 1.3,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.6),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StyleSwatch extends StatelessWidget {
  final _StyleOption option;
  const _StyleSwatch({required this.option});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: option.bg,
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 4,
                decoration: BoxDecoration(
                  color: option.fg.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              const SizedBox(width: 4),
              Container(
                width: 12,
                height: 4,
                decoration: BoxDecoration(
                  color: option.accent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FractionallySizedBox(
                widthFactor: 0.9,
                child: Container(
                  height: option.titleH,
                  decoration: BoxDecoration(
                    color: option.fg,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              FractionallySizedBox(
                widthFactor: 0.6,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: option.fg.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              FractionallySizedBox(
                widthFactor: 0.7,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: option.fg.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SelectedBadge extends StatelessWidget {
  const _SelectedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: const BoxDecoration(
        color: AppColors.primary,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: const Icon(LucideIcons.check, size: 14, color: Colors.white),
    );
  }
}

/// Single-select card mirroring [_StyleCard] but showing the palette's colors
/// as four equal vertical bands instead of a mock layout swatch.
class _PaletteCard extends StatelessWidget {
  final _PaletteOption option;
  final bool selected;
  final VoidCallback onTap;

  const _PaletteCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = selected
        ? AppColors.primary
        : theme.colorScheme.outlineVariant;
    final fillColor = selected
        ? AppColors.primary.withValues(alpha: 0.12)
        : theme.colorScheme.surfaceContainerHighest;
    final labelColor =
        selected ? AppColors.primary : theme.colorScheme.onSurface;

    return Material(
      color: fillColor,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 140,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor, width: selected ? 1.5 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(9),
                ),
                child: SizedBox(
                  height: 78,
                  child: Stack(
                    children: [
                      _PaletteSwatch(colors: option.colors),
                      if (selected)
                        const Positioned(
                          top: 6,
                          right: 6,
                          child: _SelectedBadge(),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: labelColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      option.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        height: 1.3,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.6),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaletteSwatch extends StatelessWidget {
  final List<Color> colors;
  const _PaletteSwatch({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final c in colors)
          Expanded(child: ColoredBox(color: c, child: const SizedBox.expand())),
      ],
    );
  }
}
