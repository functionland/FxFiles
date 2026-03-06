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

## Phase 2: Smart Contract + Minting (requires deployed contract)

### Prerequisites
- Deploy ERC1155 contract identically on Base (8453) and Skale Europa (2046399126)
- Contract must implement: `mintWithFula`, `createClaimOffer`, `claimNFT`, `transferBack`, `getTokenInfo`, `getClaimOffer`, `getCreatorTokens`
- Contract holds FULA tokens via `IERC20.transferFrom()` on mint

### Tasks

1. **Fill contract addresses in `SupportedChain`**
   - File: `lib/core/models/billing/supported_chain.dart`
   - Set `nftContractAddress` for both `base` and `skale` static instances

2. **Fill function selectors in `NftContractService`**
   - File: `lib/core/services/nft_contract_service.dart`
   - Replace all `'00000000'` placeholder selectors with actual `keccak256(signature)[:4]` values from deployed ABI:
     - `mintWithFula(string,uint256,uint256)`
     - `createClaimOffer(uint256,address,uint256)`
     - `claimNFT(bytes32)`
     - `transferBack(uint256,address,uint256)`
     - `getTokenInfo(uint256)`
     - `getClaimOffer(bytes32)`
     - `getCreatorTokens(address)`

3. **Implement IPFS upload in mint flow**
   - File: `lib/core/services/nft_service.dart`
   - Add `startMint()` method that:
     1. Uploads image to IPFS via `uploadNftAsset()` (already implemented)
     2. Creates `NftMintRecord` with status `approving`
     3. Calls approve + mint via Reown AppKit
     4. Polls `eth_getTransactionReceipt` every 3s
     5. Parses `tokenId` from logs
     6. Updates record status through `approving -> minting -> confirming -> completed`

4. **Wire approve + mint via Reown AppKit**
   - File: `lib/core/services/nft_service.dart`
   - Use `WalletService.instance` to send transactions:
     - Step 1: `approve(nftContractAddress, fulaPerNft * count)` on FULA token contract
     - Step 2: `mintWithFula(ipfsCid, fulaPerNftWei, count)` on NFT contract
   - Both via `eth_sendTransaction` through Reown AppKit session

5. **Transaction receipt polling**
   - File: `lib/core/services/nft_contract_service.dart`
   - `getTransactionReceipt()` already implemented
   - Add `pollForReceipt()` with 3s interval, max 5 min timeout
   - Parse `tokenId` from mint event logs (first topic after event signature)

6. **Enable Mint button in `NftDetailScreen`**
   - File: `lib/features/nft/screens/nft_detail_screen.dart`
   - Change `onPressed: null` to call `showMintConfigDialog()` then `startMint()`
   - Show progress via `NftMintStatus` updates

7. **Add `startMint()` to `NftNotifier`**
   - File: `lib/features/nft/providers/nft_provider.dart`
   - Add method that coordinates the mint flow, updates `isMinting` state

8. **Wire `NftCard` share button**
   - File: `lib/features/nft/widgets/nft_card.dart`
   - Connect `onShareClaim` callback in `NftDetailScreen`

---

## Phase 3: Claim Links

### Tasks

1. **Implement `createClaimOffer()` flow**
   - File: `lib/core/services/nft_service.dart`
   - Add method that:
     1. Calls `createClaimOffer(tokenId, claimerAddress, expiresAt)` via Reown AppKit
     2. Parses `linkHash` from tx receipt logs
     3. Builds link: `fxfiles://nft-claim?chain={chainId}&contract={addr}&token={tokenId}&hash={linkHash}`
     4. Saves `NftClaimRecord` locally (status: pending)

2. **Wire `ClaimLinkShareSheet`**
   - File: `lib/features/nft/widgets/claim_link_share_sheet.dart`
   - Already implemented UI; just needs to be called from `NftDetailScreen` after `createClaimOffer()` succeeds

3. **Implement `NftClaimScreen` token info fetch**
   - File: `lib/features/nft/screens/nft_claim_screen.dart`
   - On load: call `getTokenInfo(tokenId)` via `NftContractService.ethCall()`
   - Display: NFT image (from IPFS CID in token info), FULA amount, creator address
   - Enable "Claim" button

4. **Implement `claimNFT()` for connected wallets**
   - File: `lib/core/services/nft_service.dart`
   - If user has Reown AppKit wallet connected: send `claimNFT(linkHash)` via `eth_sendTransaction`

5. **Implement `NftWalletService.signTransaction()` for derived wallets**
   - File: `lib/core/services/nft_wallet_service.dart`
   - Full secp256k1 signing using `pointy_castle` (already transitive dep):
     1. RLP encode transaction (nonce, gasPrice, gasLimit, to, value, data, chainId)
     2. keccak256 hash
     3. secp256k1 sign with derived private key
     4. Encode v, r, s into signed transaction
     5. Submit via `eth_sendRawTransaction` to chain's RPC
   - Replace placeholder address derivation with proper `keccak256(secp256k1_pubkey)[12:]`

6. **Implement `claimNFT()` for derived wallets**
   - File: `lib/core/services/nft_service.dart`
   - If no Reown AppKit wallet: use `NftWalletService.signTransaction()` to sign and submit
   - On Skale: gas is free (sFUEL). On Base: claimer pays ~$0.01 gas in ETH

7. **Add `claimNft()` to `NftNotifier`**
   - File: `lib/features/nft/providers/nft_provider.dart`
   - Add method, update `isClaiming` state

---

## Phase 4: Transfer-Back + QR

### Prerequisites
- Add to `pubspec.yaml`:
  ```yaml
  qr_flutter: ^4.1.0
  mobile_scanner: ^6.0.0
  ```

### Tasks

1. **Implement QR code generation in `TransferBackQrDialog`**
   - File: `lib/features/nft/widgets/transfer_back_qr_dialog.dart`
   - Replace placeholder with `QrImageView` from `qr_flutter`
   - QR payload (JSON): `{chain, token, amount, claimer, nonce, signature}`
   - Signature: sign `keccak256(abi.encodePacked(chain, token, amount, claimer, nonce))` via derived wallet or Reown AppKit

2. **Implement camera scanner in `NftQrScannerScreen`**
   - File: `lib/features/nft/screens/nft_qr_scanner_screen.dart`
   - Replace placeholder with `MobileScanner` widget
   - On scan: parse JSON payload, validate signature, show confirmation dialog
   - Confirmation: "Return {n} NFT(s), release {fula} FULA to claimer"

3. **Implement `transferBack()` flow**
   - File: `lib/core/services/nft_service.dart`
   - Sender calls `transferBack(tokenId, claimer, amount)` via Reown AppKit
   - Contract transfers NFT sender<-claimer, releases locked FULA to claimer
   - Update `NftClaimRecord.status` to `returnedBack`

4. **Add "Transfer Back" button to claimed NFTs in `NftClaimScreen`**
   - After claiming: show "Transfer Back" button that opens `TransferBackQrDialog`

5. **Wire QR scan route**
   - Route `/nft-qr-scan` already exists
   - Add navigation from `NftDetailScreen` (e.g. action button for sender)

---

## Phase 5: Polish

### Tasks

1. **Error handling**
   - Insufficient FULA balance: check before approve, show specific message
   - No gas (Base): detect ETH balance < estimated gas, prompt user
   - Expired claim links: check `expiresAt` before attempting claim
   - Already claimed: handle contract revert gracefully
   - Network errors: retry logic with exponential backoff

2. **Chain switching**
   - When user is on wrong chain for a mint/claim: call `wallet_switchEthereumChain`
   - Use existing `WalletService.switchChain()` method

3. **Block explorer links**
   - Add "View on Explorer" links for all transaction hashes
   - Use existing `SupportedChain.getTxExplorerUrl(txHash)`
   - Show in `NftCard` and `NftClaimScreen`

4. **Cloud sync for NFT collections**
   - File: `lib/core/services/nft_service.dart`
   - `syncToCloud()` already implemented
   - Add `restoreFromCloud()` following `WebsiteService.restoreFromCloud()` pattern
   - Call on app start after auth check

5. **Loading states and status indicators**
   - Animated status indicators in `NftCard` for in-progress operations
   - Skeleton loading in `NftsBrowserScreen` while tags load
   - Progress overlay during mint flow (approve -> mint -> confirm)

6. **Retry logic for failed operations**
   - Failed mints: "Retry" button on error `NftCard`
   - Failed claims: retry button in `NftClaimScreen`
   - Save partial state so retries can resume from last step

---

## Smart Contract Reference

```solidity
// SPDX-License-Identifier: MIT
// ERC1155 deployed identically on Base (8453) and Skale Europa (2046399126)

// Minting - caller must approve() FULA spend first
mintWithFula(string ipfsCid, uint256 fulaPerNft, uint256 count) -> uint256 firstTokenId

// Claiming - sender creates offer, recipient claims
createClaimOffer(uint256 tokenId, address claimer, uint256 expiresAt) -> bytes32 linkHash
claimNFT(bytes32 linkHash)

// Transfer-back - claimer returns NFT, locked FULA released to claimer
transferBack(uint256 tokenId, address sender, uint256 amount)

// Read functions
getTokenInfo(uint256 tokenId) -> (creator, ipfsCid, fulaAmount, totalSupply)
getClaimOffer(bytes32 linkHash) -> (tokenId, sender, claimer, expiresAt, claimed)
balanceOf(address, uint256) -> uint256  // standard ERC1155
getCreatorTokens(address) -> uint256[]
```

## Deterministic Wallet Derivation

```
existingKey = Argon2id("{provider}:{userId}:{email}", "fula-files-v1") -> 32 bytes [already exists]
nftPrivateKey = HMAC-SHA256(existingKey, "nft-wallet") -> 32 bytes
nftAddress = keccak256(secp256k1_pubkey(nftPrivateKey))[12:] -> 20 bytes -> "0x..."
```

Phase 2 must replace the placeholder address derivation in `NftWalletService` with proper secp256k1 + keccak256 using `pointy_castle`.

## Deep Link Format

```
fxfiles://nft-claim?chain=8453&contract=0x...&token=123&hash=0xabc...
```

## QR Payload Format (Phase 4)

```json
{
  "chain": 8453,
  "token": 123,
  "amount": 1,
  "claimer": "0x...",
  "nonce": 1234567890,
  "signature": "0x..."
}
```
