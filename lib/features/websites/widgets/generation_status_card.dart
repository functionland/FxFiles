import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fula_files/core/models/website_generation.dart';

/// Card showing the status of a website generation job
class GenerationStatusCard extends StatefulWidget {
  final WebsiteGeneration generation;
  final VoidCallback? onRetry;
  final VoidCallback? onRecreate;

  const GenerationStatusCard({
    super.key,
    required this.generation,
    this.onRetry,
    this.onRecreate,
  });

  @override
  State<GenerationStatusCard> createState() => _GenerationStatusCardState();
}

class _GenerationStatusCardState extends State<GenerationStatusCard> {
  bool _promptExpanded = false;

  @override
  Widget build(BuildContext context) {
    final generation = widget.generation;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            const SizedBox(height: 8),
            _buildPromptSection(context),
            if (generation.status == WebsiteGenStatus.uploading ||
                generation.status == WebsiteGenStatus.parsing ||
                generation.status == WebsiteGenStatus.generating)
              _buildProgress(context),
            if (generation.status == WebsiteGenStatus.completed)
              _buildCompletedSection(context),
            if (generation.status == WebsiteGenStatus.error)
              _buildErrorSection(context),
            const SizedBox(height: 4),
            _buildTimestamp(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final generation = widget.generation;
    final (icon, color, label) = switch (generation.status) {
      WebsiteGenStatus.uploading => (LucideIcons.upload, Colors.blue, 'Uploading'),
      WebsiteGenStatus.parsing => (LucideIcons.scan, Colors.orange, 'Parsing'),
      WebsiteGenStatus.generating => (LucideIcons.sparkles, Colors.purple, 'Generating'),
      WebsiteGenStatus.completed => (LucideIcons.checkCircle, Colors.green, 'Completed'),
      WebsiteGenStatus.error => (LucideIcons.alertCircle, Colors.red, 'Error'),
    };

    final isActive = generation.status == WebsiteGenStatus.uploading ||
        generation.status == WebsiteGenStatus.parsing ||
        generation.status == WebsiteGenStatus.generating;

    return Row(
      children: [
        if (isActive)
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          )
        else
          Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        if (generation.statusMessage != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              generation.statusMessage!,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPromptSection(BuildContext context) {
    final fullPrompt = widget.generation.prompt;
    final userPortion = extractUserPrompt(fullPrompt);
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Colors.grey[700],
        );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: InkWell(
            onTap: () => setState(() => _promptExpanded = !_promptExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                fullPrompt,
                maxLines: _promptExpanded ? null : 2,
                overflow: _promptExpanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copy prompt',
          icon: const Icon(LucideIcons.copy, size: 16),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: () => _copyText(
            context,
            userPortion,
            'Prompt copied to clipboard',
          ),
        ),
      ],
    );
  }

  Widget _buildProgress(BuildContext context) {
    final generation = widget.generation;
    if (generation.status == WebsiteGenStatus.uploading && generation.totalAssets > 0) {
      final progress = generation.uploadedAssets / generation.totalAssets;
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 4),
            Text(
              '${generation.uploadedAssets}/${generation.totalAssets} assets uploaded',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.only(top: 8),
      child: LinearProgressIndicator(),
    );
  }

  Widget _buildCompletedSection(BuildContext context) {
    // M3: Use gatewayUrl getter which prefers resultGatewayUrl over resultCid
    final url = widget.generation.gatewayUrl;
    if (url == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(LucideIcons.globe, size: 16, color: Colors.green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    url,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openUrl(context, url),
                  icon: const Icon(LucideIcons.externalLink, size: 16),
                  label: const Text('Open'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _copyText(
                    context,
                    url,
                    'URL copied to clipboard',
                  ),
                  icon: const Icon(LucideIcons.copy, size: 16),
                  label: const Text('Copy URL'),
                ),
              ),
            ],
          ),
          if (widget.onRecreate != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: widget.onRecreate,
                icon: const Icon(LucideIcons.refreshCw, size: 16),
                label: const Text('Recreate'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorSection(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              widget.generation.errorMessage ?? 'An unknown error occurred',
              style: const TextStyle(fontSize: 12, color: Colors.red),
            ),
          ),
          if (widget.onRetry != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: widget.onRetry,
              icon: const Icon(LucideIcons.refreshCw, size: 16),
              label: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTimestamp(BuildContext context) {
    return Text(
      _formatDate(widget.generation.createdAt),
      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
    );
  }

  void _openUrl(BuildContext context, String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open URL: $e')),
        );
      }
    }
  }

  void _copyText(BuildContext context, String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      if (diff.inHours == 0) {
        return '${diff.inMinutes}m ago';
      }
      return '${diff.inHours}h ago';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}

/// Strip the auto-prepended "Website Name: …\nCategory: …\n\n" prefix and
/// return only what the user typed. Falls back to the full string for older
/// records or unexpected formats.
String extractUserPrompt(String stored) {
  final parsed = parseStoredPrompt(stored);
  return parsed.userBody;
}

/// Parse a stored prompt back into its components. Tolerates older records
/// that lack the enriched prefix by returning empty name/category/styles/
/// palette and the original string as the user body. The `Styles:` and
/// `Palette:` lines are optional — `styles` returns an empty list and
/// `palette` returns an empty string when absent.
({
  String websiteName,
  String category,
  List<String> styles,
  String palette,
  String userBody,
}) parseStoredPrompt(String stored) {
  final namePattern = RegExp(r'^Website Name:\s*(.*)$', multiLine: true);
  final categoryPattern = RegExp(r'^Category:\s*(.*)$', multiLine: true);
  final stylesPattern = RegExp(r'^Styles:\s*(.*)$', multiLine: true);
  final palettePattern = RegExp(r'^Palette:\s*(.*)$', multiLine: true);

  final nameMatch = namePattern.firstMatch(stored);
  final categoryMatch = categoryPattern.firstMatch(stored);

  if (nameMatch == null || categoryMatch == null) {
    return (
      websiteName: '',
      category: '',
      styles: const <String>[],
      palette: '',
      userBody: stored.trim(),
    );
  }

  final stylesMatch = stylesPattern.firstMatch(stored);
  final styles = <String>[];
  if (stylesMatch != null) {
    final raw = stylesMatch.group(1)?.trim() ?? '';
    if (raw.isNotEmpty) {
      styles.addAll(
        raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
      );
    }
  }

  final paletteMatch = palettePattern.firstMatch(stored);
  final palette = paletteMatch?.group(1)?.trim() ?? '';

  // User body is everything after the first blank line.
  final blankLineIdx = stored.indexOf('\n\n');
  final body = blankLineIdx >= 0
      ? stored.substring(blankLineIdx + 2).trim()
      : '';

  return (
    websiteName: nameMatch.group(1)?.trim() ?? '',
    category: categoryMatch.group(1)?.trim() ?? '',
    styles: styles,
    palette: palette,
    userBody: body,
  );
}
