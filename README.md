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

Share encrypted files with others without exposing your master key:

```dart
// Get your public key to share with others
final myPublicKey = await AuthService.instance.getPublicKeyString();

// Create a share for another user
final token = await SharingService.instance.createShare(
  pathScope: '/photos/vacation/',
  bucket: 'my-bucket',
  recipientPublicKey: recipientPublicKeyBytes,
  dek: folderEncryptionKey,
  permissions: SharePermissions.readOnly,
  expiryDays: 30,
  label: 'Vacation photos',
);

// Generate shareable link
final link = SharingService.instance.generateShareLink(token);
// Result: fula://share/eyJpZCI6Ii4uLiJ9...

// Accept a share from link
final accepted = await SharingService.instance.acceptShareFromString(encodedToken);
print('Access to: ${accepted.pathScope}');
print('Can write: ${accepted.canWrite}');

// Revoke a share
await SharingService.instance.revokeShare(shareId);
```

**Sharing Model (from Fula API):**
- **Path-Scoped**: Share only specific folders
- **Time-Limited**: Access expires automatically  
- **Permission-Based**: Read-only, read-write, or full access
- **Revocable**: Cancel access at any time
- **Zero Knowledge**: Server can't read shared content

**How it works:**
1. Owner creates share token with recipient's public key
2. DEK is re-encrypted for recipient using HPKE (X25519 + AES-256-GCM)
3. Token sent via any channel (link, QR code, message)
4. Recipient decrypts with their private key
5. Owner's master key is never exposed

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
- [ ] Add zip file viewer and unzip functionality to specified location (Archives)
- [ ] Add file compression (Archives)
- [ X ] Bug: Reword JWT Token to API Key
- [ ] Bug: Loading large text files hangs up the app, we should add streaming loading and lazy loading for better performance for large text files (Documents)
- [ ] Add search text in text viewer so that user can type a text in document viewer search and can go to next or previouse occurances of that text (Documents)
- [ ] Add goto line functionality in text viewer that user clicks in document viewer and then enters the line number to jump to and it takes user to that line (Documents)
- [ ] Bug: In opened text file in the text viewer, the wrap text does not work (Documents)
- [ ] Clicking on a type like pdf that cannot be opneed in-app, should open the Android or iOS app selector to open it with the correct app (Documents)
- [ X ] Add Image Editor to be able to crop, rotate, and adjust brightness, contrast, and saturation and write text over image (Images)
- [ X ] Add swipe right and left gestures in image viewer to go to next and previouse image in Images when an image is opened, but ensure that in zoom mode swipe bedcome deactivated and enhance gesture handlers to differentiate swipe and pinch and pan for zoom clearly (Images)
- [ X ] In zoom mode of image viewer, double tapping the screen takes it to normal view (images)
- [ X ] Swiping up the image in image viewer, reveals and shows the file details below the image along with faces that are detected in the image (Images)
- [ ] Bug: Starred files are not showing up in the Starred category (General)
- [ ] Add thumbscroll functionality for better navigation. the header tags shown in thumbscroll mode should be according to the sorting. for exmaple in sorting alphanumerically, the headrs become the letters of filenames like A,B,C,... when in date sort mode the tags become the month-year like Jan-2024, Feb-2024, etc. (General)
- [ ] Add sharing with links where root path is https://cloud.fx.land/ and the rest of paramtetres are based on the current s3 API doc for encrypted files where we have everyting to decrypt a file in the link and it shows hte link to user (General)
- [ ] Implement proper error handling for background sync
- [ ] Add unit tests for all services
- [ ] Bug: In audio player, the first time you open an audio the visualizer stays in loading (Audio)
- [ ] Bug: Version in about screen not updating according to latest app version