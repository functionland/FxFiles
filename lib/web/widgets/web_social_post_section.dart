import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fula_files/core/models/social_post_record.dart';
import 'package:fula_files/web/services/web_save.dart';
import 'package:fula_files/web/services/web_social_post_service.dart';
import 'package:fula_files/web/widgets/web_buffer_post_dialog.dart';

/// Per-generation "Generated Social Media" block, rendered inside the
/// generation card's completed section (below the analytics row). Shows a
/// status row while the job runs, an expandable result (4:5 image +
/// captions with copy/download) when complete, and an error block with
/// retry. Self-listens on [WebSocialPostService] like the analytics row
/// self-fetches.
class WebSocialPostSection extends StatefulWidget {
  final String generationId;
  final String tagName;
  final VoidCallback? onCreateSocial;
  const WebSocialPostSection({
    super.key,
    required this.generationId,
    required this.tagName,
    this.onCreateSocial,
  });

  @override
  State<WebSocialPostSection> createState() => _WebSocialPostSectionState();
}

class _WebSocialPostSectionState extends State<WebSocialPostSection> {
  bool _expanded = true;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    WebSocialPostService.instance.addListener(_onTick);
  }

  @override
  void dispose() {
    WebSocialPostService.instance.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _copy(String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$label copied to clipboard')));
  }

  /// Fetch the public image bytes and hand them to the browser as a
  /// download; if the gateway blocks the cross-origin read, fall back to
  /// opening the image in a new tab.
  Future<void> _download(SocialPostRecord record) async {
    final url = record.resolvedImageUrl;
    if (url == null) return;
    setState(() => _downloading = true);
    try {
      final response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final safeName =
          widget.tagName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      saveBytesAsDownload('social-$safeName.jpg', response.bodyBytes,
          mimeType: 'image/jpeg');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Direct download blocked — opening the image in a new tab')));
      await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _postToSocial(SocialPostRecord record) async {
    final captions = record.captions;
    final imageUrl = record.imageUrl ?? record.resolvedImageUrl;
    if (captions == null || imageUrl == null) return;
    final hasKey = await WebSocialPostService.instance.hasBufferKey();
    if (!mounted) return;
    if (!hasKey) {
      final goSetup = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Connect Buffer'),
          content: const Text(
              'Posting goes through Buffer. Add your Buffer API key in '
              'Settings → Integrations → Buffer first.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Open Settings')),
          ],
        ),
      );
      if (goSetup == true && mounted) context.go('/settings/buffer');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) =>
          WebBufferPostDialog(captions: captions, imageUrl: imageUrl),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record =
        WebSocialPostService.instance.recordFor(widget.generationId);
    if (record == null) return const SizedBox.shrink();

    if (record.status.isRunning) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                record.statusMessage ?? 'Creating social post…',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    if (record.status == SocialPostStatus.error) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(LucideIcons.alertCircle, size: 14, color: Colors.red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Social post failed: ${record.errorMessage ?? 'unknown error'}',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: Colors.red),
              ),
            ),
            if (widget.onCreateSocial != null)
              TextButton(
                onPressed: widget.onCreateSocial,
                child: const Text('Try again'),
              ),
          ],
        ),
      );
    }

    // Completed
    final captions = record.captions;
    final imageUrl = record.resolvedImageUrl;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  const Icon(LucideIcons.megaphone, size: 16),
                  const SizedBox(width: 8),
                  Text('Generated Social Media',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Icon(
                      _expanded
                          ? LucideIcons.chevronUp
                          : LucideIcons.chevronDown,
                      size: 16),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (imageUrl != null) ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: AspectRatio(
                          aspectRatio: 4 / 5,
                          child: Image.network(
                            imageUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: const Center(
                                  child: Icon(LucideIcons.imageOff)),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      icon: _downloading
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(LucideIcons.download, size: 14),
                      label: const Text('Download image'),
                      onPressed:
                          _downloading ? null : () => _download(record),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (captions != null) ...[
                    _CaptionBlock(
                      label: 'Instagram / Facebook caption',
                      text: captions.long,
                      onCopy: () => _copy(captions.long, 'Caption'),
                    ),
                    const SizedBox(height: 10),
                    _CaptionBlock(
                      label: 'X caption',
                      text: captions.short,
                      onCopy: () => _copy(captions.short, 'Caption'),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        icon: const Icon(LucideIcons.send, size: 14),
                        label: const Text('Post to social media'),
                        onPressed: () => _postToSocial(record),
                      ),
                      if (widget.onCreateSocial != null)
                        OutlinedButton.icon(
                          icon: const Icon(LucideIcons.refreshCw, size: 14),
                          label: const Text('Recreate social posts'),
                          onPressed: widget.onCreateSocial,
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Caption text with an expand-on-tap body (house maxLines idiom) and a
/// copy button.
class _CaptionBlock extends StatefulWidget {
  final String label;
  final String text;
  final VoidCallback onCopy;
  const _CaptionBlock(
      {required this.label, required this.text, required this.onCopy});

  @override
  State<_CaptionBlock> createState() => _CaptionBlockState();
}

class _CaptionBlockState extends State<_CaptionBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(widget.label,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            IconButton(
              tooltip: 'Copy caption',
              icon: const Icon(LucideIcons.copy, size: 14),
              visualDensity: VisualDensity.compact,
              onPressed: widget.onCopy,
            ),
          ],
        ),
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Text(
            widget.text,
            maxLines: _expanded ? null : 3,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
