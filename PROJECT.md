# Project
Idea: LocalVault — A private local cloud storage app that turns any disk into your own cloud. No accounts, no subscriptions, no internet required. Files never leave your devices.
Platform: Flutter (Android, Windows, Linux, macOS, Raspberry Pi)

# Features (v2.2.0 — performance optimization wave)
1. LRU image cache with 50MB limit and automatic eviction
2. Request batcher for efficient API calls
3. HTTP connection pool for connection reuse
4. Memory optimizer with GC and stats
5. Sync status badges (synced/syncing/pending/error/offline)
6. Offline files manager with storage info
7. Conflict resolver with side-by-side comparison
8. Audit log viewer with filtering and search
9. Session manager showing all active devices
10. Security score indicator (0-100)

# Done criteria (loop stops when ALL true)
- All v2.2.0 features implemented and tested
- DESIGN.md system applied to every screen
- Build passes, no critical bugs
- flutter analyze clean
- All tests pass

# Loop instruction
Each run: read RESEARCH/*.md, pick highest-priority work, build it.
