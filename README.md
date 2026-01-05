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

## Architecture

```
lib/
├── app/
│   ├── app.dart              # Root widget
│   ├── router.dart           # GoRouter navigation
│   └── theme/                # Theme configuration
├── core/
│   ├── models/               # Data models (LocalFile, FulaObject, SyncState)
│   └── services/             # Core services
│       ├── auth_service.dart         # Google/Apple authentication
│       ├── encryption_service.dart   # AES-256-GCM encryption
│       ├── file_service.dart         # Local file operations
│       ├── fula_api_service.dart     # Fula S3-compatible API
│       ├── local_storage_service.dart # Hive local storage
│       ├── secure_storage_service.dart # Secure key storage
│       └── sync_service.dart         # File synchronization
├── features/
│   ├── browser/              # Local file browser
│   ├── fula/                 # Fula cloud browser
│   ├── home/                 # Home screen with categories
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
- [ ] Implement proper error handling for background sync
- [ ] Add unit tests for all services
- [ ] Add AI features that interact with blox