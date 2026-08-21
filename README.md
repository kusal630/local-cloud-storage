# LocalVault

A cross-platform local cloud storage application that turns local storage (external SSD, pen drive, SD card, or folder) into a private local cloud. No internet access required — all data stays on your devices.

## Architecture

```
lib/
  app/           – Theme, router, providers, root widget
  core/          – Constants, errors, logging, utilities
  data/          – SQLite database, models, repositories
  server/        – Host Mode shelf HTTP server
  client/        – Client Mode Dio HTTP client
  features/      – UI screens (welcome, host, client, files, etc.)
  widgets/       – Shared UI components
```

### Key Technologies
- **Flutter** – Cross-platform UI framework
- **Riverpod** – State management
- **go_router** – Declarative routing
- **shelf** – HTTP server (Host Mode)
- **Dio** – HTTP client (Client Mode)
- **SQLite** – Local metadata storage
- **Argon2id** – Password hashing (pure Dart via `cryptography` package)
- **Material 3** – Design system

## How to Run

### Prerequisites
- Flutter 3.47+ / Dart 3.13+
- For Android: Android SDK 36, Build Tools 28.0.3
- For Linux desktop: clang, cmake, ninja, GTK 3.0 dev, pkg-config
- For Windows: Visual Studio with C++ desktop workload
- For macOS: Xcode 14+

### Android
```bash
flutter build apk --release
# or
flutter build appbundle --release
```
Install the APK on your Android device.

### Linux
```bash
flutter build linux --release
# Output: build/linux/x64/release/bundle/
```

### Windows
```bash
flutter build windows --release
# Output: build/windows/x64/runner/Release/
```

### macOS
```bash
flutter build macos --release
# Output: build/macos/Build/Products/Release/
```

### Development
```bash
flutter run                    # Run on connected device
flutter run -d linux           # Run on Linux desktop
flutter test                   # Run unit + widget tests
flutter analyze                # Static analysis
```

## How It Works

1. **Host Mode** (desktop): User selects a storage folder. The app creates `.localvault/` with a SQLite database and blob directories. A local HTTP server starts on port 8484. The host displays a QR code and 6-digit pairing code.

2. **Client Mode** (Android/desktop): User scans the QR code or enters the server URL + pairing code. The client obtains an access/refresh token pair and can browse, upload, download, rename, move, delete files.

3. **File Storage**: File bytes are stored under `.localvault/blobs/<xx>/<yy>/<uuid>`. Metadata (names, parent folders, sizes, checksums) lives in SQLite. Rename and move operations update only the database — no file copies needed.

4. **Transfer Manager**: Uploads use chunked transfer with SHA-256 verification. Downloads support HTTP Range for resume. Progress is reported to the UI in real time.

## Security Notes

- All traffic is HTTP (unencrypted) on the local network. This is acceptable for LAN-only use but a clear warning is shown in the UI. HTTPS/TLS support can be added later.
- Passwords are hashed with Argon2id (64 MiB memory, 3 iterations).
- Tokens are 256-bit random values; only SHA-256 hashes are stored in the database.
- Access tokens expire after 15 minutes; refresh tokens after 30 days.
- Pairing codes are 6-digit, expire after 5 minutes, and are rate-limited.
- File names are sanitized to prevent path traversal and injection attacks.
- The server binds only to the local network interface (0.0.0.0).
- The server does not implement port forwarding or public internet exposure.

## Known Limitations

- No HTTPS/TLS encryption on the wire (LAN-only HTTP).
- Android Host Mode is optional and not included in the MVP.
- Transfer tasks are in-memory; they do not survive app restarts.
- No file versioning or deduplication beyond blob reuse.
- No real-time sync — client must refresh to see new files.
- Thumbnail generation is image-only and uses simple downscaling.
- Disk space detection uses platform-specific commands (df/wmic) which may not work in all environments.
- Host server runs on the main isolate; very heavy concurrent operations could impact UI responsiveness.
- Drag-and-drop upload is desktop-only.