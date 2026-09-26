# RESEARCH/DESIGN.md — Pooled Data Cloud UI (LocalVault v2.4.0)

Scope: ONE unified capacity viz + contributor list + 4 states, for a worker to build as Flutter
widgets. Must sit inside the existing design language (`DESIGN.md`: deep-teal `#0E7C7B` seed,
8/12/16/24/28 radii, M3 `englishLike2021`, glassmorphism, AMOLED, haptics) — do **not** invent a
second visual system. Research date: 26 Sep 2026.

## 1. Three competitor UIs to emulate

| Source | Steal this |
|---|---|
| **TrueNAS SCALE → Storage Dashboard** (truenas/webui discussion #6767) | Pool card = one big health pill + capacity ring + a **per-disk/vdev list underneath**, each row with its own micro-bar. Mixed-capacity pools get an explicit "suboptimal configuration" notice instead of silently looking wrong. Copy: pool name + `30.0 TiB` total on one line, topology rows below. |
| **Ceph Dashboard "at-a-glance"** (Red Hat Ceph 4) | Health-first ordering: a **health glyph whose color IS the status** (green/amber/red), then `Status → Capacity → Performance` tiles. Thresholds color the number (`<0.75` green, `<0.85` amber, `≥0.85` red) so you read a signal, not a digit. Rule borrowed: *a panel that doesn't change what the user does is decoration*. |
| **Google One storage meter** | The canonical "one number, many contributors": a **single segmented bar for Drive + Gmail + Photos**, big total above, and a **legend list below where each row repeats its color chip + its own number**. Exactly our donut + contributor list relationship. |

2026 trend check (Linear/Vercel/Stripe-style dashboard roundups): *confidence over complexity* —
calm default view, progressive disclosure, typography carries hierarchy, generous whitespace is
functional. So: hero number + 4 stat rows + list; hide "edit quota / token / audit" behind a
`PopupMenuButton`, never on the surface.

## 2. Font pairing (Google Fonts)

Existing theme already applies `Typography.englishLike2021` (Roboto). Keep it — a second UI font
would break every screen.

```html
<link href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;700;800&family=Roboto+Mono:wght@500;700&display=swap" rel="stylesheet">
```

- **Headings**: Roboto 800, `letterSpacing -0.5` — matches `headlineLarge` brand usage.
  Pool hero number: `fontSize 40, w800, letterSpacing -1.0`.
- **Body**: Roboto 400/500 (`bodyMedium`), section titles Roboto 700 (`titleSmall`).
- **Byte figures**: **Roboto Mono 500** for the contributed/used columns so digits align vertically
  in the contributor list. Never Mono for prose.
- **Count-up safety**: always `style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])`
  on animated numbers, otherwise the center label jitters as digits change width.
- Uppercase micro-labels (`POOLED`, `CONTRIBUTORS`): `labelSmall` w700 `letterSpacing 1.2`, color `primary`.

## 3. Palette tokens

Segment order for up to 6 contributors = **slot order below** (chosen to maximize *adjacent*
luminance separation, min adjacent ratio 1.28): `seg1 teal → seg2 violet → seg3 amber → seg4 sky →
seg5 lime → seg6 rose` (7th+ wraps with `+40%` lightness). Assign by **stable slot index, not by
status** — colors must never reshuffle when a device goes offline.

```dart
// Dark + AMOLED (ring on #000000 / #111111)
const poolSegments = <Color>[Color(0xFF2DD4BF), Color(0xFFA78BFA), Color(0xFFFBBF24),
  Color(0xFF38BDF8), Color(0xFFA3E635), Color(0xFFFB7185)];           // teal violet amber sky lime rose
// Light theme (contrast ≥4.5:1 on #FFFFFF)
const poolSegmentsLight = <Color>[Color(0xFF0F766E), Color(0xFF6D28D9), Color(0xFFB45309),
  Color(0xFF0369A1), Color(0xFF4D7C0F), Color(0xFFBE123C)];
```

| Token | Dark hex | vs `#000000` | Light hex | vs `#FFFFFF` | Use |
|---|---|---|---|---|---|
| `poolSeg1..6` | see above | **11.3 / 7.7 / 12.6 / 9.8 / 13.9 / 7.8** (all ≫3:1) | see above | **5.5 / 7.1 / 5.0 / 5.9 / 5.0 / 6.3** | ring segments, legend chips, tile mini-bar fill |
| `statusOnline` | `#34D399` | 10.9 | `#047857` | 5.5 | online pill/dot |
| `statusOffline` | `#94A3B8` | 8.2 | `#475569` | 7.6 | offline pill/dot |
| `statusJoining` | `#38BDF8` | 9.8 | `#0369A1` | 5.9 | joining/progress |
| `statusDegraded` | `#FBBF24` | 12.6 | `#B45309` | 5.0 | partial-outage banner |
| `statusError` | `#F87171` | 7.6 | `#B91C1C` | 6.5 | quota exceeded |
| `segFreeTint` | segment @ **0.26 alpha** | — | segment @ **0.20 alpha** | — | "free" half of each segment |
| `ringTrack` | `#222222` (=`surfaceContainerHighest`) | 1.4 | `#E4E4E7` | 1.1 | empty remainder of ring |

Rules: text ≥4.5:1, **chart elements ≥3:1 vs background and vs adjacent segment** (WCAG 1.4.11).
Never encode meaning by hue alone — every segment also gets a legend row with name + bytes, and
offline segments drop to **0.30 alpha** so greyscale still reads (Datylon: if it works in greyscale
it works for colorblind users). Amber/lime text on dark: use `#111111` if placed *on* the fill.

## 4. Spacing / radius / shadow

- Space: `4 / 8 / 12 / 16 / 20 / 24 / 32`. Card padding `20`, list tile vertical gap `12`,
  section gap `16`, screen padding `16`, hero card top padding `24`.
- Radius: reuse `8` chips/mini-bar, `12` buttons/inputs, `16` cards (`GlassCard` default),
  `20` hero pool card (slightly larger = it's the page anchor), `24` bottom sheet, `28` search.
- Mini bar: height **10**, `strokeWidth`-equivalent radius `5` — identical to existing `StorageMeter`.
- Ring: size `168` (hero) / `120` (compact), `strokeWidth 16` / `10`, `StrokeCap.round`.
- Shadow: **no drop shadows** — depth comes from `GlassCard(blur: 20, opacity: 0.15,
  borderColor: outlineVariant@0.2)` exactly as `lib/widgets/glassmorphism.dart` does today.
  On AMOLED the hero card uses `surfaceContainer (#111111) @0.72` instead of a blur-heavy fill so
  the ring stays crisp over pure black.

## 5. Widget A — unified capacity card

Files: `lib/widgets/pool_donut.dart`, `lib/widgets/pool_capacity_card.dart` (screen:
`lib/features/pool/pool_screen.dart`, reached from the existing **Storage** tab → "Pooled cloud"
entry; stays inside the 5-tab `NavigationBar`).

```
PoolCapacityCard (GlassCard, radius 20, padding 20)
├─ SectionHeader('POOLED CLOUD') + StatusPill(health)      // reuse lib/widgets/common.dart
├─ Center → PoolDonut(size:168, strokeWidth:16, gapDeg:4, startAngle:-π/2)
│   ├─ CustomPaint(_PoolRingPainter)      // track → segments → per-segment used overlay
│   └─ Center Column
│       ├─ Row(baseline): [count-up 40/w800] + [gap 4] + ['GB' 16/w700 onSurfaceVariant]
│       ├─ Text('POOLED', labelSmall w700 ls1.2 primary)
│       └─ Text('18.6 GB used', bodySmall onSurfaceVariant)   // only if used > 0
├─ Row(3 × _PoolStat) : Contributors 3 · Used 18.6 GB · Free 11.4 GB
└─ Legend (Wrap of chips) OR hand-off to the list below
    chip = [8px dot poolSegN] + 'Pixel 7' + mono '10 GB'
```

**Painter geometry (concrete):**
- `sweep_i = (contributor.quotaBytes / pool.totalQuota) * (360 - n*gapDeg)`, drawn clockwise from
  top; each arc gets `gapDeg = 4` after it (`(n*gap)` reserved first so the ring never overruns).
- Two-tone per segment = free vs used of **that** contributor: draw the full sweep in
  `poolSegN @ 0.26`, then overlay `sweep_i * (used_i / quota_i)` in full `poolSegN`, both with
  round caps. One ring therefore answers "who gives what" **and** "how full are we".
- Offline contributor: draw its segment at `0.30` alpha + 2px dashed gap is unnecessary — alpha +
  the list pill is enough.
- Anti-alias: `Paint()..isAntiAlias = true`; guard `sweep <= 0` (contributes 0) and skip
  `sweep >= 359` degenerate full-circle arc (draw a `drawCircle` instead).

**Center label contract:** `formatBytes(pooledQuota)` → number = value, unit stripped, shown as
`30` + `GB`; suffix word `pooled`. Example: **`30 GB pooled`**, sub-line `18.6 GB used · 11.4 GB free`.
Reuses `formatBytes` from `lib/widgets/common.dart` (do not write a new formatter).

## 6. Widget B — contributor list card

```
SectionHeader('CONTRIBUTORS (3)') + TextButton('Add device')
└─ Card(16) → ListView.separated(shrinkWrap, physics: NeverScrollable)
   └─ PoolContributorTile (HapticListTile pattern)
      ├─ leading: 40px circle, 16% tint of poolSegN, Icon(Icons.phone/laptop/tablet/memory)
      ├─ title: Row[ Text(deviceName, titleMedium w600) , 8, StatusPill ]
      ├─ subtitle col:
      │   ├─ Text('Gives 10 GB · uses 3.2 GB', bodySmall onSurfaceVariant)   // mono digits
      │   └─ StorageMeter(fraction: used/quota, color: poolSegN, height 8, radius 4)
      │       + Row('32% of its share'  |  'This device')
      └─ trailing: PopupMenuButton(icon more_vert) →
           [Set quota…, Promote to primary / Make host, View audit entry, Revoke]
```

- Row height ≈ 88; separator `Divider()` at 0.6 opacity (theme default).
- **This device** gets a `StatusPill(primary, 'This device')` and is pinned to the top of the list.
- Quota edit → bottom sheet (radius 24, `HapticSwitch`/slider) — never a dialog.
- **Revoke** is destructive: `AppHaptics.heavy()`, confirmation sheet with the consequence spelled
  out ("Its 10 GB leaves the pool; 3.2 GB of stored chunks re-replicate"), primary action =
  `FilledButton` in `statusError`, positioned *below* the fold of the sheet (thumb-safe, per README
  "destructive actions live away from thumbs").
- Promotion success → `AppHaptics.success()` + `SnackBar(floating, radius 8)`.

## 7. Four states

**A. Empty pool** (0 contributors / first run) — `EmptyState` (64px `Icons.cloud_off_rounded`,
already exists) inside the hero GlassCard, **donut replaced by a dashed ring track** (`ringTrack`,
4/6 dash). Copy: title `Your cloud has no space yet`, subtitle `Contribute free space from this
device and add others to pool it into one drive.`, action = `GlassButton`/`FILLED` **`Contribute
this device`** + secondary `TextButton('How pooling works')`. Keep the 3 stat rows showing `0 GB`
so the layout doesn't jump when the first device joins.

**B. Degraded pool** (≥1 contributor offline) — do **not** blank the hero. Show a banner Card
*above* the donut: `Icons.wifi_off_rounded` + `2 of 3 devices are offline` + `11 GB temporarily
unavailable` + `Review`. Ring: offline segments at 0.30 alpha, health pill flips to amber
`statusDegraded`, center number switches to **available** capacity (`19 GB pooled` with sub-line
`11 GB offline`), because that's the number that changes what the user does (Ceph rule). All
contributors offline → pill `statusError`, number stays at total, banner explains reads repair from
replicas.

**C. Quota exceeded** (pool full / write rejected) — mirror the existing `usedFraction >= 0.9`
pattern in `storage_screen.dart`: `errorContainer @0.7` Card + `Icons.error_outline_rounded` +
`The pool is full. Free space, raise a contributor's quota, or add a device before uploads resume.`
+ `FilledButton('Manage space')`. Ring gets a 2px `statusError` outer halo (animated in) and the
center number/`used` line recolor to `statusError`. Haptic: `AppHaptics.error()` once per state
entry, never per rebuild.

**D. Join in progress** — tile shows `StatusPill(statusJoining,'Joining')` + a 4px indeterminate
`LinearProgressIndicator` under the name + running text `Verifying pairing… → Handshaking… →
Allocating 10 GB…`. Ring draws a **placeholder segment** for the pending device: 12% alpha +
rotating highlight. Timeout >15s → tile collapses to `statusError` + `Retry`.

## 8. Motion (concrete)

| Moment | Spec |
|---|---|
| Total number count-up | `AnimationController(duration: 700ms)` + `Curves.easeOutExpo`, integer tween, `tabularFigures()`, re-run only if `|Δ| ≥ 0.5%` of total; format each frame with `formatBytes`. |
| Ring sweep | `600ms`, `Curves.easeOutCubic`, per-arc `Tween<double>(begin: 0, end: sweep)`. |
| Contributor joins | One `joinProgress 0→1` (600ms, `easeOutCubic`) interpolates **every** arc's sweep so the whole ring re-balances together; then a `RotationTransition` spark (`Icons.auto_awesome`, 16px, `poolSegN`) travels 1 lap in 900ms, `Curves.easeInOut`, fades out. Tile entrance: `FadeTransition` + `Offset(0, 0.06 → 0)` over 320ms, staggered 60ms/tile. Ends with `AppHaptics.success()`. |
| Segment focus | Tap legend chip → that arc's `strokeWidth 16→20` and others to 0.45 alpha, 180ms `easeOut`; haptic `AppHaptics.selection()`. |
| Status change | Pill color/label cross-fade 200ms `easeInOut`; no bounce, no shake. |
| Degraded banner | `AnimatedSize` 240ms `easeOutCubic` + 12px slide-down. |
| Quota halo | 0→2px stroke over 400ms `easeOut`. |

Reduced motion: wrap all of the above in the existing `ReducedMotionWrapper` /
`MediaQuery.disableAnimations` check — durations collapse to `Duration.zero` and the count-up
jumps straight to the final value. Never let `duration: 0` break `AnimationController` (guard with
`if (reduce) return finalValue;` before constructing).

## 9. Haptics (map to existing `AppHaptics`)

`light` = tile tap / legend chip · `selection` = quota slider, filter change · `medium` = revoke
confirm, promote · `success` = join complete, quota raised · `error` = quota exceeded, join failed,
revoke failed. All calls fire **on the gesture**, not after the async result (README: optimistic
feedback). Never haptic on passive status refresh.

## 10. Accessibility & copy

- Semantic labels: `Semantics(label: 'Pooled capacity 30 gigabytes, 18.6 used, 3 contributors',
  image: true)` on the donut; ring is `excludeSemantics: true` internally.
- Every icon-only control gets a `tooltip` (`Revoke Pixel 7`, `Promote this device`).
- Hit targets ≥44px (menu row, legend chip padding `8/12`).
- Live region for state changes: `SemanticsService.announce('Pool degraded, 1 device offline', …)`.
- Copy deck (sentence case, honest, no exclamation): `pooled` / `contributes` / `uses` /
  `offline` / `joining` / `revoke` / `promote`. Prefer "device" over "node" in UI (save "node" for
  Settings/docs). Recency language everywhere: `last seen 12m ago`, not a raw timestamp.

## 11. Do / Don't

- ✅ One ring, one number, list as the legend — matches Google One + TrueNAS.
- ✅ Threshold the number (green/amber/red) instead of adding a fifth KPI card.
- ✅ Reuse `StatusPill`, `SectionHeader`, `StorageMeter`, `EmptyState`, `GlassCard`, `formatBytes`.
- ❌ Donut-per-contributor (7 rings = unreadable); ❌ pie with >6 slices; ❌ rainbow gradients;
  ❌ legends without bytes; ❌ animating on every poll tick; ❌ new fonts, new radii, drop shadows;
  ❌ `Size(double.infinity, …)` on buttons (breaks desktop, per `DESIGN.md`).
