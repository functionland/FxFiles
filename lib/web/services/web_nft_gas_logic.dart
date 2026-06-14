/// Pure helpers for NFT-share gas sponsorship (s5), mirroring the native
/// `nft_detail_screen.dart` logic. Kept dependency-free so it is VM
/// unit-testable; the browser-only RPC probe + wallet send + UI live in
/// `web_nft_service.dart` / `web_nft_detail_screen.dart`.
library;

/// Sponsoring the recipient's claim gas is only offered on Base
/// (chainId 8453), matching native (which gates the toggle on
/// `mint.chainId == 8453`). Other chains pay their own claim gas.
bool sponsorGasSupported(int chainId) => chainId == 8453;

/// ETH (in wei) to escrow so the recipient can claim gas-free: a 300k-gas
/// margin (~2 transactions) at the current gas price, mirroring native
/// EXACTLY (`gasPrice * 300000`). Falls back to 1 gwei when the gas-price
/// probe is unavailable (~0.0003 ETH on Base).
///
/// The amount is an ESTIMATE — the real gas price at wallet-sign time can
/// differ, and a CORS-blocked browser probe silently uses the fallback — so
/// callers must present it as approximate, never as a precise figure.
BigInt gasDepositFor(BigInt? gasPriceWei) {
  final price = (gasPriceWei != null && gasPriceWei > BigInt.zero)
      ? gasPriceWei
      : BigInt.from(1000000000); // 1 gwei fallback
  return price * BigInt.from(300000);
}
