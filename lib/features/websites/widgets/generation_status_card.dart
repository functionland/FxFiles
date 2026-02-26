import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fula_files/core/models/website_generation.dart';

/// Card showing the status of a website generation job
class GenerationStatusCard extends StatelessWidget {
  final WebsiteGeneration generation;
  final VoidCallback? onRetry;

  const GenerationStatusCard({
    super.key,
    required this.generation,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            const SizedBox(height: 8),
            _buildPromptPreview(context),
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

  Widget _buildPromptPreview(BuildContext context) {
    return Text(
      generation.prompt,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.grey[600],
          ),
    );
  }

  Widget _buildProgress(BuildContext context) {
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
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: const LinearProgressIndicator(),
    );
  }

  Widget _buildCompletedSection(BuildContext context) {
    // M3: Use gatewayUrl getter which prefers resultGatewayUrl over resultCid
    final url = generation.gatewayUrl;
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
                  onPressed: () => _copyUrl(context, url),
                  icon: const Icon(LucideIcons.copy, size: 16),
                  label: const Text('Copy URL'),
                ),
              ),
            ],
          ),
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
              generation.errorMessage ?? 'An unknown error occurred',
              style: const TextStyle(fontSize: 12, color: Colors.red),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onRetry,
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
      _formatDate(generation.createdAt),
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

  void _copyUrl(BuildContext context, String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('URL copied to clipboard')),
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
