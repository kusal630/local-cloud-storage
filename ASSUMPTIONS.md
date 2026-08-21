# Assumptions

## Platform Assumptions

1. **Flutter 3.47+ / Dart 3.13+** is required. The project uses Dart 3 features including pattern matching and records.

2. **Linux desktop builds** require `clang`, `cmake`, `ninja-build`, `pkg-config`, and `libgtk-3-dev`. These are not available without root access in this environment, so Linux desktop builds cannot be verified here.

3. **Android builds** require Android SDK 36 and Build Tools 28.0.3. The project is configured for Android but builds were not verified in this environment.

## Package Substitutions

4. **`sqlite3` (v3.x with hooks)** is used instead of the deprecated `sqlite3_flutter_libs` (v0.6.0+eol). The new `sqlite3` package bundles SQLite natively via Dart hooks, eliminating the need for the separate Flutter libs package.

5. **`cryptography` (pure Dart)** is used for Argon2id password hashing instead of a native C library. This ensures cross-platform compatibility without platform-specific build configuration, at the cost of slightly slower hashing (~1-2s per operation on mobile).

6. **`disk_space`** is used for disk space queries instead of platform-specific commands. It uses platform channels and may not work in all test environments.

7. **`desktop_drop`** is used for drag-and-drop file upload on desktop platforms.

8. **`mobile_scanner`** is used for QR code scanning. It requires camera permission on Android and may not work in headless test environments.

## Design Assumptions

9. **LAN-only HTTP** is acceptable for the MVP. HTTPS/TLS can be added later by adding certificate management to the shelf server and updating the client to accept custom certificates.

10. **Host Mode on Android** is optional and not implemented in this MVP. The host server runs on desktop platforms only.

11. **Transfer tasks are in-memory** and do not persist across app restarts. A future version could persist task state in SQLite.

12. **No real-time sync** between host and client. The client must refresh the file list to see new files uploaded by other clients.

13. **The server runs on a single isolate** (the main Dart isolate). For the MVP, this is acceptable because file operations are I/O-bound and the server handles one client at a time per request. A future version could use `shelf_io.serve` with a background isolate for better concurrency.

14. **Thumbnail generation** is only performed for image files and uses simple downscaling to 256px width. Video thumbnails and document previews are not included in the MVP.

15. **File deduplication** is based on SHA-256 checksum + file size. Two files with the same checksum and size share a single blob on disk.

16. **Soft delete** is recursive: deleting a folder marks all descendants as deleted. Restore is also recursive and auto-renames the top-level item if a name conflict exists.

17. **The unique name constraint** applies only to live (non-deleted) files within the same parent folder. This is enforced by a partial unique index in SQLite.

18. **Root folder** has a stable ID of "root" and cannot be renamed, moved, or deleted. It is auto-created during vault initialization.

19. **Pairing codes** are stored in memory only (not in the database). They expire after 5 minutes and are consumed on use.

20. **Rate limiting** is implemented as an in-memory sliding window per IP address (or device ID for pairing code issuance). It resets when the server restarts.

21. **The `image` package** is used for thumbnail generation. It may not support all image formats (e.g., HEIC, WebP without alpha).

22. **Disk space reporting** via `disk_space` returns values in bytes. On some platforms, the reported values may include system-reserved space.