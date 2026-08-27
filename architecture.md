# FxFiles Upload/Download Flow — Blox vs Non-Blox Users

## Context

This document explains how file upload and download works in FxFiles for two user types:
1. **Non-blox user** — cloud-only, no hardware device
2. **Blox user** — has a paired FxBlox device on their LAN

Both paths use the **same S3-compatible API** and **same client-side encryption**. The only differences are the endpoint URL and auth token type.

---

## 1. Non-Blox User (Cloud Only)

### UX — Upload

1. User opens **File Browser** screen, taps a file (or selects multiple)
2. Taps **"Upload to Cloud"** → snackbar: "Queued for upload: photo.jpg"
3. File is added to `SyncService._uploadQueue` (persistent — survives app restart)
4. Background queue processor picks it up → progress indicator shows upload %
5. On completion → snackbar: "File synced" → file appears in Cloud Browser

Folder uploads recursively queue all files preserving relative paths.

### UX — Download

1. User opens **Cloud Browser** (route `/fula?bucket=...&prefix=...`)
2. Browses encrypted cloud storage (folders and files shown with original names)
3. Taps a file → snackbar: "Downloading photo.jpg..."
4. File downloads to `/Download/` folder (or category-specific folder)
5. On completion → snackbar: "Downloaded photo.jpg"

### Data Flow — Upload

```
FxFiles app
  │
  ├─ 1. AuthService.getEncryptionKey()
  │     → Argon2id("fula-files-v1", "google:{userId}:{email}") → 32-byte AES key
  │
  ├─ 2. FulaApiService.createBucket("images")  [if not exists]
  │     → PUT https://s3.cloud.fx.land/images
  │     → Header: Authorization: Bearer <JWT>
  │
  ├─ 3. FulaApiService.encryptAndUploadLargeFile(bucket, key, data)
  │     → fula_client Rust FFI: putFlat(client, bucket, path, data, contentType)
  │       ├─ Encrypts file with AES-256-GCM using derived key
  │       ├─ Encrypts metadata (filename) with FlatNamespace obfuscation
  │       └─ Sends PUT https://s3.cloud.fx.land/{bucket}/{obfuscated-key}
  │            Header: Authorization: Bearer <JWT>
  │            Body: encrypted file bytes
  │
  └─ Server side (fula-api cloud gateway):
       ├─ Auth middleware validates JWT → extracts user_id → BLAKE3 hash
       ├─ Stores encrypted bytes in kubo → gets CID (content-addressed)
       ├─ Creates ObjectMetadata (CID, size, owner_id, content_type)
       ├─ Opens user-scoped bucket: "{hashed_user_id}:{bucket_name}"
       ├─ Stores object in Prolly Tree index
       ├─ Flushes bucket → new root CID
       ├─ Persists bucket registry → pins registry CID to remote pinning service
       └─ Returns 200 OK with ETag (= CID)
```

### Data Flow — Download

```
FxFiles app
  │
  ├─ 1. FulaApiService.downloadAndDecrypt(bucket, key, encryptionKey)
  │     → fula_client Rust FFI: getFlat(client, bucket, path)
  │       ├─ Sends GET https://s3.cloud.fx.land/{bucket}/{obfuscated-key}
  │       │    Header: Authorization: Bearer <JWT>
  │       ├─ Server: looks up object in user-scoped Prolly Tree → gets CID
  │       │    → fetches block from kubo (IPFS /api/v0/cat for DAGs, /api/v0/block/get for raw)
  │       │    → returns encrypted bytes with ETag, Content-Type headers
  │       ├─ Decrypts file with AES-256-GCM using derived key
  │       └─ Returns plaintext Uint8List
  │
  └─ 2. Write to disk: File(downloadPath).writeAsBytes(data)
```

**Key points:**
- Encryption/decryption is always **client-side** (fula_client Rust library via FFI)
- Server never sees plaintext — stores encrypted blobs addressed by CID
- Filenames are obfuscated on server (FlatNamespace mode); original names in encrypted index
- ETag = IPFS CID (content-addressed, not MD5)

---

## 2. Blox User (LAN + Cloud)

### Additional UX — Pairing

Contract: `docs/AUTOPIN-HANDOFF.md` (v1.1). URL builders + the return parser live in
`lib/core/services/blox_pairing_links.dart` (dart:io-free; unit-tested).

1. User goes to **Settings → My Devices → Pair Blox**
2. FxFiles hands off to FxBlox with the SAME params on one of two carriers:
   - **App** (mobile): `fxblox://autopin-pair?token=<JWT>&endpoint=<https api base>&returnUrl=<template>`
     (query — the custom scheme is routed by the OS, never a server)
   - **Web** (`https://blox.fx.land/autopin-pair#token=…&endpoint=…&returnUrl=…` — **fragment**, v1.1,
     so the JWT never reaches the Pages server/CDN logs or a Referer; FxBlox-web reads `location.hash`
     first and accepts the v1 `?token=…` query as a fallback): always from the web build
     (`lib/web/screens/web_blox_pairing_screen.dart`, same-tab), from desktop's manual pairing dialog
     ("Pair in browser"), and as the mobile fallback when the FxBlox app is not installed
     (`launchUrl` false/throws → "Pair in browser" dialog).
   - `returnUrl` is a URL-encoded **template** with the literal placeholders `$secret`, `$hardwareId`,
     `$bloxPeerId`, `$bloxName`: `https://files.fx.land/autopin-complete#secret=$secret&hardwareId=$hardwareId&bloxPeerId=$bloxPeerId&bloxName=$bloxName`
     (fragment form — the bearer secret never reaches a server).
3. FxBlox calls the blox's `AutoPinPair(token, endpoint)` via libp2p
   - go-fula stores `auto_pin_token`, `auto_pin_endpoint`, `auto_pin_pairing_secret` in `box_props.json`
   - Returns pairing secret + hardware ID
4. FxBlox substitutes the placeholders and navigates (user click) to the result. Receivers:
   - **Native app link** (`DeepLinkService._handleUniversalLink` → `_handleAutoPinComplete`): iOS
     (AASA `/autopin-complete*`) and Android (manifest `pathPrefix="/autopin-complete"`) open FxFiles
     directly with the full URL; the parser reads the fragment first, then the query. The legacy
     `fxfiles://autopin-complete?secret=…` deep link is still accepted.
   - **Static forwarder** `site/autopin-complete/index.html` (when the app link is not verified, the
     app is missing, or on desktop): reads the fragment, on mobile auto-tries
     `fxfiles://autopin-complete?…` (2.5 s `document.hidden` fallback), otherwise offers
     "Open in FxFiles" and "Continue in web app" → `https://files.fx.land/app/#/autopin-complete?…`.
   - **Web build** (`lib/main_web.dart` → `captureAutopinReturn()` BEFORE `runApp`): stashes the
     params (memory + sessionStorage) and `history.replaceState`s the URL to `#/` so the secret leaves
     the address bar and the logged-out router redirect cannot drop it; the web home's post-login init
     `takePendingAutopinReturn()`s and navigates to `/blox-pairing` with the params as go_router
     `extra`. `/autopin-complete` also exists as a router fallback.
5. FxFiles validates (non-empty secret, length caps, no control chars) and stores pairing secret,
   hardware ID, peer ID, name in SecureStorage.

Web limitation: the web build cannot use the Blox LAN gateway (`http://<ip>:9000` is mixed content
from an https page and browsers have no mDNS), so web downloads always come from the cloud; pairing
from the web still makes the Blox auto-pin. The credentials are device-local (that browser); native /
desktop FxFiles pair separately (desktop's manual dialog accepts the pairing secret).

### Additional UX — Blox Discovery

- `BloxDiscoveryService` runs mDNS scan every 30 seconds for `_fulatower._tcp.local`
- Extracts from TXT records: `s3Port=9000`, `autoPinPort=3501`, `gatewayPort=8080`, peer ID, hardware ID
- Builds `BloxDevice` with `s3Url = "http://{blox-ip}:9000"`
- When paired blox found on LAN → `FulaApiService.switchToLocalGateway(bloxDevice.s3Url, pairingSecret)`

### UX — Upload (Blox User)

**Identical to non-blox user from the user's perspective.** The upload still goes to the **cloud gateway** because:
- The blox is a **sync consumer**, not an upload target
- Uploads go to `s3.cloud.fx.land` → cloud kubo → remote pinning service
- The blox's `fula-pinning` daemon then pulls the data down via IPFS P2P

### UX — Download (Blox User)

User experience is identical (tap file → downloads), but **faster over LAN**:
- If blox is on the same network, `FulaApiService` switches to local endpoint
- Download comes from blox at `http://192.168.x.x:9000` instead of `https://s3.cloud.fx.land`
- Same encryption, same file format, same API

### Data Flow — Upload (Blox User)

```
Same as non-blox upload — always goes to cloud:

FxFiles → PUT https://s3.cloud.fx.land/{bucket}/{key}
       → Auth: Bearer <JWT>
       → cloud gateway stores in cloud kubo, pins to pinning service

Then asynchronously (no user involvement):

fula-pinning daemon (on blox, every 3 min):
  ├─ GET remote pinning service API (user's JWT from box_props.json)
  ├─ Gets list of pinned CIDs for this user
  ├─ Compares against local kubo pins
  ├─ For missing CIDs: ipfs pin add <cid>
  │   → kubo fetches blocks over IPFS P2P network from cloud kubo
  ├─ Writes bucket registry CID to /internal/fula-gateway/registry.cid
  └─ fula-gateway polls this file every 30s, reloads registry when CID changes
```

### Data Flow — Download (Blox User, LAN)

```
FxFiles app (blox on same LAN)
  │
  ├─ BloxDiscoveryService found paired blox at 192.168.1.100
  ├─ FulaApiService.switchToLocalGateway("http://192.168.1.100:9000", pairingSecret)
  │
  ├─ 1. FulaApiService.downloadAndDecrypt(bucket, key, encryptionKey)
  │     → fula_client Rust FFI: getFlat(client, bucket, path)
  │       ├─ Sends GET http://192.168.1.100:9000/{bucket}/{obfuscated-key}
  │       │    Header: Authorization: Bearer <pairing_secret>  ← NOT JWT
  │       │
  │       ├─ Local fula-gateway (on blox):
  │       │    ├─ Auth middleware: validates bearer == box_props.json pairing_secret
  │       │    ├─ Derives owner_id from box_props.json JWT sub claim (BLAKE3 hash)
  │       │    ├─ Loads registry from registry.cid (synced by fula-pinning)
  │       │    ├─ Opens user-scoped bucket → Prolly Tree lookup → gets CID
  │       │    ├─ Fetches block from LOCAL kubo (127.0.0.1:5001)
  │       │    │   → Data already present because fula-pinning synced it
  │       │    └─ Returns encrypted bytes + X-Fula-Content-Cid header
  │       │
  │       ├─ Decrypts file with AES-256-GCM (same key, same algorithm)
  │       └─ Returns plaintext Uint8List
  │
  └─ 2. Write to disk (identical)
```

### Data Flow — Download (Blox User, NOT on LAN)

If blox is not reachable (user is away from home), `switchToCloudGateway()` is called and the flow is **identical to non-blox user** — download from `s3.cloud.fx.land` with JWT auth.

---

## 3. Comparison Table

| Aspect | Non-Blox User | Blox User (LAN) | Blox User (Remote) |
|--------|---------------|------------------|---------------------|
| **Upload endpoint** | `s3.cloud.fx.land` | `s3.cloud.fx.land` (same) | `s3.cloud.fx.land` (same) |
| **Upload auth** | Bearer JWT | Bearer JWT | Bearer JWT |
| **Download endpoint** | `s3.cloud.fx.land` | `http://{blox-ip}:9000` | `s3.cloud.fx.land` |
| **Download auth** | Bearer JWT | Bearer pairing_secret | Bearer JWT |
| **Download speed** | WAN (internet) | LAN (local network) | WAN (internet) |
| **Encryption** | Client-side AES-256-GCM | Same | Same |
| **Encryption key** | Argon2id from user creds | Same key | Same key |
| **Data on blox?** | No | Yes (synced by fula-pinning) | Yes (but not used) |
| **Offline access** | No | Yes (if data synced) | No |

---

## 4. Encryption Details

- **Key derivation**: `Argon2id("fula-files-v1", "google:{userId}:{email}")` → 32-byte key
- **File encryption**: AES-256-GCM (handled transparently by `fula_client` Rust library)
- **Metadata privacy**: FlatNamespace obfuscation — original filenames stored only in encrypted index
- **Cross-platform**: Same derived key on Flutter (native) and WebUI (WASM)
- **Server-side**: No encryption — gateway stores encrypted blobs as-is in IPFS
- **Same key for cloud and local**: Encryption is user-scoped, not endpoint-scoped

---

## 5. How Data Gets to the Blox (Sync Flow)

```
User uploads via FxFiles
    ↓
Cloud S3 Gateway (s3.cloud.fx.land)
    ↓
Cloud Kubo (stores blocks) + Remote Pinning Service (records CIDs)
    ↓
fula-pinning daemon on blox (polls pinning service every 3 min using user's JWT)
    ↓
Finds new CIDs → ipfs pin add → local kubo fetches blocks over IPFS P2P
    ↓
Writes registry.cid → fula-gateway reloads → files now available on LAN
```

---

## 6. Key Code Paths

| Component | File | Role |
|-----------|------|------|
| Upload queue | `FxFiles/lib/core/services/sync_service.dart` | Queues, retries, progress |
| S3 client | `FxFiles/lib/core/services/fula_api_service.dart` | `putFlat()`, `getFlat()`, gateway switching |
| Encryption | `fula_client` Rust crate (FFI) | AES-256-GCM encrypt/decrypt |
| Blox discovery | `FxFiles/lib/core/services/blox_discovery_service.dart` | mDNS `_fulatower._tcp.local` |
| Cloud gateway | `fula-api/crates/fula-cli/src/handlers/object.rs` | `put_object`, `get_object` |
| Local gateway | `fula-ota/docker/fula-gateway/fula-local-gateway/` | Same S3 API, bearer auth |
| Auto-pin sync | `fula-ota/docker/fula-pinning/` | Polls remote pinning → local kubo pin |
| mDNS advertise | `go-fula/wap/cmd/mdns/mdns.go:165` | `s3Port=9000` in TXT records |
| Pairing | `go-fula/blockchain/bl_autopin.go` | Stores credentials in box_props.json |

---

## 7. FxFiles Client Implementation Details

### Upload Queue (SyncService)

- **Parallel uploads**: Up to 5 concurrent uploads (configurable)
- **Persistent queue**: Stored in Hive `sync_queue` box — survives app restart
- **Retry logic**: Exponential backoff (2s, 4s, 8s, 16s, 32s, capped at 5 min)
- **Max retries**: 5 attempts per file
- **Auto-pause**: Queue pauses for 2 minutes after 3 consecutive failures
- **Progress tracking**: `UploadProgressManager` with speed estimation per file and batch

### Error Classification

- **Retryable**: DNS failures, connection refused/reset, timeouts, bad gateway, SSL issues, EOF
- **Permanent**: 401/403/404/409/410/413/422, access denied, invalid key, quota exceeded

### SyncState Model

```dart
SyncStatus: notSynced | syncing | synced | error

Fields:
  localPath, remotePath, remoteKey, bucket, status,
  lastSyncedAt, etag, localSize, remoteSize, errorMessage,
  displayPath (iOS PhotoKit), iosAssetId, contentCid (IPFS CID for Blox)
```

### Background Sync

- **Android**: WorkManager periodic task (15 min minimum)
- **iOS**: BGProcessingTask
- **Task types**:
  - `periodicSync` — 15-min periodic processing
  - `uploadTask` — One-off file upload (9-min timeout)
  - `downloadTask` — One-off file download (9-min timeout)
  - `retryFailedTask` — Retry all failed uploads
  - `cleanupTask` — Clean up incomplete multipart uploads >24h old

### FulaApiService Methods

```dart
initialize(endpoint, secretKey, accessToken, defaultBucket)
switchToLocalGateway(localUrl, pairingSecret)  // For paired Blox
switchToCloudGateway(endpoint, accessToken)
uploadObject / uploadLargeFile(bucket, key, data)
downloadObject / downloadAndDecrypt(bucket, key)
deleteObject(bucket, key)
listObjects(bucket, prefix, recursive)
createBucket(bucket)
createShareToken(bucket, storageKey, recipientPublicKey, mode, expiresAt)
```

### BloxDiscoveryService

- mDNS scan every 30 seconds for `_fulatower._tcp.local`
- Extracts from TXT records: `s3Port`, `autoPinPort`, `gatewayPort`, peer ID, hardware ID
- Builds `BloxDevice` with `s3Url = "http://{blox-ip}:9000"`
- Can report missing CIDs to fula-pinning for priority pinning
- Polls auto-pin status (pinned count, pending count, last sync)

---

## 8. Blox-Side Services

### fula-gateway (Rust S3 Gateway)

- **Port**: 9000 (LAN-only via firewall)
- **Framework**: Axum 0.8 + Tokio
- **Auth**: Bearer token from `box_props.json` pairing secret
- **User scoping**: BLAKE3 hash of JWT `sub` claim → `owner_id`
- **CID watcher**: Polls `/internal/fula-gateway/registry.cid` every 30s, reloads on change
- **Storage**: Uses `fula-core` and `fula-blockstore` crates from fula-api
- **S3 API support**: GET, PUT, DELETE, HEAD, COPY objects; multipart uploads; bucket operations
- **Special headers**: `X-Fula-Content-Cid` on every object response
- **Health check**: `GET /healthz`

### fula-pinning (Go Sync Daemon)

- **Port**: 3501 (LAN-only via firewall)
- **Language**: Pure Go stdlib (no external dependencies)
- **Sync interval**: Every 3 minutes (configurable via `SYNC_INTERVAL`)
- **Config polling**: Reads `box_props.json` every 30 seconds for pair/unpair detection
- **Sync algorithm**:
  1. Fetch all remote pins from pinning service (paginated, 1000/page)
  2. Fetch local recursive pins from Kubo
  3. Diff to find missing CIDs
  4. Pin each missing CID recursively via Kubo API
  5. Write registry CID to `/internal/fula-gateway/registry.cid` (atomic write)
- **Priority queue**: HTTP API accepts up to 100 CIDs for immediate pinning
- **HTTP endpoints**:
  - `GET /api/v1/auto-pin/status` — daemon status JSON
  - `POST /api/v1/auto-pin/report-missing` — queue priority pins
- **Auth**: All endpoints require `Authorization: Bearer {pairing_secret}`

### Docker Compose Configuration

Both services run with `network_mode: "host"` and depend on kubo:

```yaml
fula-pinning:
  image: ${FULA_PINNING:-functionland/fula-pinning:release}
  container_name: fula_pinning
  restart: unless-stopped
  network_mode: "host"
  volumes:
    - /home/pi/.internal:/internal:rw,rshared
  depends_on:
    - kubo
  environment:
    - KUBO_API=http://127.0.0.1:5001
    - AUTO_PIN_PORT=3501
    - SYNC_INTERVAL=3m
    - REGISTRY_CID_PATH=/internal/fula-gateway/registry.cid

fula-gateway:
  image: ${FULA_GATEWAY:-functionland/fula-gateway:release}
  container_name: fula_gateway
  restart: unless-stopped
  network_mode: "host"
  volumes:
    - /home/pi/.internal:/internal:rw,rshared
  depends_on:
    - kubo
  environment:
    - FULA_HOST=0.0.0.0
    - FULA_PORT=9000
    - IPFS_API_URL=http://127.0.0.1:5001
    - REGISTRY_CID_PATH=/internal/fula-gateway/registry.cid
    - BOX_PROPS_FILE=/internal/box_props.json
    - RUST_LOG=info
```

### Firewall Rules

Both ports restricted to LAN-only access:

```bash
# Port 3501 (fula-pinning)
iptables -A "$CHAIN" -p tcp --dport 3501 -s 192.168.0.0/16 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 3501 -s 10.0.0.0/8 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 3501 -s 172.16.0.0/12 -j ACCEPT

# Port 9000 (fula-gateway)
iptables -A "$CHAIN" -p tcp --dport 9000 -s 192.168.0.0/16 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 9000 -s 10.0.0.0/8 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 9000 -s 172.16.0.0/12 -j ACCEPT
```

---

## 9. Runtime File System Layout (on Blox)

```
/home/pi/.internal/
├── box_props.json                      # Pairing credentials (read by both services)
│   ├── auto_pin_token                  # JWT for remote pinning service
│   ├── auto_pin_endpoint               # Remote pinning service URL
│   └── auto_pin_pairing_secret         # Bearer secret for local HTTP APIs
├── fula-gateway/
│   └── registry.cid                    # Bucket registry CID (written by fula-pinning, read by fula-gateway)
└── ipfs_data/                          # Kubo's IPFS repository
```

---

## 10. End-to-End Data Flow Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          FxFiles Mobile App                              │
│                                                                          │
│  ┌─────────────┐  ┌───────────────┐  ┌──────────────────────┐          │
│  │ SyncService  │  │ FulaApiService│  │ BloxDiscoveryService │          │
│  │ (queue mgr)  │→ │ (S3 client)   │  │ (mDNS scanner)       │          │
│  └─────────────┘  └───────┬───────┘  └──────────┬───────────┘          │
│                           │                      │                       │
│                    fula_client FFI          mDNS: _fulatower._tcp        │
│                 (AES-256-GCM encrypt)            │                       │
│                           │                      │                       │
└───────────────────────────┼──────────────────────┼───────────────────────┘
                            │                      │
              ┌─────────────┴──────────┐           │
              │                        │           │
              ▼                        ▼           ▼
   ┌─────────────────┐    ┌─────────────────────────────────────────────┐
   │  Cloud Gateway   │    │              FxBlox Device (LAN)            │
   │ s3.cloud.fx.land │    │                                             │
   │                   │    │  ┌──────────────┐   ┌──────────────────┐   │
   │  JWT auth         │    │  │ fula-gateway  │   │  fula-pinning    │   │
   │  Cloud Kubo       │    │  │ :9000 (S3)    │   │  :3501 (sync)    │   │
   │  Prolly Trees     │    │  │ Bearer auth   │   │  Bearer auth     │   │
   │                   │    │  │ Reads CIDs    │   │  Writes CIDs     │   │
   │  Pins to remote   │    │  │ from local    │   │  to local kubo   │   │
   │  pinning service  │    │  │ kubo          │   │                  │   │
   │                   │    │  └──────┬────────┘   └────────┬─────────┘   │
   │                   │    │         │                      │             │
   │                   │    │         ▼                      ▼             │
   │                   │    │  ┌──────────────────────────────────────┐   │
   │                   │    │  │         Local Kubo (:5001)            │   │
   │                   │    │  │    IPFS blocks pinned locally        │   │
   │                   │    │  └──────────────────────────────────────┘   │
   │                   │    │         ▲                                    │
   └─────────┬─────────┘    └─────────┼────────────────────────────────────┘
             │                        │
             │    IPFS P2P (Bitswap)  │
             └────────────────────────┘
```

---

## 11. Persistence & Crash Recovery

### Client Side (FxFiles)

| Store | Backend | Contents |
|-------|---------|----------|
| `sync_queue` | Hive box | Pending upload/download tasks (survives app restart) |
| `sync_states` | Hive box | Per-file sync status, etag, CID |
| `sync_mappings` | Hive box | Cloud-to-local file mappings (for reinstall) |
| `settings` | Hive box | General app settings |
| SecureStorage | Keychain/Keystore | Pairing secret, hardware ID, peer ID |

### Blox Side

| File | Written By | Read By | Contents |
|------|-----------|---------|----------|
| `box_props.json` | go-fula (pairing) | fula-pinning, fula-gateway | JWT, endpoint, pairing secret |
| `registry.cid` | fula-pinning | fula-gateway | Latest bucket registry CID |
| Kubo datastore | Kubo | fula-gateway | IPFS blocks (content-addressed) |

---

## 12. Monitoring & Health

- **readiness-check.py**: Monitors `fula_pinning` and `fula_gateway` containers; triggers `fula.service` restart if either stops
- **fula-gateway health**: `GET /healthz` (Docker HEALTHCHECK every 30s)
- **fula-pinning status**: `GET /api/v1/auto-pin/status` returns JSON with `paired`, `total_pinned`, `last_sync_at`, `next_sync_at`
- **Watchtower**: Both containers labeled for automatic image updates
