# Best-in-World Plan — LocalVault

Goal: take the working MVP (host+client LAN file cloud, Riverpod + go_router + shelf + SQLite) to best-in-world for its niche: private, offline-first, LAN-local cloud. All subagents MUST use opencode free models only.

## Assessment (from code read 2026-09-18)

- Working: host setup/dashboard (QR + 6-digit pairing, shelf :8484), client connect/files/transfers/trash/devices/storage/settings, blob store + SQLite meta, chunked upload + Range resume, Argon2id, token auth, image thumbs, drag-drop desktop-only.
- Gaps blocking best-in-world:
  1. Visual identity is generic seed-blue M3 defaults; welcome is icon + 2 buttons, no brand, no onboarding, no hero.
  2. Files UX is basic: no breadcrumbs, no file-type icons, no multi-select/bulk ops, search is a dialog, grid is fixed 3-col, no thumbnails in list, no storage meter inline.
  3. Common widgets minimal; no logo widget, no file-icon mapper, no shimmer/skeleton, empty states are icon-only.
  4. README is MVP-only: no badges, screenshots, feature matrix, roadmap, or contribution guide.
  5. Functional polish missing: no auto-refresh/polling, sort not persisted, no selection mode, no keyboard shortcuts groundwork.
- Out of scope for this wave (documented, not attempted): HTTPS/TLS, server isolate split, persistent transfer queue across restarts, versioning, realtime sync, Android host mode.

## TODOs

- [x] 1. Premium design system in `lib/app/theme.dart` — refined M3 color/typography/component themes, dark-mode polish, card/button/navigation/dialog/snackbar/divider themes — expect `flutter analyze` clean
- [x] 2. Welcome + brand overhaul (`lib/features/welcome/`, `lib/widgets/common.dart` logo/brand widgets) — hero card, feature highlights, responsive layout, offline-first messaging — expect widget tests pass
- [x] 3. Files experience upgrade (`lib/features/files/files_screen.dart`) — breadcrumbs, file-type icons + thumbnails, inline search bar + type filter chips, sort persistence, responsive grid/list, selection mode + bulk delete/move — expect widget tests pass
- [x] 4. Common UX polish (`lib/widgets/common.dart`, settings/storage/transfers touch-ups) — storage meter widget, skeleton loading, improved empty/error states, consistent spacing — expect `flutter analyze` clean
- [x] 5. Best-in-world README + verify + commit + push — badges, screenshots section, features matrix, architecture diagram (ASCII), roadmap, dev workflow, run `flutter test` + `flutter analyze`, commit and push to `origin/master` — expect push succeeds

## Final Verification Wave

- [x] F1. `flutter analyze` clean — expect zero issues
- [x] F2. `flutter test` passes — expect all tests pass
- [x] F3. UI review (welcome + files + theme load without errors via widget tests) — expect APPROVE
- [x] F4. GitHub push verified (`git status` clean, `git log` shows new commit, remote updated) + README renders — expect APPROVE

## Success Criteria

- `export PATH="$HOME/flutter/bin:$PATH" && flutter analyze` → no issues
- `export PATH="$HOME/flutter/bin:$PATH" && flutter test` → all pass
- `git status --short` → clean; `git log --oneline -3` shows best-in-world commit; `git ls-remote origin` reachable / push output success
