import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/core/models/nft_token.dart';
import 'package:fula_files/web/services/web_nft_status_logic.dart';

/// Unit tests for the pure web NFT status-display logic (a1), mirroring native
/// nft_card.dart. The card widget (colors/icons/Image.network) is browser-only
/// and verified live; these transitions are the VM-safe core.
void main() {
  final now = DateTime(2026, 6, 14, 12, 0, 0);

  NftClaimRecord claim(
    NftClaimStatus status, {
    DateTime? expiresAt,
    String? linkHash,
    String? claimerAddress,
  }) =>
      NftClaimRecord(
        id: 'c-${status.index}-${expiresAt?.millisecondsSinceEpoch ?? 0}',
        tokenId: 1,
        chainId: 8453,
        createdAt: now,
        expiresAt: expiresAt ?? now.add(const Duration(days: 7)),
        status: status,
        linkHash: linkHash,
        claimerAddress: claimerAddress,
      );

  NftMintRecord mint(List<NftClaimRecord> claims,
          {int count = 5, int creatorBurned = 0}) =>
      NftMintRecord(
        id: 'm1',
        ipfsCid: 'cid',
        count: count,
        fulaPerNft: '10',
        chainId: 8453,
        creatorAddress: '0xcreator',
        mintedAt: now,
        status: NftMintStatus.completed,
        claims: claims,
        creatorBurned: creatorBurned,
      );

  group('copyCounts', () {
    test('mixed claims + creatorBurned, expired returns to creator', () {
      final m = mint(
        [
          claim(NftClaimStatus.claimed),
          claim(NftClaimStatus.pending,
              expiresAt: now.add(const Duration(days: 2)), linkHash: '0xabc'),
          claim(NftClaimStatus.pending,
              expiresAt: now.subtract(const Duration(days: 1))), // expired
          claim(NftClaimStatus.burned),
        ],
        count: 5,
        creatorBurned: 1,
      );
      final c = copyCounts(m, now);
      expect(c.claimed, 1);
      expect(c.linkGenerated, 1); // the expired pending is NOT counted
      expect(c.burned, 2); // 1 claim-burned + 1 creatorBurned
      expect(c.held, 1); // 5 - 1 - 1 - 2
    });

    test('no claims → all copies held', () {
      final c = copyCounts(mint(const [], count: 3), now);
      expect(c.held, 3);
      expect(c.linkGenerated, 0);
      expect(c.claimed, 0);
      expect(c.burned, 0);
    });
  });

  group('claimKind', () {
    test('pending in the future is pending', () {
      expect(
          claimKind(
              claim(NftClaimStatus.pending,
                  expiresAt: now.add(const Duration(hours: 1))),
              now),
          NftClaimKind.pending);
    });
    test('pending past expiry is expired', () {
      expect(
          claimKind(
              claim(NftClaimStatus.pending,
                  expiresAt: now.subtract(const Duration(hours: 1))),
              now),
          NftClaimKind.expired);
    });
    test('claimed / burned / expired pass through', () {
      expect(claimKind(claim(NftClaimStatus.claimed), now),
          NftClaimKind.claimed);
      expect(
          claimKind(claim(NftClaimStatus.burned), now), NftClaimKind.burned);
      expect(claimKind(claim(NftClaimStatus.expired), now),
          NftClaimKind.expired);
    });
  });

  group('claimIsActionable', () {
    test('pending + future + linkHash is actionable', () {
      expect(
          claimIsActionable(
              claim(NftClaimStatus.pending,
                  expiresAt: now.add(const Duration(days: 1)),
                  linkHash: '0xabc'),
              now),
          isTrue);
    });
    test('not actionable when expired, claimed, or missing linkHash', () {
      expect(
          claimIsActionable(
              claim(NftClaimStatus.pending,
                  expiresAt: now.subtract(const Duration(days: 1)),
                  linkHash: '0xabc'),
              now),
          isFalse);
      expect(claimIsActionable(claim(NftClaimStatus.claimed), now), isFalse);
      expect(
          claimIsActionable(
              claim(NftClaimStatus.pending,
                  expiresAt: now.add(const Duration(days: 1))),
              now),
          isFalse); // no linkHash
    });
  });

  group('formatExpiry', () {
    test('days / hours / minutes / soon', () {
      expect(formatExpiry(now.add(const Duration(days: 2)), now), '2d');
      expect(formatExpiry(now.add(const Duration(hours: 3)), now), '3h');
      expect(formatExpiry(now.add(const Duration(minutes: 5)), now), '5m');
      expect(formatExpiry(now.subtract(const Duration(minutes: 1)), now),
          'soon');
    });
  });

  group('truncateAddress', () {
    test('middle-truncates long addresses', () {
      expect(truncateAddress('0x1234567890abcdef'), '0x1234...cdef');
    });
    test('leaves short strings unchanged', () {
      expect(truncateAddress('0x1234'), '0x1234');
    });
  });
}
