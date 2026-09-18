# DESIGN.md — LocalVault Design Language

## Identity
- Seed: deep teal `#0E7C7B` (private-vault feel, distinct from generic blue).
- Shape: 12px inputs/buttons, 16px cards, 24px top sheets, 28px search.
- Type: M3 `englishLike2021`, headlineLarge 800/-0.5 for brand, titleSmall 700 for sections.

## Components
- `AppLogo`: gradient tile (primary→tertiary) + soft shadow, `cloud_off` glyph.
- `SectionHeader`: uppercase-ish titleSmall + optional action.
- `VaultFileIcon`: folder (primary) / image (violet) / video (magenta) / audio (cyan) /
  pdf (red) / archive (orange) / docs (tertiary) / sheets (green) / apps (secondary) /
  fallback (surface tint). 16% bg tint, 30% radius.
- `StorageMeter`: 10px rounded bar + used/free labels.
- `SkeletonList`: 6 shimmer-less placeholder rows for first paint.
- `StatusPill`: dot + bold label, tinted bg + border.
- `EmptyState`/`ErrorState`: circled icon tile, centered copy, optional action.

## Screens
- Welcome: max-width 560, logo → name → tagline → LAN pill → action card →
  3 feature rows → LAN explainer footer.
- Files: AppBar (back/selection/sort/view) → breadcrumbs (ActionChips) →
  SearchBar → FilterChips → list (Card+ListTile, VaultFileIcon, size•date) or
  responsive grid (2/3/4/5/6 cols by width) → FAB.extended "New".
- Host setup: max-width 560, step headers, storage card, name/password fields,
  strength meter, error card, rocket CTA, `.localvault` explainer.
- Host dashboard: max-width 640, status pills row, CONNECT / DEVICES / STORAGE cards.
- Client connect: max-width 560, STEP 1 scan + STEP 2 code, validation, last-URL memory.
- Transfers: type icon, rounded bar, `x / y • n%`, Up/Download-aware label.
- Storage/Preview: shared meters, formatted dates (`Today HH:MM` / `12 Sep 2026, 14:30`),
  copyable checksum, picker-based download.

## Rules
- Never force `Size(double.infinity, …)` on buttons — constrains desktop.
- One component-theme builder for light+dark; no duplicated literals.
- `formatBytes` to TB; `formatDateTime` human; QR payload `localvault://host:port` (no scheme).
- Controllers live in State.initState, never inside build.
