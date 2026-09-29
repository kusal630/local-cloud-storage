# RESEARCH/UX_BENCHMARK.md — benchmarking LocalVault against best-in-class storage UIs

Scope: what the strongest storage/quota products and pro self-hosted UIs actually put on screen,
what is genuinely available in Flutter stable for Material 3 Expressive, and a ranked backlog for
LocalVault (Flutter, Android-first, `#0E7C7B` seed, glassmorphism, AMOLED, haptics). Companion to
`RESEARCH/DESIGN.md` (pool widget spec) — sentence case, no marketing. Research date: 28 Sep 2026.

Method: ~35 web searches and full fetches of the substantive pages (vendor help docs, TrueNAS/Unraid
docs, Material spec, Google research, NN/g, Flutter source + API docs). Sites that blocked us and
therefore are **not** cited as evidence: Synology DSM help (JS shell only), QNAP (403), Trustpilot
(403), Reddit threads (no content returned), W3C WCAG page (403). Where evidence was thin —
pCloud, IDrive, Backblaze, Jellyfin — this document says so rather than inventing findings.

---

## What the best do

### One number, many sources

| # | Product | What it actually does (evidence) | How we'd apply it |
|---|---|---|---|
| 1 | **Google One storage manager** | First screen = % used **plus** raw used/capacity numbers, one segmented bar for Drive + Gmail + Photos, then a legend where each service repeats its own number, then a "Get your space back" card with per-category **Review** links, sorted largest-first (filerev.com walk-through, support.google.com/drive/answer/6374270). | Donut + legend already matches; add the missing third beat: a **"Free up space"** card under the legend whose rows deep-link to Trash, duplicates and largest files. |
| 2 | **Google One (M3 Expressive refresh)** | The redesign *removed* infographics for a denser app, put cards into prominent containers, shortened the bottom bar; cleanup panes got smaller thumbs, single-row filter chips and an encouragement card up top (9to5google.com tracker, androidauthority.com). | Drop any decorative chart that doesn't change a decision; keep exactly one hero viz. Denser cards > airy KPI tiles. |
| 3 | **Dropbox plan/storage** | The bar splits into `Regular files / Shared files / Unused space / Backup / Replay`; the cleanup tool filters by **Largest** or **Last activity**; a team storage widget appears in the sidebar **only once the team passes 50%** (help.dropbox.com/storage-space/account-space-left). | Surface pool capacity on the Files tab only after ~50% used (quiet when healthy, loud when it matters), and offer "largest / least recently used" filters in cleanup. |
| 4 | **iCloud+ storage** | Bar graph at the top, list of categories **sorted by usage descending** underneath; on small screens it collapses to the three largest categories plus **"Others"** (support.apple.com guide). | Sort contributors by share descending, pin "This device", and collapse the tail (`3 more devices · 8 GB`) on narrow widths. |
| 5 | **Google "account is full"** | Recovery is ordered **short-term first** ("empty trash — fastest way to recover space") then long-term (clear or buy), and it spells the cross-service consequence ("can't upload, can't send mail") (support.google.com/drive/answer/6374270). | Our full-pool banner should lead with the fastest fix (empty trash / raise a contributor's quota) as *buttons*, not as prose. |
| 6 | **Google One — the number-accuracy complaint** | The most-reported Storage Manager problem is a quota that doesn't reconcile: trash, spam and hidden app data keep counting after "delete" (filerev.com). | Every total must be inspectable: tap the hero number → sheet listing quota per contributor, trash, replica overhead, reserved. |
| 7 | **TrueNAS SCALE storage dashboard** | Per pool: four widgets — Topology, Usage, ZFS Health, Disk Health. Usage = donut with **blue 0–80%, red >80% and a warning line under the donut**; every widget header carries a color-coded status glyph (green check / orange triangle / purple warning) repeated on the dashboard card; Disk Health shows temps + failed SMART; empty state = "No Pools" with a centered **Create Pool** button (truenas.com SCALE docs, 22.12 + 23.10). | Graded thresholds (80% turns amber *before* it's a crisis), a warning sentence under the ring, one status glyph language reused on every card. |
| 8 | **Unraid WebGUI** | Dashboard = grid of tiles (CPU/RAM/storage/network/containers), Main shows per-disk health + capacity + filesystem, and a persistent bottom **status bar** always shows array state and running operations (Mover, parity check) (docs.unraid.net WebGUI tour). | A persistent, non-modal strip for active uploads/pool repair above the NavigationBar — state never hides behind a tab. |
| 9 | **TrueNAS destructive flows** | Export/Disconnect requires ticking "destroy data", a type-the-pool-name confirmation, then a progress window and a completion dialog (truenas.com). | Revoke/promote: consequence spelled out (DESIGN §6), typed or explicitly acknowledged confirmation for revoke, progress → completion. |
| 10 | **Immich (polish, and its critics)** | Community filed a design rework thread specifically about **true-black `#000000` OLED smearing** while scrolling; a maintainer acknowledged Flutter's default dark is `#303030` and that Immich's contrast "is quite a bit" (github.com/immich-app/immich discussion #1898). An automated design review scored it 80–98 but called out **silent failures**: wrong passwords and broken fetches fail quietly (rams.ai). | AMOLED: keep `#000` behind static hero surfaces, use `#0A0A0A` under scrolling lists. Never fail quietly — every async failure lands in `ErrorState` with a cause. |
| 11 | **IDrive / pCloud / Backblaze / Jellyfin** | IDrive's console is admin/Reports-first (Users, Computers, Settings, Reports — idrive.com/dashboard-faq), i.e. tables over hero numbers; we found no substantive, fetchable documentation of pCloud's, Backblaze Personal's or Jellyfin's storage/quota first screen. | Treat IDrive as the "when it's fleet management, use tables" counter-example; nothing else claimed here. |

### Loading, feedback and calm

- **NN/g, Skeleton Screens 101** (nngroup.com/articles/skeleton-screens/): skeletons are for **full-page**
  loads under ~10s; spinners are fine for a **single module**; **progress bars** for anything >10s or any
  task-like process (upload/convert); show **nothing** if the page resolves in <1s; **never** use a
  frame-only skeleton (header + empty background) — it reads as broken; animated shimmer can itself be an
  accessibility problem. *Apply:* pool/storage first-paint skeletons are correct (pool_screen `_skeleton()`);
  transfer progress must stay determinate with ETA (already true); the shimmer must switch off under
  reduced motion (currently it doesn't — see backlog).
- **Optimistic UI** (simonhearne.com/2021/optimistic-ui-patterns/): decouple feedback from the network,
  aim for **<100ms** visible response; animate on gesture, run the request in parallel, queue and retry,
  and only roll the UI back after repeated failure. *Apply:* quota slider, revoke, star/pin, restore.
- **Designing calm** (uxmatters.com, May 2025): micro-anxieties come from *unexplained* delays ("spinner
  with no status update"), ambiguous labels (`Submit`, `Continue`), inconsistent hierarchy and missing
  confirmation; forgiving interactions (undo, non-destructive defaults) beat tutorials; tone of voice
  should guide, not scold (`Error 409` vs "Couldn't save — another sync is in progress").
- **Empty states** (pencilandpaper.io/articles/empty-states): anatomy = informative copy + visual + one
  action; distinguish *information*, *action* and *celebration* states; "no results" must never be a dead
  end — offer the next best thing; empty containers are a legitimate onboarding surface.
- **Google's own expressive research** (design.google/library/expressive-material-design-google-research):
  46 studies, 18,000+ participants; expressive layouts made key elements findable **up to 4× faster** and
  erased the age gap in fixation time — **but only when familiar paradigms and text labels were kept**
  (an unlabeled helter-skelter playlist scored worse), and a "strong minority" still prefers calmer
  versions. *Apply:* bigger, clearer primary actions are evidence-backed; removing labels from donut
  segments is not.

### Accessibility of data visualisation

- **IBM Carbon** (medium.com/carbondesign/…data-visualization): WCAG **1.4.11 non-text contrast = 3:1**
  against the background; a categorical palette must be *differentiated* (colorblind-optimized),
  *diverse* (no false associations) and *sequenced* (works from 2 to 14 categories); when low-contrast
  colors are unavoidable inside a chart, add **color-agnostic cues**: axes/outlines at 3:1, 1px caps on
  bar tops, divider strokes in the background color. Legends that filter/isolate a series can break a
  pair that only worked because the neighbors touched. *Apply:* our 6 segment colors already clear 3:1;
  the missing redundancy is caps/outline and non-color status encoding (see backlog).
- **Never hue alone**: pair every color with a glyph or text (TrueNAS status glyph next to every widget
  header is the model).
- **Flutter facts verified against stable 3.47.5 source/API docs** (use these, not blog guesses):
  - `Semantics(role: …)` exists, with `SemanticsRole` from `dart:ui` (`status`, `alert`, `list`,
    `listItem`, `table`, `cell`, `columnHeader`, `progressBar`, …).
  - `SemanticsService.announce(...)` is **deprecated after v3.35** — use
    `SemanticsService.sendAnnouncement(View.of(context), message, direction)`; guard with
    `MediaQuery.supportsAnnounceOf(context)`.
  - `MediaQuery.disableAnimationsOf(context)` exists (prefer over reading `MediaQuery.disableAnimations`).
  - `MediaQuery.textScalerOf(context)` exists; ~25% of phone users enlarge text.
  - `ThemeData(useSystemColors: true)` exists (forced-colors/high-contrast on web/Windows).
  - `HapticFeedback.successNotification() / warningNotification() / errorNotification()` exist alongside
    `lightImpact/mediumImpact/heavyImpact/selectionClick`.
  - Pull-to-refresh: only `RefreshIndicator` / `RefreshProgressIndicator` (Material) and
    `CupertinoSliverRefreshControl` — **there is no `PullToRefresh` widget in stable**.

---

## Material 3 Expressive — applies to us

**The headline: M3 Expressive is not in Flutter.** Verified three ways:

1. m3.material.io/develop/flutter states verbatim: *"Flutter supports original M3 components.
   **M3 Expressive is not available on Flutter.**"*
2. The official motion page's availability table lists **Flutter: Unavailable** for the motion physics
   system (Compose: available; Android Views: partially; Web: compatible with Compose springs).
3. flutter/flutter#168813 (umbrella issue): Flutter is *"not actively developing Material 3 Expressive
   … and will not be accepting contributions for these features"*, and Material has since been
   decoupled into the standalone **`material_ui`** package where M3E work will land.

### Not available in Flutter stable 3.47.5 — do not code against these

| Compose / spec name | Status in stable (checked `flutter/material` source + `material_ui` API index) |
|---|---|
| `MotionScheme` (expressive/standard springs, `md.sys.motion.spring.*`) | **Absent.** Motion library only has `Durations` and `Easing` token classes. |
| `HorizontalDivider` | **Absent** — only `Divider` and `VerticalDivider`. Use `Divider()` or `SizedBox(height: 1)`. |
| FAB menu (`FloatingActionButtonMenu`) | **Absent**; no `FloatingActionButton.menu` either. Nearest thing: `MenuAnchor` + a regular FAB. |
| Split button, button groups, M3E "loading indicator" | **Absent.** |
| Button "emphasis levels" (`ButtonLevel`) | **Absent.** Emphasis = choosing among `FilledButton` / `FilledButton.tonal` / `OutlinedButton` / `TextButton`. |
| `PullToRefresh` widget | **Absent** (see above). |
| `StyleVariant.material3Expressive` | **Exists in `material_ui`** but the enum docs say *"Material 3 Expressive support is under development"*, and I found no `ThemeData` property that accepts it. Not usable today. |

### Available and verified — safe to use now

- `IconButton.filled` / `.filledTonal` / `.outlined`; `FloatingActionButton.small` / `.large` /
  `.extended` (`.medium` not found in stable source).
- `SegmentedButton`, `MenuAnchor`, `RefreshIndicator`, `RefreshProgressIndicator`, `CarouselView`,
  `Badge`, `DropdownMenu`.
- `ThemeData(useSystemColors: true)` for system high-contrast.
- `flutter/physics` (`SpringSimulation`) if we want springy motion by hand — framework API, **not** a
  Material token set; keep our existing `Curves` durations rather than inventing a motion system.

### What to take from Expressive anyway (design tactics, not APIs)

These are the parts that shipped in Google's own apps and need no new widgets:

- **Containment over cards-in-space**: group list rows into visible containers (Gmail/Drive/Messages
  redesign), pill-shaped action groups, containerized settings rows.
- **Emphasis by size + placement + color**, not by adding a fifth KPI: Google's research found the
  enlarged, recolored Send button was spotted 4× faster.
- **Thicker, fewer charts**: Digital Wellbeing's donut simply got **thicker**; Google One deleted its
  infographics. Our `strokeWidth 16` hero ring is already on the right side of this.
- **Shorter bottom bar**, larger hit targets, single-row filter chips, search app bar (every M3E app in
  the 9to5google tracker did this).
- **Refresh as a moment**: Google Photos shows cycling M3E shapes + "how much you have stored" behind
  pull-to-refresh, and a wavy indicator while backing up — refresh feedback can carry state.
- **Hand-rolled "expressive" motion is fine within our design language**: count-up easeOutExpo, ring
  sweep, arc re-balance (DESIGN §8) already read as one coherent motion family. Don't mix in bounce
  springs — overshoot is the one M3E trait our calm/AMOLED language should skip.

### Third-party option (flagged, not recommended)

`material_3_expressive` on pub.dev implements 44 M3E widgets (FAB menu, split buttons, spring press
feedback, emphasized type scale). Caveat: it requires Flutter ≥3.47 and importing
`package:material_ui/material_ui.dart` **instead of** `package:flutter/material.dart` — a repo-wide
import migration with a compatibility bridge. Treat as an experiment, not a dependency.

---

## Anti-patterns to avoid

1. **A total nobody can reconcile** — quota complaints are dominated by "the number is wrong" (trash,
   replicas, hidden data still counted). Fix: inspectable breakdown sheet.
2. **Binary warning at the brink** — our storage banner fires only at `usedFraction >= 0.9`. TrueNAS
   warns at 80% with a line under the donut; Dropbox surfaces a widget at 50%. Graded thresholds.
3. **A full-state banner with no action** — the current `storage_screen.dart` full card is icon + text
   only. Google's model puts the fastest fix in the first button.
4. **Silent failures** — an async error that only logs, or a stale number that keeps showing without an
   age. Both read as "broken" (Immich criticism; calm-design article: silence is ambiguous).
5. **Colour as the only encoding** — Carbon: 3:1 min for chart elements, plus glyphs/text; a legend
   that isolates a series can expose a low-contrast pair.
6. **Decorative visualisation** — any chart that doesn't change what the user does (Google One removed
   infographics; DESIGN §1 Ceph rule).
7. **Pure `#000` under scrolling lists** — OLED smearing complaint filed against Immich's exact choice.
   Keep true black for the static hero only.
8. **Skeleton misuse** — frame-only skeletons, skeletons for <1s loads, skeletons for upload tasks
   (use a determinate bar), shimmer while reduced-motion is on.
9. **Animating on every poll tick** — re-run count-up/ring only when Δ ≥ 0.5% (DESIGN §8); never
   haptic on passive refresh.
10. **Hardcoded type sizes** — 27 `fontSize:` literals in `lib/`, zero `textScaler` handling; breaks at
    1.3× system text and with `TabularFigures` alignment.
11. **Icon-only controls without a label** — 37 `IconButton(` vs 29 `tooltip:` occurrences; audit the
    gap, and give every one a `tooltip`.
12. **Scolding or technical microcopy** — `Error 409`, "node", "quota violation". DESIGN §10 word list
    (`device`, `offline`, `joining`) plus a next-step verb.
13. **Confirmations without consequence** — "Are you sure?" beats nothing; TrueNAS requires typing the
    pool name for destroy.
14. **Upsell-first storage screens** — cloud-storage reviews are dominated by subscription-trap and
    scare-notification resentment (FTC has a public alert about fake "your storage is full" messages).
    We're self-hosted: capacity advice must be neutral, never nagging.
15. **Dated M3 habits**: `BottomAppBar` (Expressive deprecates it in favour of toolbars — we don't use
    it), dense multi-donut "infographic" dashboards, tiny text-only primary actions, card grids where a
    single list would do.

---

## Ranked backlog

Impact: **H**igh / **M**ed / **L**ow · Effort: **S** (<½ day) / **M** (1–2 days) / **L** (3+ days).
Ordered by impact ÷ effort (H=3, M=2, L=1; S=1, M=2, L=3).

| # | Impact × Effort | Score | Change (screen / widget) | Why it improves UX |
|---|---|---|---|---|
| 1 | H × S | 3.0 | **Add two actions to the storage-full card** in `lib/features/storage/storage_screen.dart` (the `usedFraction >= 0.9` Card): `FilledButton('Free up space')` → Trash, `TextButton('Raise quota')` → quota sheet. Keep existing copy. | Google's full-account flow leads with the fastest fix; a warning with no verb forces the user to hunt (calm-design: unexplained states create anxiety). |
| 2 | H × S | 3.0 | **Graded thresholds** on `storage_screen.dart` + `lib/widgets/pool_capacity_card.dart`: at ≥0.75 amber hero number, ≥0.85 amber ring + one-line warning under the donut, ≥0.90 the existing error card. Colour the *number*, not a new tile. | TrueNAS turns red at 80% with a warning line; a single 90% cliff gives no time to act. Reading a signal beats reading a digit. |
| 3 | H × S | 3.0 | **Wire reduced motion into the shared skeletons**: `SkeletonList` in `lib/widgets/common.dart` runs `.shimmer()` unconditionally, and `ReducedMotionWrapper` in `lib/widgets/accessibility.dart` is never used anywhere else. Gate shimmer (and any repeated count-up) on `MediaQuery.disableAnimationsOf(context)` — pool_screen already does this locally. | NN/g notes animated skeletons can be an accessibility problem; our own design contract (DESIGN §8) says durations collapse to zero under reduced motion. |
| 4 | H × S | 3.0 | **Semantics for the charts**: `StorageDonut` (`lib/widgets/common.dart`) has *no* `Semantics` at all; add `Semantics(label: 'Disk usage', value: '18.6 of 30 GB used', role: SemanticsRole.status, excludeSemantics: true)`; on `PoolDonut` add `role:` too, and expose the legend as `Semantics(list)`/`listItem` rows. | Screen-reader users currently get "image" or nothing; Flutter's `SemanticsRole` exists precisely for custom-painted charts. |
| 5 | H × S | 3.0 | **Make the hero number explainable**: `onTap` on `StorageDonut` / `PoolDonut` → bottom sheet (radius 24) "Where this number comes from": per-contributor quota, trash, replica overhead, reserved — each row with `formatBytes`. | The single loudest complaint about Google One's meter is that it doesn't reconcile; an inspectable total is the trust fix. |
| 6 | H × S | 3.0 | **Optimistic + haptic-on-gesture for quota/revoke**: in `pool_contributor_tile.dart` / `contribute_sheet.dart`, apply the new quota to the ring and micro-bar the moment the slider moves (`AppHaptics.selection()` on drag), reconcile on response, roll back with an error `SnackBar` only after failure. | Simon Hearne: decouple feedback from network, <100ms visible response; DESIGN §9 already mandates "haptic on the gesture". |
| 7 | H × M | 1.5 | **"Largest items" card on the Storage tab**: top 5 files by size with a tap that jumps to `files_screen.dart` pre-sorted by `size` descending (sort already exists), plus a `TextButton('Review all')`. | Google Drive's storage view sorts largest-first and Google One's cleanup rows all end in "Review"; our tab stops at BY TYPE + DUPLICATES. |
| 8 | H × M | 1.5 | **Text scaling pass**: replace the 27 hardcoded `fontSize:` literals with `textTheme` styles; add `FittedBox`/`MediaQuery.textScalerOf` guards on the hero number (`pool_donut.dart` count-up), the mono byte columns and `StorageMeter` captions. | ~25% of users raise system text; today oversized labels overflow or get clipped, which looks like a rendering bug. |
| 9 | M × S | 2.0 | **Freshness line** on `pool_screen.dart` and `storage_screen.dart`: `Updated 8s ago` (`formatRelative`) under the hero, plus an inline "Couldn't refresh" note when a poll fails instead of silently keeping old numbers. `files_screen.dart` already shows `STALE`. | Calm design: silence is ambiguous; a stale number presented as current is the classic trust leak. |
| 10 | M × S | 2.0 | **Undo everywhere destructive**: `trash_screen.dart` restore and `pool_contributor_tile.dart` revoke currently show a failure SnackBar only — add `SnackBar(…, action: SnackBarAction('Undo'))` on success (files screen already has the pattern). | Forgiving interactions raise confidence more than confirmation copy; TrueNAS-style confirmations still stay for permanent delete. |
| 11 | M × S | 2.0 | **AMOLED smear guard** in `lib/app/theme.dart`: keep `#000000` behind static surfaces (hero card, bottom bar) but use `surfaceContainerLow #0A0A0A` for scrolling list backgrounds (`files`, `transfers`, `pool` lists). | Immich's rework thread documents purple smearing on pure-black scroll surfaces; Flutter's own dark default is `#303030`. |
| 12 | M × S | 2.0 | **Use the platform success/error haptics** in `lib/core/haptics/haptic_feedback.dart`: map `AppHaptics.success()` → `HapticFeedback.successNotification()`, `error()` → `errorNotification()`, `warning` → `warningNotification()`; keep hand-rolled double impacts as fallback. | These APIs exist in stable; system-pattern feedback is distinct from UI taps, so "upload finished" is unmistakable. |
| 13 | M × S | 2.0 | **Give `ErrorState` a second slot**: optional `details` (collapsed "Technical details") + optional secondary action; then audit every `ErrorState(message: …)` call site so each message names the cause and the next step. | "Retry" alone leaves users stuck; calm-design guidance is exactly this: guide, don't scold. |
| 14 | M × S | 2.0 | **No-results empty states**: search/filter-empty in `files_screen.dart`, `trash_screen.dart`, `shared_links_screen.dart` → offer "Clear filters" / "Try a different term" instead of a bare icon. | Empty-state research: a dead-end empty screen reads as broken; the next-best action keeps the session alive. |
| 15 | M × S | 2.0 | **Contributor list tail collapse** in `pool_contributor_tile.dart` list: sort by share descending, pin "This device", show the first 6 then a single row `3 more devices · 8 GB` that expands. | iCloud collapses to top-3 + "Others" on small screens; keeps the legend readable at 8+ contributors. |
| 16 | M × M | 1.0 | **Persistent transfer strip**: a slim glass chip above the `NavigationBar` in `lib/app/router.dart` showing `↑ 4.2 MB/s · 62%` while any transfer runs; tap → Transfers tab. | Unraid's status bar keeps running operations visible across tabs; today the only way to notice a transfer is to visit the tab. |
| 17 | M × M | 1.0 | **Threshold-gated pool meter on Files**: show a compact `StorageMeter` (pool used/quota) under the `AppBar` of `files_screen.dart` only when ≥50% used or ≥1 contributor offline. | Dropbox's >50% sidebar widget: quiet when healthy, present exactly when it changes a decision — and it's the Ceph "panel that doesn't change behaviour is decoration" rule. |
| 18 | L × S | 1.0 | **NavigationBar density**: in `lib/app/router.dart` set `NavigationBar(height: 68, indicatorColor: …tint)` while keeping all five labels visible (do **not** switch to `alwaysHide`). | Every M3E Google app shortened the bottom bar; but dropping labels on a 5-tab utility hurts discoverability, and Google's own research says keep text labels. |

**Status after v2.5.0:** **7** (Largest items card) and **17** (threshold-gated pool meter
on Files) are still open — both cross screens (a file-size query onto Storage, a pool-status
query onto Files), which wants a focused pass rather than the tail of a release.

Item **8** shipped in the half that could be verified, and not the other half. The guards
are real: `FittedBox(fit: BoxFit.scaleDown)` on the `StorageDonut` centre and on the pool
hero's number/`POOLED`/sub-line stack, both under
`test/widget/text_scaling_test.dart` at `TextScaler.linear(2.0)`. That test is what proved
the item was worth doing — it found two `RenderFlex` overflows (24 px and 98 px) that no
existing test could see, because every prior test pumped straight past the count-up at
default scale. The 27 hardcoded `fontSize:` literals were deliberately **not**
bulk-replaced: at default scale they *are* the design, and substituting them blind would
regress screens that have no test to catch the change.

Deferred / deliberately not recommended: adopting `material_3_expressive` (import migration),
spring/overshoot motion (clashes with our calm + AMOLED language), extra KPI cards, per-contributor
donuts, FAB menu (no stable API), bottom app bar.

---

## Sources

**Storage products**
- https://support.google.com/drive/answer/6374270?hl=en — shared 15 GB, full-account consequences, short- vs long-term recovery
- https://filerev.com/blog/google-one-storage-manager/ — Google One Storage Manager first screen, cleanup suggestions, quota-accuracy complaints
- https://www.androidpolice.com/google-one-new-swipe-storage-ui/ · https://www.androidauthority.com/google-one-swipe-ui-for-cleanup-3614669/ — M3E cleanup pane, swipe-to-delete
- https://9to5google.com/2025/11/17/google-material-3-expressive-redesign/ — per-app M3E rollout (Google One drops infographics, Photos pull-to-refresh, Digital Wellbeing donut thicker)
- https://help.dropbox.com/storage-space/account-space-left — storage bar categories, >50% sidebar widget, cleanup filters
- https://support.apple.com/guide/icloud/check-your-icloud-storage-on-any-device-mm039c13d410/icloud — bar graph + descending category list + "Others" collapse
- https://www.idrive.com/dashboard-faq — IDrive console structure (admin/Reports-first)
- https://consumer.ftc.gov/consumer-alerts/2025/07/are-you-really-out-cloud-storage-or-message-scam — scare-notification context

**Self-hosted / pro UIs**
- https://www.truenas.com/docs/scale/22.12/scaleuireference/storage/storagedashboardscreen/ · https://www.truenas.com/docs/scale/23.10/scaleuireference/storage/ — widgets, 80% donut warning, status glyphs, no-pools empty state, type-to-confirm destructive flows
- https://docs.unraid.net/unraid-os/getting-started/explore-the-user-interface/tour-the-web-gui/ — dashboard tiles, Main per-disk health, persistent status bar
- https://github.com/immich-app/immich/discussions/1898 — OLED smearing / true-black debate
- https://www.rams.ai/score/immich-app/immich — automated design review calling out silent failures

**Material 3 Expressive / Flutter availability**
- https://m3.material.io/develop/flutter — "M3 Expressive is not available on Flutter"
- https://m3.material.io/styles/motion/overview/how-it-works — motion physics availability table (Flutter: Unavailable), spring tokens, expressive vs standard
- https://m3.material.io/blog/building-with-m3-expressive · https://supercharge.design/blog/material-3-expressive — component list (button groups, FAB menu, loading indicator, split button, toolbars)
- https://blog.google/products-and-platforms/platforms/android/material-3-expressive-android-wearos-launch/ — launch post (haptic rumble, emphasized typography)
- https://design.google/library/expressive-material-design-google-research — 46 studies / 18,000 participants, 4× faster element detection, keep labels, minority prefers calm
- https://github.com/flutter/flutter/issues/168813 — Flutter is not actively developing M3E; Material decoupled to `material_ui`
- https://pub.dev/packages/material_ui · https://pub.dev/packages/material_ui/changelog — `StyleVariant` enum, "under development" note
- https://pub.dev/packages/material_3_expressive — third-party M3E implementation (caveats above)
- Flutter stable 3.47.5 source/API checks: `packages/flutter/lib/src/material/{divider,motion,icon_button,floating_action_button,refresh_indicator}.dart`, `src/semantics/semantics_service.dart`, `src/widgets/media_query.dart`, `src/widgets/basic.dart`, `src/services/haptic_feedback.dart`, `api.flutter.dev/flutter/dart-ui/SemanticsRole.html`

**Mobile UX 2025–2026**
- https://www.nngroup.com/articles/skeleton-screens/ — skeleton vs spinner vs progress bar rules
- https://simonhearne.com/2021/optimistic-ui-patterns/ — <100ms feedback, optimistic atomic actions
- https://www.uxmatters.com/mt/archives/2025/05/designing-calm-ux-principles-for-reducing-users-anxiety.php — micro-anxieties, forgiveness, tone
- https://www.pencilandpaper.io/articles/empty-states — empty-state anatomy and types
- https://developer.android.com/develop/ui/views/haptics/haptics-principles — haptic strength/frequency/consistency guidelines

**Accessibility of data viz**
- https://medium.com/carbondesign/color-palettes-and-accessibility-features-for-data-visualization-7869f4874fca — 3:1 non-text contrast, differentiated/diverse/sequenced palettes, color-agnostic chart cues
- https://www.section508.gov/create/making-color-usage-accessible/ · https://mn.gov/mnit/about-mnit/accessibility/news/?id=38-716215 — don't rely on colour alone
- https://dcm.dev/blog/2025/06/30/accessibility-flutter-practical-tips-tools-code-youll-actually-use/ — `SemanticsRole`, tooltips, `textScalerOf`, `useSystemColors`
