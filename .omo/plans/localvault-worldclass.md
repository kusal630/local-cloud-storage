# LocalVault — Best-in-the-World Plan (UI + Product)

## Vision
Make LocalVault the best LAN-first private cloud: instant to start, delightful to browse,
honest about security, fast on big folders, and beautiful on phone + desktop.

## Audit summary (2026-09-18, direct code read)
- Theme: single seed color, duplicated light/dark, `Size(double.infinity,48)` buttons
  break desktop layouts, no dialog/snackbar/chip/progress/list-tile theming.
- Widgets: EmptyState/ErrorState plain, `formatBytes` stops at GB, no file-type icons,
  no reusable storage bar/section header/logo.
- Welcome: bare icon + 2 buttons, no value props, no trust/security note.
- Files: `_load()` in `didChangeDependencies` refires on every dependency change;
  no breadcrumb/back path, generic file icons, no date in subtitle, fixed 3-col grid,
  search is a raw dialog, sort has no visible state.
- Host setup: `TextEditingController(text:…)` created inside `build` (cursor jumps,
  state loss), no password visibility/strength, no steps.
- Host dashboard: `dynamic server/vault`, QR payload `localvault://http://…` is
  double-scheme, pairing regenerate has no countdown, `lastSeenAt.toString()` raw,
  storage rows are plain text, one crammed card.
- Client connect: fragile QR string replace, no LAN help, no validation, no history.
- Preview: download hardcodes `/tmp` (breaks Android/Win), full file loaded into
  memory as fallback (OOM risk), raw `DateTime.toString()`.
- Transfers: status says "Uploading…" even for downloads, no % display, square bars.
- Router: 6 bottom tabs crowd small phones; no error page.

## TODOs (P0 — implement now)
- [ ] T1 Design system: rewrite `lib/app/theme.dart` (expressive M3, component themes, responsive buttons, dialog/snackbar/chip/progress/list-tile/tabs, extensions)
- [ ] T2 Shared widgets: expand `lib/widgets/common.dart` (VaultFileIcon, StorageUsageBar, SectionHeader, AppLogo, formatBytes TB + formatDateTime, skeleton, status pill)
- [ ] T3 Welcome: premium hero + feature cards + trust note (`lib/features/welcome/welcome_screen.dart`)
- [ ] T4 Files: breadcrumbs + back, type icons, size•date subtitles, responsive grid, sort state, remove didChangeDependencies reload loop, polished search (`lib/features/files/files_screen.dart`)
- [ ] T5 Host setup: fix controllers (stateful), password visibility + strength, steps header (`lib/features/host_setup/host_setup_screen.dart`)
- [ ] T6 Host dashboard: typed card layout, status pill, QR card fix, storage bar, device list polish (`lib/features/host_dashboard/host_dashboard_screen.dart`)
- [ ] T7 Client connect: steps header + LAN help + validation + error card (`lib/features/client_connect/client_connect_screen.dart`)
- [ ] T8 Transfers + Storage + Preview polish (labels, % rounded bars, formatted dates, picker-based download) (`transfers_screen.dart`, `storage_screen.dart`, `preview_screen.dart`)
- [ ] T9 README + DESIGN docs update

## P1 (next, documented not built)
- mDNS/LAN auto-discovery, TLS with self-signed cert + trust flow
- Favorites/star + Recent (DB columns + filters)
- Persistent transfer queue (SQLite) + speed/ETA + pause/resume
- Multi-select batch ops, grid/list + sort persistence (shared_preferences)
- Video/PDF thumbnails, per-type storage breakdown, quota per device
- Biometric/app lock, audit log, trash retention policy

## Success criteria
- `flutter analyze` zero new issues; `flutter test` passes
- No `TextEditingController(text:)` inside build; no hardcoded `/tmp`; no double-scheme QR
- Responsive: phones (1-2 col) → tablets (3-4) → desktop (5-6) grids; buttons not forced full-width on desktop
- README documents new UI + how to run + security notes

## Final Verification Wave
- [ ] F1 Analyze + tests pass
- [ ] F2 UI consistency (theme/widgets/screens share same language)
- [ ] F3 No regressions (routes, pairing, CRUD flows intact)
- [ ] F4 README/DESIGN accurate
