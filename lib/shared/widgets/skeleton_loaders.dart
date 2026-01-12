import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// Skeleton loader widgets for FxFiles
///
/// Provides consistent loading placeholders that match the actual UI components.

// ============================================================================
// BASE SKELETON WIDGET
// ============================================================================

/// Base shimmer wrapper for consistent animation across all skeletons
class SkeletonShimmer extends StatelessWidget {
  final Widget child;

  const SkeletonShimmer({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Shimmer.fromColors(
      baseColor: isDark
          ? Colors.grey.shade800
          : Colors.grey.shade300,
      highlightColor: isDark
          ? Colors.grey.shade700
          : Colors.grey.shade100,
      child: child,
    );
  }
}

/// Skeleton box with rounded corners
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double borderRadius;
  final bool isCircle;

  const SkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.borderRadius = 4,
    this.isCircle = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: isCircle ? height : width,
      height: height,
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
        borderRadius: isCircle
            ? null
            : BorderRadius.circular(borderRadius),
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
      ),
    );
  }
}

// ============================================================================
// FILE LIST ITEM SKELETON
// ============================================================================

/// Skeleton for file list items (used in file browser, trash, search)
class FileListItemSkeleton extends StatelessWidget {
  final bool showTrailing;

  const FileListItemSkeleton({
    super.key,
    this.showTrailing = true,
  });

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // File icon placeholder
            const SkeletonBox(width: 40, height: 40, borderRadius: 8),
            const SizedBox(width: 12),
            // File info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // File name
                  SkeletonBox(
                    width: MediaQuery.of(context).size.width * 0.5,
                    height: 14,
                  ),
                  const SizedBox(height: 6),
                  // File metadata (size, date)
                  const SkeletonBox(width: 120, height: 10),
                ],
              ),
            ),
            if (showTrailing) ...[
              const SizedBox(width: 8),
              // More options icon
              const SkeletonBox(width: 24, height: 24, borderRadius: 12),
            ],
          ],
        ),
      ),
    );
  }
}

/// List of file item skeletons
class FileListSkeleton extends StatelessWidget {
  final int itemCount;
  final bool showTrailing;

  const FileListSkeleton({
    super.key,
    this.itemCount = 5,
    this.showTrailing = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: itemCount,
      itemBuilder: (context, index) => FileListItemSkeleton(
        showTrailing: showTrailing,
      ),
    );
  }
}

// ============================================================================
// GRID ITEM SKELETONS
// ============================================================================

/// Skeleton for grid items (file grid view)
class FileGridItemSkeleton extends StatelessWidget {
  const FileGridItemSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Thumbnail placeholder
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // File name
          const SkeletonBox(width: 80, height: 12),
        ],
      ),
    );
  }
}

/// Grid of file skeletons
class FileGridSkeleton extends StatelessWidget {
  final int crossAxisCount;
  final int itemCount;

  const FileGridSkeleton({
    super.key,
    this.crossAxisCount = 3,
    this.itemCount = 9,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.85,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) => const FileGridItemSkeleton(),
    );
  }
}

// ============================================================================
// PERSON/AVATAR SKELETONS
// ============================================================================

/// Skeleton for person list items (face management, search people)
class PersonListItemSkeleton extends StatelessWidget {
  final double avatarSize;

  const PersonListItemSkeleton({
    super.key,
    this.avatarSize = 48,
  });

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Avatar placeholder
            SkeletonBox(height: avatarSize, isCircle: true),
            const SizedBox(width: 12),
            // Person info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name
                  SkeletonBox(
                    width: MediaQuery.of(context).size.width * 0.35,
                    height: 14,
                  ),
                  const SizedBox(height: 6),
                  // Face count or metadata
                  const SkeletonBox(width: 80, height: 10),
                ],
              ),
            ),
            // Action button
            const SkeletonBox(width: 32, height: 32, borderRadius: 16),
          ],
        ),
      ),
    );
  }
}

/// List of person skeletons
class PersonListSkeleton extends StatelessWidget {
  final int itemCount;
  final double avatarSize;

  const PersonListSkeleton({
    super.key,
    this.itemCount = 5,
    this.avatarSize = 48,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: itemCount,
      itemBuilder: (context, index) => PersonListItemSkeleton(
        avatarSize: avatarSize,
      ),
    );
  }
}

/// Skeleton for face/image grid (face management)
class FaceGridItemSkeleton extends StatelessWidget {
  const FaceGridItemSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}

/// Grid of face skeletons
class FaceGridSkeleton extends StatelessWidget {
  final int crossAxisCount;
  final int itemCount;

  const FaceGridSkeleton({
    super.key,
    this.crossAxisCount = 3,
    this.itemCount = 9,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) => const FaceGridItemSkeleton(),
    );
  }
}

// ============================================================================
// PLAYLIST/CARD SKELETONS
// ============================================================================

/// Skeleton for playlist card
class PlaylistCardSkeleton extends StatelessWidget {
  const PlaylistCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // Album art placeholder
            const SkeletonBox(width: 56, height: 56, borderRadius: 8),
            const SizedBox(width: 12),
            // Playlist info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Playlist name
                  SkeletonBox(
                    width: MediaQuery.of(context).size.width * 0.4,
                    height: 14,
                  ),
                  const SizedBox(height: 6),
                  // Song count
                  const SkeletonBox(width: 100, height: 10),
                ],
              ),
            ),
            // Action buttons
            const SkeletonBox(width: 32, height: 32, borderRadius: 16),
          ],
        ),
      ),
    );
  }
}

/// List of playlist skeletons
class PlaylistListSkeleton extends StatelessWidget {
  final int itemCount;

  const PlaylistListSkeleton({
    super.key,
    this.itemCount = 4,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: itemCount,
      itemBuilder: (context, index) => const PlaylistCardSkeleton(),
    );
  }
}

// ============================================================================
// SHARE CARD SKELETONS
// ============================================================================

/// Skeleton for share list items
class ShareCardSkeleton extends StatelessWidget {
  const ShareCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                // Icon placeholder
                const SkeletonBox(width: 40, height: 40, borderRadius: 8),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Path/name
                      SkeletonBox(
                        width: MediaQuery.of(context).size.width * 0.45,
                        height: 14,
                      ),
                      const SizedBox(height: 6),
                      // Recipient/info
                      const SkeletonBox(width: 120, height: 10),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Status chips row
            Row(
              children: [
                const SkeletonBox(width: 60, height: 24, borderRadius: 12),
                const SizedBox(width: 8),
                const SkeletonBox(width: 80, height: 24, borderRadius: 12),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// List of share skeletons
class ShareListSkeleton extends StatelessWidget {
  final int itemCount;

  const ShareListSkeleton({
    super.key,
    this.itemCount = 3,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: itemCount,
      itemBuilder: (context, index) => const ShareCardSkeleton(),
    );
  }
}

// ============================================================================
// BILLING/WALLET SKELETONS
// ============================================================================

/// Skeleton for credit stats card
class CreditStatsCardSkeleton extends StatelessWidget {
  const CreditStatsCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            const SkeletonBox(width: 100, height: 14),
            const SizedBox(height: 16),
            // Big number
            const SkeletonBox(width: 150, height: 36),
            const SizedBox(height: 12),
            // Subtitle
            const SkeletonBox(width: 200, height: 12),
          ],
        ),
      ),
    );
  }
}

/// Skeleton for wallet tile
class WalletTileSkeleton extends StatelessWidget {
  const WalletTileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Wallet icon
            const SkeletonBox(width: 40, height: 40, isCircle: true),
            const SizedBox(width: 12),
            // Wallet info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SkeletonBox(width: 120, height: 14),
                  const SizedBox(height: 6),
                  const SkeletonBox(width: 180, height: 10),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Skeleton for history/transaction tile
class HistoryTileSkeleton extends StatelessWidget {
  const HistoryTileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Type icon
            const SkeletonBox(width: 32, height: 32, borderRadius: 16),
            const SizedBox(width: 12),
            // Transaction info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SkeletonBox(width: 100, height: 14),
                  const SizedBox(height: 6),
                  const SkeletonBox(width: 150, height: 10),
                ],
              ),
            ),
            // Amount
            const SkeletonBox(width: 60, height: 14),
          ],
        ),
      ),
    );
  }
}

/// Full billing screen skeleton
class BillingScreenSkeleton extends StatelessWidget {
  const BillingScreenSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Credit stats
          const CreditStatsCardSkeleton(),
          // Wallets section header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SkeletonShimmer(
              child: const SkeletonBox(width: 80, height: 16),
            ),
          ),
          // Wallet tiles
          const WalletTileSkeleton(),
          const WalletTileSkeleton(),
          // History section header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SkeletonShimmer(
              child: const SkeletonBox(width: 120, height: 16),
            ),
          ),
          // History tiles
          const HistoryTileSkeleton(),
          const HistoryTileSkeleton(),
          const HistoryTileSkeleton(),
        ],
      ),
    );
  }
}

// ============================================================================
// HOME SCREEN SECTION SKELETONS
// ============================================================================

/// Skeleton for recent files section
class RecentFilesSectionSkeleton extends StatelessWidget {
  const RecentFilesSectionSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SkeletonShimmer(
            child: const SkeletonBox(width: 100, height: 18),
          ),
        ),
        // Horizontal list of recent files
        SizedBox(
          height: 100,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: 4,
            itemBuilder: (context, index) => SkeletonShimmer(
              child: Container(
                width: 80,
                margin: const EdgeInsets.only(right: 12),
                child: Column(
                  children: [
                    const SkeletonBox(width: 64, height: 64, borderRadius: 8),
                    const SizedBox(height: 8),
                    const SkeletonBox(width: 60, height: 10),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Skeleton for categories section
class CategoriesSectionSkeleton extends StatelessWidget {
  const CategoriesSectionSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SkeletonShimmer(
            child: const SkeletonBox(width: 80, height: 18),
          ),
        ),
        // Grid of categories
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SkeletonShimmer(
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: List.generate(
                4,
                (index) => const SkeletonBox(width: 80, height: 80, borderRadius: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Skeleton for storage section
class StorageSectionSkeleton extends StatelessWidget {
  const StorageSectionSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            const SkeletonBox(width: 80, height: 16),
            const SizedBox(height: 16),
            // Progress bar
            const SkeletonBox(height: 8, borderRadius: 4),
            const SizedBox(height: 12),
            // Storage info
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const SkeletonBox(width: 100, height: 12),
                const SkeletonBox(width: 60, height: 12),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// TRACK LIST SKELETON (for playlist details)
// ============================================================================

/// Skeleton for track list item
class TrackListItemSkeleton extends StatelessWidget {
  const TrackListItemSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Track number or drag handle
            const SkeletonBox(width: 24, height: 24, borderRadius: 4),
            const SizedBox(width: 12),
            // Track info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Track name
                  SkeletonBox(
                    width: MediaQuery.of(context).size.width * 0.5,
                    height: 14,
                  ),
                  const SizedBox(height: 4),
                  // Artist/duration
                  const SkeletonBox(width: 120, height: 10),
                ],
              ),
            ),
            // More button
            const SkeletonBox(width: 24, height: 24, borderRadius: 12),
          ],
        ),
      ),
    );
  }
}

/// List of track skeletons
class TrackListSkeleton extends StatelessWidget {
  final int itemCount;

  const TrackListSkeleton({
    super.key,
    this.itemCount = 6,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: itemCount,
      itemBuilder: (context, index) => const TrackListItemSkeleton(),
    );
  }
}

// ============================================================================
// FULA BROWSER SKELETON
// ============================================================================

/// Skeleton for Fula bucket list
class BucketListSkeleton extends StatelessWidget {
  final int itemCount;

  const BucketListSkeleton({
    super.key,
    this.itemCount = 3,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: itemCount,
      itemBuilder: (context, index) => SkeletonShimmer(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const SkeletonBox(width: 40, height: 40, borderRadius: 8),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SkeletonBox(width: 120, height: 14),
                    const SizedBox(height: 4),
                    const SkeletonBox(width: 80, height: 10),
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
