# NFT Feature Implementation Plan

## Phase 1: Foundation - COMPLETE

All files created and wired. See git diff for details.

**New files (14):**
- `lib/core/models/nft_token.dart` + `.g.dart` (Hive type IDs 30-34)
- `lib/core/services/nft_service.dart`, `nft_wallet_service.dart`, `nft_contract_service.dart`
- `lib/features/nft/providers/nft_provider.dart`
- `lib/features/nft/screens/` (4 screens)
- `lib/features/nft/widgets/` (4 widgets)

**Modified files (8):**
- `supported_chain.dart` — added `nftContractAddress`
- `secure_storage_service.dart` — added `nftWalletPrivateKey`
- `deep_link_service.dart` — `fxfiles://nft-claim` handler
- `app.dart` — NFT claim deep link subscription
- `router.dart` — 4 new routes
- `featured_section.dart` — NFTs card
- `home_screen.dart` — `isNftEnabled` pass-through
- `main.dart` — `NftService.instance.init()`

---

## Phase 2: Smart Contract + Minting - COMPLETE

### Smart Contract (`/mnt/e/GitHub/fula-chain`)
- `contracts/core/FulaFileNFT.sol` — ERC1155 + GovernanceModule, FULA locking, claim escrow
- `contracts/governance/interfaces/IFulaFileNFT.sol` — Events + errors interface
- `scripts/deployFulaFileNFT.ts` — UUPS proxy deployment
- `test/governance/integration/FulaFileNFT.test.ts` — 25 tests, all passing

### Flutter Changes
- `nft_token.dart` + `.g.dart` — Added `@HiveField(13) approvalTxHash`
- `supported_chain.dart` — Zero address placeholder for both chains (replace after deployment)
- `nft_contract_service.dart` — All 7 selectors filled (`e90284f4`, `49db23ce`, `fbcb5ae7`, `76ee030a`, `8c7a63ae`, `695aaae9`, `74abfa54`), added `pollForReceipt()` + `parseTokenIdFromReceipt()`
- `wallet_service.dart` — Added `sendContractTransaction()` generic method
- `nft_service.dart` — Implemented `startMint()` full flow (upload → approve → mint → poll → parse)
- `nft_provider.dart` — Added `startMint()` notifier wrapper
- `nft_detail_screen.dart` — Enabled mint button with spinner + wired share button on NftCard

### Remaining after contract deployment
- Replace `0x000...000` in `SupportedChain` with real proxy addresses

---

## Phase 3: Claim Links - COMPLETE (connected wallet flow)

### Implemented
- `nft_contract_service.dart` — Added `parseClaimOfferHash()` and `decodeTokenInfo()` for reading contract state
- `nft_service.dart` — Added `createClaimOffer()` (send tx → parse linkHash → build deep link → save NftClaimRecord), `claimNft()` (send claimNFT tx → poll receipt), `fetchTokenInfo()` (eth_call → decode)
- `nft_provider.dart` — Added `createClaimOffer()` and `claimNft()` notifier methods
- `nft_detail_screen.dart` — Share button opens claimer address dialog → creates on-chain offer → shows share sheet with link
- `nft_claim_screen.dart` — Fetches token info on load (image, creator, FULA, supply), enables claim button for connected wallets

### Deferred to Phase 5
- `NftWalletService.signTransaction()` — Full secp256k1 signing for derived wallets (requires RLP encoding + keccak256 + secp256k1). Currently only Reown AppKit wallets can mint/claim.

---

## Phase 4: Transfer-Back + QR - COMPLETE

### Implemented
- `pubspec.yaml` — Added `qr_flutter: ^4.1.0` and `mobile_scanner: ^6.0.0`
- `transfer_back_qr_dialog.dart` — Replaced placeholder with `QrImageView`, JSON payload `{chain, token, amount, claimer, nonce}`, detail summary below QR
- `nft_qr_scanner_screen.dart` — Replaced placeholder with `MobileScanner` widget, parses JSON payload, fetches token info for FULA display, shows confirmation dialog with transfer-back details, flashlight + camera switch controls
- `nft_service.dart` — Added `transferBack()` flow (encodeTransferBack → sendContractTransaction → pollForReceipt) + `markClaimReturned()` to update claim status
- `nft_provider.dart` — Added `transferBack()` notifier wrapper
- `nft_claim_screen.dart` — After claiming: shows "Transfer Back" button (calls contract directly) + QR code button (shows QR for sender verification), transfer-back success state
- `nft_detail_screen.dart` — Added QR scan button in app bar (navigates to `/nft-qr-scan`)

### Deferred to Phase 5
- QR payload signature (secp256k1 signing) — requires `NftWalletService.signTransaction()` which is deferred

---

## Phase 5: Polish - COMPLETE

### Implemented

1. **Error handling**
   - `nft_service.dart` — FULA balance check before approve in `startMint()` with specific "Required vs Available" message
   - `nft_service.dart` — Expired claim check via `_fetchClaimOffer()` + `decodeClaimOffer()` before attempting claim
   - `nft_service.dart` — Already-claimed detection from contract revert messages
   - `nft_service.dart` — Not-claim-recipient error handling
   - `nft_service.dart` — Reverted transaction detection with user-friendly messages
   - `nft_contract_service.dart` — Added `decodeClaimOffer()` for on-chain expiry/claimed status checks

2. **Chain switching**
   - `nft_service.dart` — Added `_ensureCorrectChain()` helper using `WalletService.switchChain()`
   - Called before `startMint()`, `claimNft()`, `transferBack()`, and `retryMint()`

3. **Block explorer links**
   - `nft_card.dart` — "View on Explorer" link for completed mints using `SupportedChain.getTxExplorerUrl()`
   - `nft_claim_screen.dart` — Clickable explorer links for claim tx and transfer-back tx hashes

4. **Cloud sync for NFT collections**
   - `nft_service.dart` — Added `restoreFromCloud()` following WebsiteService pattern (guard checks, preserve in-progress mints, merge by tagId, silent on NoSuchKey)
   - `auth_service.dart` — Added `NftService.instance.restoreFromCloud()` at all 4 auth completion points (auto-login, Google, Apple, reinitialize)

5. **Loading states and status indicators**
   - `nft_card.dart` — Animated pulsing status badge with spinner for in-progress operations (approving/minting/confirming)
   - `nfts_browser_screen.dart` — Shimmer skeleton loading while tags initialize
   - `nft_detail_screen.dart` — Status message display below mint button showing current step (with spinner)

6. **Retry logic for failed operations**
   - `nft_service.dart` — Added `retryMint()` that resumes from last successful step (skips upload if CID exists, skips approval if tx exists, re-polls mint tx)
   - `nft_provider.dart` — Added `retryMint()` notifier wrapper
   - `nft_card.dart` — Retry button (refresh icon) on error-state cards
   - `nft_detail_screen.dart` — Wired `onRetry` callback to `_retryMint()` method
   - `nft_claim_screen.dart` — Retry button for failed claim attempts

### Remaining (requires deployed contract)
- Replace `0x000...000` in `SupportedChain` with real proxy addresses

---

## Phase 6: Design Overhaul - COMPLETE

Three fundamental design changes applied:

### Change 3: Burn-to-Release Model
- **Contract**: Removed `transferBack()`. Added `burn()` and `burnBatch()` overrides that release locked FULA via `storageToken.safeTransfer()`. Standard ERC1155 transfers (safeTransferFrom) preserved — FULA stays locked on transfer, only released on burn.
- **Flutter**: Renamed `returnedBack` → `burned`, removed QR scanner/transfer-back dialog, added burn button with confirmation dialog, added transfer button with address input.
- **Deleted**: `transfer_back_qr_dialog.dart`, `nft_qr_scanner_screen.dart`

### Change 1: Open Claim Links
- **Contract**: `createClaimOffer()` allows `claimer = address(0)` for open claims. `claimNFT()` skips claimer check when offer has zero-address claimer.
- **Flutter**: "Anyone can claim" toggle (default ON) in claim sheet. Open claims skip address input.
- **Tests**: 43 tests passing (added open claim + burn tests, removed transferBack + zero-claimer-revert tests).

### Change 2: Internal Wallet
- **NftWalletService**: Fixed base64 decode bug, uses web3dart `EthPrivateKey` for proper secp256k1 derivation, added `sendSignedTransaction()` and `sendApproveTransaction()`.
- **WalletSource dispatch**: `enum WalletSource { internal, external }` — all service methods dispatch to either `NftWalletService` or `WalletService`.
- **Wallet Picker UI**: Dialog shown before every NFT operation (mint, claim, burn, transfer). Auto-selects if only one wallet available.
- **Settings**: NFT Wallet section shows internal wallet address with copy button.

---

## Smart Contract Reference

```solidity
// SPDX-License-Identifier: MIT
// ERC1155 deployed identically on Base (8453) and Skale Europa (2046399126)

// Minting - caller must approve() FULA spend first
mintWithFula(string ipfsCid, uint256 fulaPerNft, uint256 count) -> uint256 firstTokenId

// Claiming - sender creates offer, recipient claims
createClaimOffer(uint256 tokenId, address claimer, uint256 expiresAt) -> bytes32 linkHash
// claimer = address(0) → open claim (anyone), claimer = 0x1234... → targeted
claimNFT(bytes32 linkHash)

// Burn - permanently destroys NFT, releases locked FULA to burner
burn(address account, uint256 id, uint256 value)
burnBatch(address account, uint256[] ids, uint256[] values)

// Transfer - standard ERC1155, FULA stays locked
safeTransferFrom(from, to, id, amount, data)  // inherited

// Cancel - sender (after expiry) or admin can cancel stuck offers
cancelClaimOffer(bytes32 linkHash)

// Read functions
getTokenInfo(uint256 tokenId) -> (creator, ipfsCid, fulaAmount, totalSupply)
getClaimOffer(bytes32 linkHash) -> (tokenId, sender, claimer, expiresAt, claimed)
getCreatorTokens(address) -> uint256[]
```

## Deterministic Wallet Derivation

```
encryptionKey = Argon2id("{provider}:{userId}:{email}", "fula-files-v1") -> 32 bytes (existing)
nftPrivateKey = HMAC-SHA256("nft-wallet", base64Decode(encryptionKey)) -> 32 bytes
nftAddress    = EthPrivateKey(nftPrivateKey).address.eip55With0x -> "0x..." (via web3dart + wallet)
```

Uses web3dart for proper secp256k1 public key derivation and keccak256 address computation.

## Deep Link Format

```
fxfiles://nft-claim?chain=8453&contract=0x...&token=123&hash=0xabc...
```
