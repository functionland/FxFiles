import 'package:flutter_test/flutter_test.dart';

import 'package:fula_files/web/services/web_nft_gas_logic.dart';

/// Unit tests for the pure NFT-share gas-sponsorship logic (s5). The
/// eth_gasPrice RPC probe (web_nft_service.estimateGasDeposit) and the
/// payable wallet send are browser/wallet-only and verified live; this is
/// the VM-safe core, mirroring native's gasPrice*300000 formula.
void main() {
  group('sponsorGasSupported', () {
    test('only Base (8453) supports sponsorship', () {
      expect(sponsorGasSupported(8453), isTrue);
    });
    test('other chains do not', () {
      expect(sponsorGasSupported(1), isFalse); // Ethereum mainnet
      expect(sponsorGasSupported(1351057110), isFalse); // SKALE
      expect(sponsorGasSupported(0), isFalse);
    });
  });

  group('gasDepositFor', () {
    test('multiplies gas price by the 300k-gas margin', () {
      final gwei = BigInt.from(1000000000); // 1 gwei
      expect(gasDepositFor(BigInt.from(2) * gwei),
          BigInt.from(2) * gwei * BigInt.from(300000));
    });

    test('falls back to 1 gwei when price is null', () {
      expect(gasDepositFor(null),
          BigInt.from(1000000000) * BigInt.from(300000));
    });

    test('falls back to 1 gwei when price is zero or negative', () {
      final fallback = BigInt.from(1000000000) * BigInt.from(300000);
      expect(gasDepositFor(BigInt.zero), fallback);
      expect(gasDepositFor(BigInt.from(-5)), fallback);
    });

    test('1 gwei fallback is ~0.0003 ETH (3e14 wei)', () {
      expect(gasDepositFor(null), BigInt.parse('300000000000000'));
    });

    test('scales linearly with gas price', () {
      final gwei = BigInt.from(1000000000);
      final lo = gasDepositFor(gwei);
      final hi = gasDepositFor(BigInt.from(10) * gwei);
      expect(hi, lo * BigInt.from(10));
    });
  });
}
