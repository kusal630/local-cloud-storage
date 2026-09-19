# Project
Idea: LocalVault — A private local cloud storage app that turns any disk into your own cloud. No accounts, no subscriptions, no internet required. Files never leave your devices.
Platform: Flutter (Android, Windows, Linux, macOS, Raspberry Pi)

# Features (v1.7.0 — best-in-world wave)
1. Premium Material 3 design system with dark mode polish
2. Enhanced lock screen with animated security UX
3. Storage donut visualization for instant capacity scan
4. Better typography and visual hierarchy across all screens
5. Improved button sizing and layout consistency
6. Rate limiting on all auth endpoints (login, pairing, refresh)
7. Argon2id memory upgraded to 64 MiB (matching documented spec)
8. Version display fixed across all screens
9. Improved error messages with retry guidance
10. Better empty states and loading indicators

# Done criteria (loop stops when ALL true)
- All v1.7.0 features implemented and tested
- DESIGN.md system applied to every screen
- Build passes, no critical bugs
- flutter analyze clean
- All tests pass

# Loop instruction
Each run: read RESEARCH/*.md, pick highest-priority work, build it.
