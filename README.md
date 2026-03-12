# FxFiles - Fula File Manager

A minimalistic file manager with Fula decentralized storage backup support. Built with Flutter for cross-platform compatibility.

## Features

- **Local File Browser**: Browse and manage local files and folders
- **Fula Cloud Storage**: Sync files to decentralized Fula network
- **Client-Side Encryption**: AES-256-GCM encryption before upload
- **Authentication**: Sign in with Google or Apple
- **File Viewers**: Built-in viewers for images, videos, and text files
- **Search**: Search local files by name
- **Trash Management**: Safely delete and restore files
- **Dark/Light Theme**: Automatic theme switching
- **NFT Minting**: Mint images as ERC1155 NFTs on Base/Skale Europa with FULA token backing
- **NFT Sharing & Claiming**: Share NFTs via deep links — open claims (anyone) or targeted (specific wallet)
- **NFT Transfer**: Standard ERC1155 transfers between wallets (FULA stays locked)
- **NFT Burn-to-Release**: Burn NFTs to permanently destroy them and release locked FULA to the burner
- **Dual Wallet Support**: Internal wallet (auto-derived from sign-in) or external wallet (WalletConnect)

## Architecture

```
lib/
├── app/
│   ├── app.dart              # Root widget
│   ├── router.dart           # GoRouter navigation
│   └── theme/                # Theme configuration
├── core/
│   ├── models/               # Data models (LocalFile, FulaObject, SyncState, NftToken)
│   └── services/             # Core services
│       ├── auth_service.dart         # Google/Apple authentication
│       ├── encryption_service.dart   # AES-256-GCM encryption
│       ├── file_service.dart         # Local file operations
│       ├── fula_api_service.dart     # Fula S3-compatible API
│       ├── local_storage_service.dart # Hive local storage
│       ├── nft_service.dart          # NFT mint/claim/burn/transfer orchestration
│       ├── nft_contract_service.dart  # ABI encoding + RPC calls for NFT contract
│       ├── nft_wallet_service.dart    # Deterministic wallet derivation + signing
│       ├── secure_storage_service.dart # Secure key storage
│       └── sync_service.dart         # File synchronization
├── features/
│   ├── browser/              # Local file browser
│   ├── fula/                 # Fula cloud browser
│   ├── home/                 # Home screen with categories
│   ├── nft/                  # NFT minting & claiming
│   │   ├── providers/        # NftNotifier, nftTagsProvider, nftMintsProvider
│   │   ├── screens/          # Collection browser, detail, claim
│   │   └── widgets/          # NftCard, MintConfigDialog, ClaimShareSheet
│   ├── search/               # File search
│   ├── settings/             # App settings
│   ├── shared/               # Shared files
│   ├── sync/                 # Sync providers
│   ├── trash/                # Trash management
│   └── viewer/               # File viewers (image, video, text)
├── shared/
│   └── widgets/              # Reusable widgets
└── main.dart                 # App entry point
```

## Getting Started

### Prerequisites

- Flutter SDK 3.2.0 or higher
- Dart SDK 3.2.0 or higher
- Android Studio / Xcode for mobile development

### Installation

1. Clone the repository:
```bash
git clone https://github.com/user/FxFiles.git
cd FxFiles
```

2. Install dependencies:
```bash
flutter pub get
```

3. Run the app:
```bash
flutter run
```

### Windows Build

#### Prerequisites

- Flutter SDK 3.38.0+
- Rust (install from [rustup.rs](https://rustup.rs))
- `flutter_rust_bridge_codegen`: `cargo install flutter_rust_bridge_codegen`

#### Build and Run

```powershell
# 1. Get dependencies
flutter pub get

# 2. Generate Dart/Rust bindings (from repo root of fula-api)
flutter_rust_bridge_codegen generate

# 3. Build the native DLL (from repo root of fula-api)
cargo build -p fula-flutter --release

# 4. Copy DLL to the FxFiles windows directory
copy path\to\fula-api\target\release\fula_flutter.dll windows\fula_flutter.dll

# 5. Run the app
flutter run -d windows
```

The CMakeLists.txt automatically copies `fula_flutter.dll` from `windows/` to the build output directory.

#### Build MSIX Installer

```powershell
# 1. Ensure fula_flutter.dll is in windows/ (see steps above)

# 2. Add msix dev dependency (if not already added)
dart pub add --dev msix

# 3. Build Windows release
flutter build windows --release

# 4. Create MSIX installer
dart run msix:create
```

The MSIX installer will be at `build/windows/x64/runner/Release/fula_files.msix`. Double-click to install.

### Configuration

#### Fula API Setup

1. Open the app and go to **Settings**
2. Under **Fula Configuration**, enter:
   - **API Gateway URL**: Your Fula gateway endpoint (e.g., `https://gateway.fula.network`)
   - **JWT Token**: Your authentication token
   - **IPFS Server** (optional): Custom IPFS server URL

#### Authentication

Sign in with Google or Apple to enable:
- Encrypted file uploads
- Per-user encryption keys derived from authentication
- Cross-device sync

## Security

### Encryption

- **Algorithm**: AES-256-GCM for symmetric encryption
- **Key Derivation**: PBKDF2 with SHA-256 for password-based keys
- **Per-User Keys**: Encryption keys derived from user authentication
- **Client-Side**: All encryption happens locally before upload

### Data Flow

```
Local File → Encrypt (AES-256-GCM) → Upload to Fula → IPFS Storage
                    ↑
            User's Encryption Key
```

## Dependencies

| Package | Purpose |
|---------|---------|
| `flutter_riverpod` | State management |
| `go_router` | Navigation |
| `minio_new` | S3-compatible API client |
| `cryptography` | Encryption primitives |
| `hive_flutter` | Local storage |
| `flutter_secure_storage` | Secure key storage |
| `google_sign_in` | Google authentication |
| `sign_in_with_apple` | Apple authentication |
| `workmanager` | Background sync tasks |
| `connectivity_plus` | Network monitoring |
| `reown_appkit` | WalletConnect wallet connection (external wallet for NFTs) |
| `web3dart` | EVM wallet derivation + transaction signing (internal wallet) |

## Usage

### Upload Files to Fula

1. Browse to local files
2. Select files to upload
3. Tap the upload button
4. Files are encrypted and uploaded automatically

### Download from Fula

1. Open **Fula Browser** from home screen
2. Browse buckets and files
3. Tap a file to download and decrypt

### Sync Folders

```dart
await SyncService.instance.syncFolder(
  localPath: '/storage/emulated/0/Documents',
  remoteBucket: 'my-bucket',
  remotePrefix: 'documents',
  direction: SyncDirection.bidirectional,
);
```

## API Reference

### SyncService

```dart
// Queue file upload
await SyncService.instance.queueUpload(
  localPath: '/path/to/file.txt',
  remoteBucket: 'my-bucket',
  remoteKey: 'file.txt',
  encrypt: true,
);

// Queue file download
await SyncService.instance.queueDownload(
  remoteBucket: 'my-bucket',
  remoteKey: 'file.txt',
  localPath: '/path/to/file.txt',
  decrypt: true,
);

// Retry failed syncs
await SyncService.instance.retryFailed();
```

### FulaApiService

```dart
// List objects in bucket
final objects = await FulaApiService.instance.listObjects(
  'my-bucket',
  prefix: 'folder/',
);

// Upload with encryption
await FulaApiService.instance.encryptAndUpload(
  'my-bucket',
  'file.txt',
  fileBytes,
  encryptionKey,
);

// Download and decrypt
final bytes = await FulaApiService.instance.downloadAndDecrypt(
  'my-bucket',
  'file.txt',
  encryptionKey,
);
```

### Multipart Upload (Large Files)

For files larger than 5MB, multipart upload is used automatically with progress tracking:

```dart
// Upload large file with progress (>5MB uses multipart automatically)
await FulaApiService.instance.uploadLargeFile(
  'my-bucket',
  'large-video.mp4',
  fileBytes,
  onProgress: (progress) {
    print('Upload: ${progress.percentage.toStringAsFixed(1)}%');
  },
);

// Encrypted large file upload
await FulaApiService.instance.encryptAndUploadLargeFile(
  'my-bucket',
  'large-video.mp4',
  fileBytes,
  encryptionKey,
  originalFilename: 'vacation.mp4',
  onProgress: (progress) {
    print('Encrypted upload: ${progress.percentage.toStringAsFixed(1)}%');
  },
);
```

### Background Sync (WorkManager)

Background sync runs automatically when the app is closed:

```dart
// Initialize background sync (called in main.dart)
await BackgroundSyncService.instance.initialize();

// Schedule periodic sync (every 15 minutes on WiFi)
await BackgroundSyncService.instance.schedulePeriodicSync(
  frequency: Duration(minutes: 15),
  requiresWifi: true,
);

// Schedule one-time upload
await BackgroundSyncService.instance.scheduleUpload(
  localPath: '/path/to/file.txt',
  bucket: 'my-bucket',
  key: 'file.txt',
  encrypt: true,
  useMultipart: true,
);

// Schedule one-time download
await BackgroundSyncService.instance.scheduleDownload(
  bucket: 'my-bucket',
  key: 'file.txt',
  localPath: '/path/to/file.txt',
  decrypt: true,
);

// Retry failed operations
await BackgroundSyncService.instance.scheduleRetryFailed();

// Cancel all background tasks
await BackgroundSyncService.instance.cancelAll();
```

### Secure Sharing (HPKE)

Share encrypted files with others without exposing your master key. Three sharing modes are available:

#### Share Types

| Type | Use Case | Security |
|------|----------|----------|
| **Create Link For...** | Share with specific recipient | Highest - uses recipient's public key |
| **Create Link** | Anyone with link can access | Medium - disposable keypair in URL fragment |
| **Create Link with Password** | Password-protected access | High - password + link required |

#### Gateway URL Structure

All share links use the gateway at `https://cloud.fx.land/view`:

```
https://cloud.fx.land/view/{shareId}#{payload}
```

**URL Structure:**
- `{shareId}` - Unique share identifier (UUID)
- `#{payload}` - Base64url-encoded payload in URL fragment (never sent to server)

**Payload Contents (for public/password links):**
```json
{
  "v": 1,              // Version
  "t": "<token>",      // Encoded share token
  "k": "<secretKey>",  // Link secret key (base64)
  "b": "bucket-name",  // Storage bucket
  "p": "/path/to/file", // Path scope
  "pwd": false         // Is password-protected
}
```

#### API Usage

```dart
// Get your public key to share with others
final myPublicKey = await AuthService.instance.getPublicKeyString();

// 1. Create a share for a specific recipient
final token = await SharingService.instance.shareWithUser(
  pathScope: '/photos/vacation/',
  bucket: 'my-bucket',
  recipientPublicKey: recipientPublicKeyBytes,
  recipientName: 'John',
  dek: folderEncryptionKey,
  permissions: SharePermissions.readOnly,
  expiryDays: 30,
  label: 'Vacation photos',
);

// 2. Create a public link (anyone with link can access)
final publicLink = await SharingService.instance.createPublicLink(
  pathScope: '/photos/vacation/',
  bucket: 'my-bucket',
  dek: folderEncryptionKey,
  expiryDays: 7,
  label: 'Vacation photos',
);
// Result: https://cloud.fx.land/view/abc123#eyJ2IjoxLC...

// 3. Create a password-protected link
final passwordLink = await SharingService.instance.createPasswordProtectedLink(
  pathScope: '/documents/report.pdf',
  bucket: 'my-bucket',
  dek: folderEncryptionKey,
  expiryDays: 30,
  password: 'secretPassword123',
  label: 'Monthly report',
);
// Recipients need both the link AND password to access

// Generate share link from OutgoingShare
final link = SharingService.instance.generateShareLinkFromOutgoing(outgoingShare);

// Accept a share from link
final accepted = await SharingService.instance.acceptShareFromString(encodedToken);
print('Access to: ${accepted.pathScope}');
print('Can write: ${accepted.canWrite}');

// Revoke a share
await SharingService.instance.revokeShare(shareId);
```

#### Expiry Options

| Option | Duration |
|--------|----------|
| 1 Day | 24 hours |
| 1 Week | 7 days |
| 1 Month | 30 days |
| 1 Year | 365 days |
| 5 Years | 1825 days (max) |

#### Share Modes

- **Temporal**: Recipients see the latest version of the file/folder
- **Snapshot**: Recipients only see the specific version at share time

**Sharing Model:**
- **Path-Scoped**: Share only specific folders or files
- **Time-Limited**: Access expires automatically
- **Permission-Based**: Read-only, read-write, or full access
- **Revocable**: Cancel access at any time
- **Zero Knowledge**: Server can't read shared content

**Security Details:**
- URL fragment (`#...`) is never sent to server (HTTP standard)
- Public links use disposable X25519 keypairs - private key in fragment
- Password links encrypt the payload with PBKDF2-SHA256 derived key
- All keys stored locally, synced to cloud encrypted with user's master key
- Each share is isolated - revoking one doesn't affect others

**How it works:**
1. Owner creates share token with appropriate encryption
2. For recipient shares: DEK re-encrypted using HPKE (X25519 + AES-256-GCM)
3. For public links: Disposable keypair generated, private key in URL fragment
4. For password links: Payload encrypted with password-derived key
5. Token sent via any channel (link, QR code, message)
6. Recipient decrypts with their private key or password
7. Owner's master key is never exposed

#### Cloud Storage Structure for Shares (Owner's Share List)

The gateway can retrieve an owner's share list from cloud storage. Shares are stored encrypted with the owner's encryption key:

**Storage Location:**
```
Bucket: fula-metadata
Key:    .fula/shares/{userId}.json.enc
```

**User ID Derivation:**
```dart
// userId is first 16 chars of SHA-256(publicKey), URL-safe
final hash = sha256(publicKeyBytes);
final userId = hash.substring(0, 16).replaceAll('/', '_').replaceAll('+', '-');
```

**Decrypted JSON Structure:**
```json
{
  "version": 1,
  "updatedAt": "2024-01-15T10:30:00.000Z",
  "shares": [
    {
      "id": "share-uuid",
      "token": {
        "id": "token-uuid",
        "pathScope": "/photos/vacation/",
        "permissions": "readOnly",
        "wrappedDek": "base64...",
        "recipientPublicKey": "base64...",
        "issuedAt": "2024-01-15T10:30:00.000Z",
        "expiresAt": "2024-02-15T10:30:00.000Z",
        "shareType": "publicLink",
        "shareMode": "temporal"
      },
      "bucket": "photos",
      "recipientName": "Public Link",
      "label": "Vacation photos",
      "sharedAt": "2024-01-15T10:30:00.000Z",
      "isRevoked": false,
      "linkSecretKey": "base64...",
      "passwordSalt": null
    }
  ]
}
```

**OutgoingShare Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique share identifier |
| `token` | ShareToken | The share token with encryption details |
| `bucket` | string | S3 bucket containing shared content |
| `recipientName` | string | Display name (or "Public Link"/"Password Link") |
| `label` | string? | Optional user-defined label |
| `sharedAt` | datetime | When share was created |
| `isRevoked` | bool | Whether share has been revoked |
| `linkSecretKey` | string? | Base64 secret key for public links |
| `passwordSalt` | string? | Base64 salt for password-protected links |

### Audio Playlists Cloud Storage

Playlists are stored encrypted for recovery across devices:

**Storage Location:**
```
Bucket: playlists
Key:    user-playlists/{playlistId}.json
```

**Decrypted JSON Structure:**
```json
{
  "id": "playlist-uuid",
  "name": "My Favorites",
  "tracks": [
    {
      "id": "track-uuid",
      "path": "/storage/emulated/0/Music/song.mp3",
      "name": "Song Title",
      "artist": "Artist Name",
      "album": "Album Name",
      "duration": 180000,
      "artworkPath": "/path/to/artwork.jpg"
    }
  ],
  "createdAt": "2024-01-15T10:30:00.000Z",
  "updatedAt": "2024-01-20T15:45:00.000Z",
  "cloudKey": "user-playlists/playlist-uuid.json",
  "isSyncedToCloud": true
}
```

**Playlist Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique playlist identifier |
| `name` | string | Playlist name |
| `tracks` | AudioTrack[] | List of tracks in order |
| `createdAt` | datetime | When playlist was created |
| `updatedAt` | datetime | Last modification time |
| `cloudKey` | string? | S3 key if synced to cloud |
| `isSyncedToCloud` | bool | Whether synced to cloud |

**AudioTrack Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique track identifier |
| `path` | string | Local file path |
| `name` | string | Track/file name |
| `artist` | string? | Artist name from metadata |
| `album` | string? | Album name from metadata |
| `duration` | int | Duration in milliseconds |
| `artworkPath` | string? | Path to album artwork |

### Gateway Implementation Notes

For the gateway at `https://cloud.fx.land/view`:

1. **Parsing Share Links:**
   ```
   URL: https://cloud.fx.land/view/{shareId}#{payload}

   1. Extract shareId from path
   2. Extract payload from URL fragment (client-side only)
   3. Base64url-decode payload
   4. If password-protected: prompt for password, derive key with PBKDF2
   5. Decrypt payload to get token, bucket, path, and secretKey
   6. Use secretKey to decrypt wrappedDek in token
   7. Use decrypted DEK to access files in bucket/path
   ```

2. **Fetching Owner's Share List:**
   ```
   1. Authenticate owner (get their encryption key)
   2. Compute userId from owner's public key
   3. Fetch: fula-metadata/.fula/shares/{userId}.json.enc
   4. Decrypt with owner's encryption key
   5. Parse JSON to get list of OutgoingShare objects
   ```

3. **Fetching User's Playlists:**
   ```
   1. Authenticate user (get their encryption key)
   2. List objects: playlists/user-playlists/*.json
   3. For each object: download and decrypt with user's key
   4. Parse JSON to get Playlist objects
   ```

### NFT Lifecycle

FxFiles includes a full NFT lifecycle built on ERC1155 tokens with FULA token backing. FULA tokens are permanently locked inside NFTs and can only be released by burning the NFT.

#### Overview

```
Create Collection → Import Images → Mint NFTs → Share / Transfer → Burn to Release FULA
```

Users can:
- **Mint** images as on-chain NFTs with FULA locked per token
- **Share** claim links — open (anyone can claim) or targeted (specific wallet)
- **Transfer** NFTs freely via standard ERC1155 transfers (FULA stays locked)
- **Burn** NFTs to permanently destroy them and release the locked FULA to the burner

#### Wallet Options

Every NFT operation shows a **wallet picker** before proceeding:

| Wallet | Source | Use Case |
|--------|--------|----------|
| **Internal Wallet** | Auto-derived from sign-in credentials via HMAC-SHA256 + secp256k1 (web3dart) | Non-crypto users — no setup required |
| **Connected Wallet** | External wallet via Reown AppKit (WalletConnect) | Crypto users who want to use MetaMask, etc. |

If only one wallet is available, it auto-selects. If neither is available, the user is prompted to sign in or connect.

**Internal wallet derivation:**
```
encryptionKey = Argon2id("{provider}:{userId}:{email}", "fula-files-v1") → 32 bytes (existing)
nftPrivateKey = HMAC-SHA256("nft-wallet", encryptionKey) → 32 bytes
nftAddress    = EthPrivateKey(nftPrivateKey).address → "0x..."
```

The internal wallet uses web3dart's `EthPrivateKey` for proper secp256k1 address derivation and `Web3Client.sendTransaction()` for on-chain signing.

#### 1. Minting

**User flow:** Create Collection → Import Images → Choose Wallet → Configure (count, FULA/NFT, chain) → Mint

**Pipeline (5 checkpointed steps):**

```
Upload to IPFS → Approve FULA spend → mintWithFula() → Poll Receipt → Parse Token ID
```

1. **Upload to IPFS** — Image uploaded unencrypted to Fula S3 gateway, CID returned
2. **Approve FULA** — ERC20 `approve()` so the NFT contract can pull FULA tokens
3. **mintWithFula()** — Contract locks FULA and mints ERC1155 tokens
4. **Poll Receipt** — Wait for transaction confirmation
5. **Parse Token ID** — Extract minted token ID from receipt logs

Each step is persisted to Hive. If the app crashes or the transaction fails, "Retry" resumes from the last successful step (skips upload if CID exists, skips approval if tx exists).

For internal wallets, approval uses `NftWalletService.sendApproveTransaction()` (ABI-encodes ERC20 approve and signs locally). For external wallets, it goes through `WalletService.sendContractTransaction()` via WalletConnect.

#### 2. Sharing (Claim Links)

**Creator side:** On a minted NFT card → "Share Claim" → Configure → Share link

The claim dialog offers:
- **"Anyone can claim" toggle** (default ON) — creates an open claim where `claimer = address(0)` on-chain. First person to open the link claims it.
- **Targeted claim** (toggle OFF) — enter a specific wallet address. Only that wallet can claim.
- **Expiry** — 1, 7, 30, or 90 days.

The contract escrows 1 NFT via `createClaimOffer()` and returns a `linkHash`. A deep link is generated:

```
fxfiles://nft-claim?chain={chainId}&contract={address}&token={tokenId}&hash={linkHash}
```

**Claimer side:** Open link → App shows NFT details (image, creator, FULA/NFT, supply) → Choose Wallet → Claim

The claim screen fetches token info from the contract via `eth_call`, displays the NFT image from the IPFS gateway, and calls `claimNFT(linkHash)` on-chain. Pre-claim checks detect already-claimed or expired links.

After claiming, the screen shows **Transfer** and **Burn** buttons.

#### 3. Transfer

Standard ERC1155 `safeTransferFrom()`. FULA tokens remain locked inside the NFT — transfers do NOT release FULA. The UI shows: "Transfer keeps FULA locked. Only burning releases FULA."

**Flow:** Choose Wallet → Enter recipient `0x...` address → Confirm → `safeTransferFrom()` → Poll Receipt

NFTs can be transferred any number of times between any wallets. The FULA only comes out when someone burns.

#### 4. Burn (Releases FULA)

The **only way** to release locked FULA from an NFT is to burn it. Burning permanently destroys the NFT and sends the proportional FULA to the burner.

**Flow:** Choose Wallet → Confirmation dialog ("This will permanently destroy the NFT and release X FULA to your wallet. This action cannot be undone.") → `burn(account, tokenId, amount)` → Poll Receipt

The contract's `burn()` override:
1. Calls `super.burn()` — standard ERC1155 burn (checks caller is owner or approved, zeros balance)
2. Calculates `fulaToRelease = tokenInfo[id].fulaPerNft * amount`
3. Decrements `totalLockedFula`
4. Transfers FULA to the burner via `storageToken.safeTransfer()`
5. Emits `NftBurned(tokenId, burner, amount, fulaReleased)`

`burnBatch()` works similarly for multiple token types in one transaction.

#### Smart Contract: `FulaFileNFT.sol`

ERC1155 upgradeable contract using OpenZeppelin v5.3.0 + GovernanceModule (UUPS proxy).

Deployed identically on Base (chain 8453) and Skale Europa (chain 2046399126).

```solidity
// Mint — caller must approve() FULA spend first
mintWithFula(string ipfsCid, uint256 fulaPerNft, uint256 count) → uint256 firstTokenId

// Claim — sender creates offer (escrows NFT), recipient claims
createClaimOffer(uint256 tokenId, address claimer, uint256 expiresAt) → bytes32 linkHash
claimNFT(bytes32 linkHash)
// claimer = address(0) → open claim (anyone can claim)
// claimer = 0x1234...  → only that address can claim

// Burn — permanently destroys NFT, releases locked FULA to burner
burn(address account, uint256 id, uint256 value)       // single token type
burnBatch(address account, uint256[] ids, uint256[] values)  // multiple types

// Transfer — standard ERC1155, FULA stays locked
safeTransferFrom(from, to, id, amount, data)  // inherited from ERC1155

// Cancel — sender (after expiry) or admin can cancel stuck offers
cancelClaimOffer(bytes32 linkHash)

// Read
getTokenInfo(uint256 tokenId) → (creator, ipfsCid, fulaAmount, totalSupply)
getClaimOffer(bytes32 linkHash) → (tokenId, sender, claimer, expiresAt, claimed)
getCreatorTokens(address) → uint256[]
```

**Security features:**
- `totalLockedFula` tracking prevents admin `recoverERC20` from draining locked funds
- Monotonic nonce prevents duplicate claim offer hashes
- `ipfsCid` length validation (1-256 bytes)
- `nonReentrant` + `whenNotPaused` on all write functions
- Burn checks caller is owner or approved (via ERC1155Burnable)

#### Flutter Architecture

| Component | Role |
|-----------|------|
| `NftService` | Orchestrates mint/claim/burn/transfer flows, Hive persistence, cloud sync |
| `NftContractService` | ABI encoding, RPC calls, receipt polling |
| `NftWalletService` | Deterministic wallet derivation (web3dart), transaction signing |
| `WalletService` | External wallet via Reown AppKit (WalletConnect) |
| `NftNotifier` (Riverpod) | UI state: `isMinting`, `isClaiming`, `isBurning`, `isTransferring`, `error` |
| `nftMintsProvider` | `StreamProvider.family` — real-time mint status updates per collection |
| `nftTagsProvider` | Filters tags with `nft-` prefix to list NFT collections |

**Wallet dispatch:** All transaction methods accept a `WalletSource` enum (`internal` or `external`). Internal uses `NftWalletService.sendSignedTransaction()` (web3dart `Web3Client`). External uses `WalletService.sendContractTransaction()` (Reown AppKit).

#### Data Models (Hive)

| Type ID | Model | Description |
|---------|-------|-------------|
| 30 | `NftCollection` | Collection with tagId, name, list of mints |
| 31 | `NftMintRecord` | Mint state: CID, txHash, tokenId, status, claims |
| 32 | `NftClaimRecord` | Claim state: linkHash, claimer, status, tx hashes |
| 33 | `NftMintStatus` | Enum: approving, minting, confirming, completed, error |
| 34 | `NftClaimStatus` | Enum: pending, claimed, burned, expired |

#### Cloud Sync

NFT metadata is encrypted and synced to the `nft-metadata` S3 bucket:

```
Bucket: nft-metadata
Key:    .fula/nfts/{userId}.json
```

On login, `restoreFromCloud()` merges cloud data with local state, preserving any in-progress mints. Sync is debounced (5s) and triggered after mints, claims, and burns.

#### Deep Link Format

```
fxfiles://nft-claim?chain=8453&contract=0x...&token=123&hash=0xabc...
```

#### After Contract Deployment

Replace the zero-address placeholders in `SupportedChain.nftContractAddress` with the real proxy addresses for each chain.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Commit changes
4. Push to the branch
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- [Fula Network](https://fula.network) for decentralized storage
- Flutter team for the amazing framework
- All open-source contributors

## Demo

[Watch the demo video](https://youtu.be/rhEi1yA14LM)

## TODO

- [ X ] Add repeat track for audio playback. An icon to allow user to click and it puts the playing track on repeat and the icon becomes filled and another click toggles off (Audio)
- [ X ] Add audio playlist creation and management + Upload the playlist to cloud encrypted nad securely using hte S3 APIs so that user can recover them (Audio)
- [ X ] Add shuffle functionality for playlists (Audio)
- [ X ] Add playlist management (rename, delete, reorder) (Audio)
- [ X ] Add audio visualization in the audio player to beautify it with animated waveforms (Audio)
- [ X ] Add audio equalizer to adjust bass, treble, and mid frequencies with a simpole click (Audio)
- [ X ] Add playback control from lock screen (Audio)
- [ X ] Add playback control from notification tray (Audio)
- [ X ] Audio track playback continues when going out of audios in the app. the player will become minimized at the bottom of hte screen where user can still interat with buttons and see the progress bar of audio while browsing other files (Audio)
- [ X ] Add video playback picture-in-picture so user can minimize a playing video and continue browsing other files. also it has the picture in picture feature of app that the minimized video can be seen in android screen whele using other apps too (Videos)
- [ X ] Add video thumbnail in browsing but it should be optimized and not consume much processing power (Videos)
- [ X ] Add zip file viewer and unzip functionality to specified location. so in the Archive category in the menu of each zip file, we also ee an unzip item (Archives)
- [ X ] Add file compression so in all screens like Images, Videos, Documents, when we select a file or multiple files on the top currenly we see a delete and a share icon, we also need to add a compression icon to compress files to zip (Archives, General)
- [ X ] Bug: Loading large text files hangs up the app, we should add streaming loading and lazy loading for better performance for large text files (Documents)
- [ X ] Add search text in text viewer so that user can type a text in document viewer search and can go to next or previouse occurances of that text (Documents)
- [ X ] Add goto line functionality in text viewer that user clicks in document viewer and then enters the line number to jump to and it takes user to that line (Documents)
- [ X ] Bug: In opened text file in the text viewer, the wrap text does not work (Documents)
- [ X ] Clicking on a type like pdf that cannot be opned in-app, should open the Android or iOS app selector to open it with the correct app. in other plavces if there is an unknown file type showing in the list that cannot be handled by app, it should open the Android or iOS app selector to open it with the correct app (Documents, General)
- [ X ] Add Image Editor to be able to crop, rotate, and adjust brightness, contrast, and saturation and write text over image (Images)
- [ X ] Add swipe right and left gestures in image viewer to go to next and previouse image in Images when an image is opened, but ensure that in zoom mode swipe bedcome deactivated and enhance gesture handlers to differentiate swipe and pinch and pan for zoom clearly (Images)
- [ X ] In zoom mode of image viewer, double tapping the screen takes it to normal view (images)
- [ X ] Swiping up the image in image viewer, reveals and shows the file details below the image along with faces that are detected in the image (Images)
- [ X ] Bug: Reword JWT Token to API Key
- [ X ] Design: Separate the Starred, Cloud, Shared and Playlists categories under a differnet section, named "Featured" below hte Categories section and before "Storage" section (General)
- [ X ] Bug: Starred files are not showing up in the Starred category. Although it seems hte file is starred but hte starred category remains empty (General)
- [ X ] Bug: In audio player, the first time you open an audio the visualizer stays in loading (Audio)
- [ X ] Bug: Version in about screen not updating according to latest app version
- [ X ] Add thumbscroll functionality for better navigation. the header tags shown in thumbscroll mode should be according to the sorting. for exmaple in sorting alphanumerically, the headrs become the letters of filenames like A,B,C,... when in date sort mode the tags become the month-year like Jan-2024, Feb-2024, etc. We should consider all optimizations possible to make it fast and smooth in large folders and in categories and to ensure that the headers are not repeated and updated according to all files in the folder or category without reducing hte performance or making the app laggy. Also it should be a separate module that can be deactivated if user wants (General)
- [ ] Add folder names in tabs inside each category. default view is All, but user can switch to other tabs in each category like "Images" to see only images in that folder for example "WhatsApp"
- [ X ] Add sharing with links where root path is https://cloud.fx.land/ and the rest of parameters are based on the current s3 API doc for encrypted files where we have everything to decrypt a file in the link and it shows the link to user (General) - Implemented three share types: public links, password-protected links, and recipient-specific shares
- [ X ] Change package name to land.fx.files.dev and create github actions to remove.dev for publishing to play store
- [ X ] NFT minting: Mint images as ERC1155 NFTs on Base/Skale Europa with FULA token locking (NFT)
- [ X ] NFT claim links: Share NFTs via deep links — open claims (anyone) or targeted (specific wallet) (NFT)
- [ X ] NFT burn-to-release: Burn NFTs to permanently destroy and release locked FULA (NFT)
- [ X ] NFT transfer: Standard ERC1155 transfers, FULA stays locked (NFT)
- [ X ] NFT internal wallet: Deterministic wallet derivation + web3dart signing for non-crypto users (NFT)
- [ X ] NFT wallet picker: Choose internal or connected wallet before every operation (NFT)
- [ X ] NFT cloud sync: Encrypted metadata sync to S3 for cross-device recovery (NFT)
- [ X ] NFT retry logic: Resume failed mints from last checkpoint (NFT)
- [ X ] Deploy FulaFileNFT contract and update SupportedChain addresses (NFT)
- [ X ] Implement proper error handling for background sync
- [ X ] Add unit tests for all services
- [ X ] Add AI features that interact with blox
