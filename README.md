# LocalVault — Your Private Local Cloud

> Turn any disk into your own cloud. No accounts, no subscriptions, no internet
> required. Your files never leave your devices.

LocalVault makes a folder, SSD, pen drive, SD card — or a whole Raspberry Pi —
act like Dropbox, except the "cloud" is hardware you own. One device hosts
(**Storage Node**); every other device connects as a **Client** to browse,
upload, download, share, and back up.

## 📱 Download

- **Android**: [Releases → latest APK](https://github.com/kusal630/local-cloud-storage/releases)
  (open on the phone → allow “Install unknown apps” → install)
- **Windows / Linux / macOS**: build from source (5 minutes, see below)

## What you can do with it (v1.3.0 research wave)

- **Tags**: label files/folders, filter the whole vault by tag (Nextcloud-style)
- **Comments + per-file activity** on every preview
- **File requests**: links that let anyone *upload into* a folder (password + expiry)
- **Folder download as ZIP** (2 GB / 2000-file cap, streamed)
- **Duplicate finder** with one-tap cleanup of wasted bytes
- **Offline files**: pin files locally, badge + filter, works without the host
- **New notes** and **share-sheet uploads** from any Android app
- **Biometric unlock** + PIN, **known-device badges** on Nearby nodes
- **Staggered version pruning** (hourly → daily → weekly, like Syncthing)
- **Backup ignore patterns** (`*.tmp`, `Screenshots`) Syncthing-style

## What you can do with it

| Use | How |
|---|---|
| **Family cloud on an old phone** | Host on the always-on phone, everyone connects with username + password |
| **Raspberry Pi home server** | `pi/install.sh` builds an always-on node on your Pi (see below) |
| **Camera backup** | Client → Settings → Auto Backup watches folders and uploads new photos to `Auto Backup/<device>`, skipping what is already there |
| **Share a file** | Long-press → Share link → expiring URL with optional password (`https://…/s/<token>`) |
| **Version safety** | Re-uploading a file archives the old content; restore any version from Preview |
| **Scripts & automation** | Host Dashboard → New API token gives a long-lived token for `curl`/cron jobs |
| **Offline media** | Host on a laptop on a trip; phones stream/download over the hotspot, no internet needed |

## Quick start (2 minutes)

**1. Start a Storage Node** (phone, PC, or Pi)
- Welcome → **Start Storage Node** → pick the folder/drive to use as cloud
- Choose a **username + password** → Start
- On Android the node keeps running in the background (foreground service)

**2. Connect**
- On another device: **Connect to Storage Node**
- Either scan the QR (certificate is pinned automatically) or enter the URL +
  pairing code — or log in with username + password
- First manual HTTPS connection asks you to confirm the TLS fingerprint —
  compare it with Host Dashboard → Pairing → TLS fingerprint

**3. Use it like a cloud**
- Files: breadcrumbs, search across the whole vault, Starred/Recent filters,
  grid/list, sort, bulk select, drag & drop (desktop), shortcuts
  (`Ctrl+R` refresh, `Ctrl+Shift+N` folder, `/` search)
- Preview images, read text/code notes, restore old versions
- Transfers survive app restarts, show speed/ETA, and downloads are
  checksum-verified

## Run it on every platform

| Platform | Host | Client | Notes |
|---|---|---|---|
| **Android** | ✅ (foreground service, always-on) | ✅ | Storage defaults to app external dir (SD-card friendly) |
| **Windows** | ✅ | ✅ | `flutter build windows --release` → `build\windows\x64\runner\Release\` |
| **Linux** | ✅ | ✅ | Needs `clang cmake ninja-build pkg-config libgtk-3-dev`; `flutter build linux --release` |
| **macOS** | ✅ | ✅ | Xcode 14+; `flutter build macos --release` |
| **Raspberry Pi** | ✅ (headless via `pi/install.sh`) | — | Pi OS 64-bit, see below |

Disk space, thumbnails, and drag & drop work per-platform; where a platform
API is missing the UI degrades to a clear message instead of crashing.

### Raspberry Pi home server

```bash
git clone https://github.com/kusal630/local-cloud-storage.git
cd local-cloud-storage
STORAGE=/mnt/cloud PASS='a-strong-password' ./pi/install.sh
# optional: USERNAME=owner NAME='Pi Cloud' PORT=8484
```

This installs deps + Flutter, builds the ARM64 release with your storage baked
in, and enables a systemd service (`localvault`) that starts on boot through
Xvfb (no monitor needed). Then `hostname -I` for the IP and connect from your
phone with `https://<pi-ip>:8484`.

## Access from anywhere

Any network route to the node works: same Wi-Fi, phone hotspot, or a VPN such
as Tailscale/ZeroTier on both devices (closest to real-cloud UX). Without a
VPN, port-forward the server port to the node on your router. Mobile networks
use carrier NAT, so inbound connections from the raw internet need that
forward — the app never pretends otherwise.

## Security model

- **Encrypted by default**: every node serves **HTTPS** with a per-vault
  self-signed certificate (generated on first start, RSA-2048, 825 days).
  Clients **pin the certificate fingerprint** (QR or verify-on-first-use) —
  LAN eavesdroppers and impersonators get nothing. Plain HTTP exists only if
  you deliberately clear both TLS paths in Host Settings.
- **Passwords**: Argon2id (64 MiB, 3 iterations); only hashes stored.
- **Tokens**: 256-bit `Random.secure`, only SHA-256 hashes in SQLite;
  15-minute access / 30-day refresh with rotation; expiry enforced on every
  request; rate-limited pairing + login; the host device entry can't be
  revoked out from under you.
- **Storage**: vault dir locked to owner-only permissions (`0700`) where the
  OS supports it; file names sanitized (no path traversal); uploads verified
  by SHA-256 before they land; downloads re-verified on the client.
- **Shares**: unguessable 256-bit tokens (hashes only in DB), optional expiry
  and Argon2id passwords, ticketed content URLs, download counting, one-tap
  revoke. **API tokens**: long-lived, shown once, revocable like devices.
- **App**: optional PIN lock; tokens in the platform keystore.

## How it stores things

- `<storage>/.localvault/` holds `db.sqlite` (metadata, users, versions,
  audit, shares) plus content-addressed blobs (`blobs/…`), thumbnails, and
  the TLS identity (`tls/`). Rename/move/version operations touch only the
  database — bytes are deduplicated by checksum + size.
- Trash with configurable retention auto-purge, per-vault quota, per-type
  storage breakdown, and a host activity log are built in.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Phone can't find the node | Same Wi-Fi? Host running? Try the IP URL manually; check Nearby needs UDP broadcast allowed |
| Certificate warning on manual connect | Compare the fingerprint with the dashboard, then Trust & connect |
| Backup finds nothing on Android | Pick the folder via the picker (grants access), grant media/files permission when asked |
| Node stops overnight (Android) | Exempt LocalVault from battery optimization so the foreground service survives |
| Pi service won't start | `systemctl --user status localvault`; ensure `STORAGE` path is mounted before boot (fstab) |
| Port busy | The node auto-tries the next free port and shows it on the dashboard |

## Develop

```bash
flutter pub get
flutter analyze        # must be clean
flutter test           # unit + widget + integration (SQLite, server, isolate runner)
flutter run -d linux   # desktop
flutter build apk --release   # Android → build/app/outputs/flutter-apk/
```

## Experience design (why it feels fast)

LocalVault is designed around how people actually perceive software:

- **Instant feedback** — stars, comments, and uploads acknowledge the tap
  immediately (optimistic UI with rollback); haptics confirm what fingers do
- **No dead ends** — deletes are undoable, trash states its safety window,
  errors name the fix and offer Retry, offline mode says so honestly
- **Thumb-first** — 5 bottom tabs, bottom sheets, FAB, swipe-to-star/delete
  with button fallbacks; destructive actions live away from thumbs
- **Recency language** — lists speak in "2h ago", details keep exact dates
- **Trust is visible** — the host Security scorecard, pinned-certificate
  flow, and checksum "verified" badges show the safety instead of claiming it
- **Progressive onboarding** — a 10-second intro once, then features teach
  themselves through empty states and contextual hints

Architecture: `lib/app` (theme/router) · `lib/server` (shelf API on a
background isolate) · `lib/data` (SQLite + repositories) · `lib/client`
(Dio services, transfers, backup) · `lib/features` (screens) ·
`lib/core` (auth crypto, discovery, disk, lock). See `DESIGN.md` for the
design language and `TEST_PLAN.md` for manual test cases.

## Current status (honest)

- Video/PDF/Office thumbnails are not generated (images + text/code previews are).
- Auto Backup runs while the app is open (Android background WorkManager sync is future work).
- Raw SD-card paths on Android are limited by scoped storage — the app
  external dir and picker-chosen folders work everywhere.
- True internet exposure needs your VPN/port-forward (see above); there is no
  relay server, by design.
