/// Pure status-display logic for the web NFT minted-card (a1), mirroring the
/// native `nft_card.dart` (`_CopyBreakdown` + `_heldCount` + `_ClaimRow`).
/// Dependency-free (no Flutter) so it is VM unit-testable; the widget layer
/// maps these to colors/icons.
library;

import 'package:fula_files/core/models/nft_token.dart';

enum NftClaimKind { pending, expired, claimed, burned }

/// Per-copy breakdown of a minted record.
class NftCopyCounts {
  final int held;
  final int linkGenerated;
  final int claimed;
  final int burned;
  const NftCopyCounts({
    required this.held,
    required this.linkGenerated,
    required this.claimed,
    required this.burned,
  });
}

/// Compute the per-copy breakdown, mirroring native exactly:
/// expired claims return to the creator (don't consume a copy); `creatorBurned`
/// adds to burned; held = count − linkGenerated − claimed − burned.
NftCopyCounts copyCounts(NftMintRecord m, DateTime now) {
  var pendingLinks = 0;
  var claimed = 0;
  var burned = 0;
  for (final c in m.claims) {
    if (c.status == NftClaimStatus.claimed) {
      claimed++;
    } else if (c.status == NftClaimStatus.burned) {
      burned++;
    } else if (c.status == NftClaimStatus.pending &&
        !c.expiresAt.isBefore(now)) {
      pendingLinks++;
    }
    // expired (or pending-but-past-expiry) claims return to the creator.
  }
  final totalBurned = burned + m.creatorBurned;
  final held = m.count - pendingLinks - claimed - totalBurned;
  return NftCopyCounts(
    held: held,
    linkGenerated: pendingLinks,
    claimed: claimed,
    burned: totalBurned,
  );
}

/// The display status of a single claim, mirroring native `_ClaimRow`:
/// a pending claim past its expiry shows as expired.
NftClaimKind claimKind(NftClaimRecord c, DateTime now) {
  final expired = c.status == NftClaimStatus.expired ||
      (c.status == NftClaimStatus.pending && c.expiresAt.isBefore(now));
  return switch (c.status) {
    NftClaimStatus.pending when expired => NftClaimKind.expired,
    NftClaimStatus.pending => NftClaimKind.pending,
    NftClaimStatus.claimed => NftClaimKind.claimed,
    NftClaimStatus.expired => NftClaimKind.expired,
    NftClaimStatus.burned => NftClaimKind.burned,
  };
}

String claimKindLabel(NftClaimKind k) => switch (k) {
      NftClaimKind.pending => 'Pending',
      NftClaimKind.expired => 'Expired',
      NftClaimKind.claimed => 'Claimed',
      NftClaimKind.burned => 'Burned',
    };

/// Whether a claim still offers the Copy-Link action (pending, not expired,
/// has a secret) — mirrors native `showActions`.
bool claimIsActionable(NftClaimRecord c, DateTime now) =>
    c.status == NftClaimStatus.pending &&
    !c.expiresAt.isBefore(now) &&
    (c.linkHash != null && c.linkHash!.isNotEmpty);

/// Short remaining-time string, mirroring native `_formatDate`.
String formatExpiry(DateTime expiresAt, DateTime now) {
  final d = expiresAt.difference(now);
  if (d.inDays > 0) return '${d.inDays}d';
  if (d.inHours > 0) return '${d.inHours}h';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return 'soon';
}

/// Middle-truncate an address, mirroring native `_truncateAddress`.
String truncateAddress(String addr) {
  if (addr.length <= 10) return addr;
  return '${addr.substring(0, 6)}...${addr.substring(addr.length - 4)}';
}
