# Project
Idea: LocalVault — A private local cloud storage app that turns any disk into your own cloud. No accounts, no subscriptions, no internet required. Files never leave your devices.
Platform: Flutter (Android, Windows, Linux, macOS, Raspberry Pi)

# Features (v2.1.0 — offline & sync wave)
1. Sync status badges (synced/syncing/pending/error/offline)
2. Sync progress indicator for bulk operations
3. Offline files manager with storage info
4. Conflict resolver with side-by-side comparison
5. Audit log viewer with filtering and search
6. Session manager showing all active devices
7. Security score indicator (0-100)
8. Lazy loading system for large file lists (1000+ items)
9. Batch operations bar for multi-select file management
10. Enhanced image viewer with pinch-to-zoom and controls

# Done criteria (loop stops when ALL true)
- All v2.1.0 features implemented and tested
- DESIGN.md system applied to every screen
- Build passes, no critical bugs
- flutter analyze clean
- All tests pass

# Loop instruction
Each run: read RESEARCH/*.md, pick highest-priority work, build it.
