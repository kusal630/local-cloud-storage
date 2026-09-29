# UI_BACKLOG — promised-vs-built, open UX defects, rules, test obligations

**Scope:** the project's own written record only (`PROJECT.md`, `RESEARCH/*`, `TEST_PLAN.md`,
`ASSUMPTIONS.md`, `BUILD.md`, `DESIGN.md`, `README.md`), cross-checked against `lib/` with `grep`.
Read-only audit; no file touched except this one. Date: 2026-09-28.

**Verdict key** — every promised UI/UX item below is one of:
**(a) built** · **(b) partially built** (work item) · **(c) not built** (work item) · **(d) explicitly descoped**
(quoted descope in the source doc, or a later doc cancels the promise — not a work item, but do not
re-introduce it silently).

Line numbers are from the docs/`lib` as read on 2026-09-28. `RESEARCH/INEFFICIENCIES.md:8-11`
warns its own cited lines drift ±30 while other agents edit — treat *its* code line numbers the same way.

---

## Promised but not built

### A. Pool screen — `RESEARCH/DESIGN.md` (the widget spec)

| # | Promise (doc:line) | Verdict | Evidence (`lib/`) |
|---|---|---|---|
| A1 | §5 "PoolCapacityCard (GlassCard, radius 20, padding 20)" + `SectionHeader('POOLED CLOUD')` + `StatusPill` (:91-93) | **(a)** | `widgets/pool_capacity_card.dart:101-113` |
| A2 | §5 `PoolDonut(size:168, strokeWidth:16, gapDeg:4, startAngle:-π/2)` two-tone arcs, free vs used per contributor (:93-109) | **(a)** | `widgets/pool_donut.dart:411-444`, painter `:161-332` |
| A3 | §5 "Count-up safety: always `FontFeature.tabularFigures()` on animated numbers" (:35-36) | **(a)** | `pool_donut.dart:104,107` |
| A4 | §5 `Row(3 × _PoolStat) : Contributors · Used · Free` (:99) | **(a)** | `pool_capacity_card.dart:128-132,239-278` |
| A5 | §5 legend chips = `[8px dot poolSegN] + name + mono bytes` (:100-101) | **(a)** | `pool_capacity_card.dart:318-385` |
| A6 | §6 contributor tile anatomy: 40px tinted circle, name + pills, `Gives 10 GB · uses 3.2 GB`, `StorageMeter`, `PopupMenuButton` (:121-133) | **(a)** | `pool_contributor_tile.dart:145-254` |
| A7 | §6 "This device … pinned to the top of the list" (:136) | **(a)** | `pool_contributor_tile.dart:169-172`, `:547-550` |
| A8 | §6 menu item **"Promote to primary / Make host"** (:132) | **(b)** | Menu exists (`pool_contributor_tile.dart:234-237`) but **no promote backend anywhere** (`grep -rn promote lib/server` matches only chunk staging — `pool_node.dart:148`, `pool_node_router.dart:190` — never a primary/registry promote) and `PoolScreen` never passes `onPromote` (`pool_screen.dart:237-249`), so the fallback fakes a success: `SnackBar('${c.name} is now primary')` + `AppHaptics.success()` (`pool_contributor_tile.dart:263-270`). Invented success = violates README:282 "no dead ends … errors name the fix". |
| A9 | §6 menu item **"View audit entry"** (:132) | **(b)** | `onViewAudit` never passed (`pool_screen.dart:237-249`); fallback renders a **fabricated** sheet from tile fields, not a real `audit_log` row (`pool_contributor_tile.dart:378-432`). |
| A10 | §6 quota edit → "bottom sheet (radius 24, `HapticSwitch`/slider) — never a dialog" (:137) | **(a)** | `pool_contributor_tile.dart:290-376` (`showModalBottomSheet` + `Slider` + `AppHaptics.selection`) — note: sheet shape not explicitly set to 24 (M3 default 28). |
| A11 | §6 revoke: `AppHaptics.heavy()` on gesture, consequence sheet, primary action in `statusError` below the fold (:138-141) | **(a)** | `pool_contributor_tile.dart:279-282,434-512` |
| A12 | §6 "Promotion success → `AppHaptics.success()` + `SnackBar(floating, radius 8)`" (:142) | **(b)** | Only reachable in the fake path (A8), and the SnackBar is plain, not `floating`/radius 8 (`pool_contributor_tile.dart:268-270`). Same for the quota-save SnackBar (`:372-374`). |
| A13 | §7A empty state: `EmptyState` 64px `cloud_off`, **dashed ring track**, exact copy, `GlassButton 'Contribute this device'` + `TextButton('How pooling works')`, 3 stat rows kept at `0 GB` (:146-151) | **(a)** | `pool_capacity_card.dart:140-178`, dashed `pool_donut.dart:247,403-404`, copy at `pool_capacity_card.dart:144-146`, explainer sheet `:193-236` |
| A14 | §7B degraded: banner Card above the donut with `wifi_off` + "2 of 3 devices are offline" + "11 GB temporarily unavailable" + `Review`; centre number switches to **available** capacity (:153-159) | **(a)** | `pool_screen.dart:309-320`, `pool_health_banner.dart:150-171`, centre switch `pool_capacity_card.dart:60-66` |
| A15 | §7C quota exceeded: `errorContainer @0.7` card + exact copy + `FilledButton('Manage space')` + 2px `statusError` halo + `AppHaptics.error()` **once per state entry, never per rebuild** (:161-166) | **(a)** | `pool_screen.dart:261-300` (card), `:130-137` (`_wasFull` guard), halo `pool_donut.dart:324-332,397-398,442-443` |
| A16 | §7D join in progress: `StatusPill('Joining')` + 4px indeterminate `LinearProgressIndicator` + staged text `Verifying pairing… → Handshaking… → Allocating 10 GB…` + placeholder ring segment + "Timeout >15s → tile collapses to `statusError` + `Retry`" (:168-171) | **(a)** | `pool_contributor_tile.dart:53-56,102-107,180-220`; placeholder arc `pool_donut.dart:517-519`; 15s timer `pool_screen.dart:166-185` |
| A17 | §8 motion: total count-up `700ms easeOutExpo`, re-run only if `|Δ| ≥ 0.5%` (:177) | **(a)** | `pool_donut.dart:412,439,491-493` |
| A18 | §8 motion: ring sweep `600ms easeOutCubic` (:178) | **(a)** | `pool_donut.dart:411,437` |
| A19 | §8 motion: **"Contributor joins … `joinProgress 0→1` (600ms) interpolates every arc … then a `RotationTransition` spark (`Icons.auto_awesome`, 16px) travels 1 lap in 900ms … Ends with `AppHaptics.success()`"** (:179) | **(c)** | No `auto_awesome`, `joinProgress`, or `RotationTransition` anywhere in `lib/` (grep → 0). Tiles do entrance-stagger (`pool_contributor_tile.dart:598-607`); ring only re-sweeps. |
| A20 | §8 motion: segment focus — tap legend chip → that arc `strokeWidth 16→20`, others `0.45 alpha`, `180ms easeOut`, `AppHaptics.selection()` (:180) | **(a)** | `pool_capacity_card.dart:38-43`, `pool_donut.dart:441,315` |
| A21 | §8 motion: **"Status change: pill color/label cross-fade 200ms `easeInOut`; no bounce, no shake"** (:181) | **(c)** | `StatusPill` is a stateless `Container` — no animation (`lib/widgets/common.dart:287-313`); pills swap instantly everywhere. |
| A22 | §8 motion: degraded banner `AnimatedSize` 240ms `easeOutCubic` + 12px slide-down (:182) | **(a)** | `pool_health_banner.dart:284-300` |
| A23 | §8 motion: quota halo 0→2px over 400ms `easeOut` (:183) | **(a)** | `pool_donut.dart:442-443,507-511` |
| A24 | §8 reduced motion: wrap in `ReducedMotionWrapper` / `MediaQuery.disableAnimations`, durations → `Duration.zero`, count-up jumps to final; "Never let `duration: 0` break `AnimationController`" (:185-188) | **(a)** | `pool_donut.dart:423-435,464,475-511`; `pool_screen.dart:97-100,425`; banner skips anims entirely (`pool_health_banner.dart:284`). *Note:* `ReducedMotionWrapper` itself is **never mounted** anywhere (see B14). |
| A25 | §9 haptics map: light = tile/legend, selection = slider/filter, medium = revoke confirm/promote, success = join complete/quota raised, error = quota exceeded/join failed; **"fire on the gesture, not after the async result"**; **"Never haptic on passive status refresh"** (:192-195) | **(a)** | `pool_contributor_tile.dart:227,263,281,337,371,502`; `pool_capacity_card.dart:41,152,167`; `contribute_sheet.dart:216,226,236,252,329,342,354`; refresh button has no haptic (`pool_screen.dart:206-211`) |
| A26 | §10 semantics on the donut `Semantics(label: 'Pooled capacity 30 gigabytes…', image: true)` + `excludeSemantics` internally (:199-200) | **(a)** | `pool_donut.dart:601-604` |
| A27 | §10 "Every icon-only control gets a `tooltip` (`Revoke Pixel 7`, `Promote this device`)" (:201) | **(b)** | Refresh button (`pool_screen.dart:208`) and the row menu (`pool_contributor_tile.dart:225` = `'Actions for ${c.name}'`) have tooltips; there is **no** per-action tooltip such as "Revoke Pixel 7" (actions are text menu rows), and the sheet's icon-only buttons are text-labelled. Widget test `pool_ui_test.dart:689` only asserts *some* tooltip coverage. |
| A28 | §10 hit targets ≥44px (menu row, legend chip padding 8/12) (:202) | **(a)** | `pool_capacity_card.dart:345-349`, `contribute_sheet.dart:896`, banner `Review` min 64×44 (`pool_health_banner.dart:267`) |
| A29 | §10 live region: `SemanticsService.announce('Pool degraded, 1 device offline', …)` (:203) | **(a)** | `pool_health_banner.dart:135-148`, once per state entry `:114-133` |
| A30 | §10 copy deck: sentence case, honest, **no exclamation**; prefer "device" over "node"; recency language `last seen 12m ago` not a raw timestamp (:204-206) | **(b)** | "device over node": **(a)** — `grep -i node lib/features/pool lib/widgets/pool_*.dart` returns **0** hits (user-facing or comment). Recency: **(b)** — `last seen …` exists (`pool_contributor_tile.dart:142,417`) but is hidden on offline rows (B3-ii); `devices_screen.dart:115` still prints a raw timestamp outside the pool. |
| A31 | §11 ❌ don'ts: no donut-per-contributor, no pie >6 slices, no rainbow gradients, **no legends without bytes**, **no animating on every poll tick**, no new fonts/radii/drop shadows, ❌ `Size(double.infinity, …)` on buttons (:213-215) | **(a)** | Legend always carries bytes (`pool_capacity_card.dart:370-375`); poll tick never re-animates count below 0.5% (`pool_donut.dart:491-493`); pool buttons use `minimumSize: Size(64,44)` not infinity (`pool_health_banner.dart:267`, `contribute_sheet.dart:303,758`). *Caveat:* `welcome_screen.dart:100-115` and `lock_screen.dart:176,197` wrap buttons in `SizedBox(width: double.infinity)` — pre-existing, same desktop risk the rule targets. |

### B. Pool + honesty patterns — `RESEARCH/FEATURES.md` §4 / §3 / §6

| # | Promise (doc:line) | Verdict | Evidence |
|---|---|---|---|
| B1 | §4.1 "One number, segmented … extend the existing segmented donut rather than invent a new chart" (:168) | **(a)** | `PoolDonut` reused from `lib/features/storage`'s donut lineage; single chart |
| B2 | §4.2 **"ZFS-style headline state. A single colored word *above* everything: `ONLINE` (green) / `DEGRADED` (amber…) / `AT RISK` (red). Never a healthy-looking total while a member is missing."** (:169) | **(b)** | `PoolHealthBanner` renders the word — but `PoolScreen._showBanner` **suppresses the banner whenever health == online** (`pool_screen.dart:160-164`), so **`ONLINE` is never rendered in the running app**; the healthy path shows the capacity card's pill, whose vocabulary is `Healthy/Empty/Full/Joining/Offline/Degraded` (`pool_capacity_card.dart:45-58`), not the promised `ONLINE`. DEGRADED/AT RISK/OFFLINE do render. Widget test asserts `ONLINE` only by constructing the banner directly (`pool_ui_test.dart:187-199`). |
| B3 | §4.3 member rows: "icon · name · used/total · mini bar vs its own cap · status chip · **`last seen`** · ⋯ menu (**pause**, revoke, **set as registry**)" (:170) | **(b)** | Rows built (`pool_contributor_tile.dart:145-254`), **but**: (i) `last seen` renders only for **non-offline** rows (`:139-143`) — the stale device that needs it shows just the word `Offline`, contradicting §4.6 "staleness must be visible, not inferred"; (ii) **no `pause`** menu item; (iii) **no `set as registry`** (see A8); (iv) status chips are the UI's 4-state enum, not the §3 five-state machine (D13 below). |
| B4 | §4.4 **"Resilver-style repair progress. A persistent, non-blocking row: `Repairing 3 of 12 replicas…` with ETA"** (:171) | **(b)** | Widget + test exist (`pool_health_banner.dart:274-374`, `pool_ui_test.dart:265-288`) **but `PoolScreen` never passes `repairDone`/`repairTotal`/`repairEta`** (`pool_screen.dart:309-320` passes neither), and `GET /pool/status` carries **no repair fields** (`pool_coordinator.dart:140-158`), so `repairTotal` stays 0 and the row never renders. `RepairReport.queued` is only returned by revoke/maintenance responses (`pool_router.dart:165-174`). |
| B5 | §4.5 per-contributor quota bar `4.2 GB / 10 GB used` with the cap as a hard stop (:172) | **(a)** | `pool_contributor_tile.dart:193-207` (`Gives … · uses …` + `StorageMeter` + `% of its share`) |
| B6 | §4.6 **"Honest freshness. `Last sync 12 s ago` on the pool header; per-row `last seen`."** (:173) | **(b)** | Header freshness **not built**: `generated_at` is sent (`pool_coordinator.dart:155`) and parsed into `PoolDiagnostics.generatedAt` (`pool_service.dart:117,149`) but `fetchStatus()` **discards diagnostics** (`pool_service.dart:263-277`) and `PoolStatus` has no such field (`pool_models.dart:209-227`). Per-row: partial (B3-ii). |
| B7 | §4.7 **"Trust badges on files** (already a v2.3 pattern): `2/2 copies · verified` → degrades to `1/2 copies` → `unreadable (quarantined)`. Progressively disclose *why* on tap." (:174) | **(c)** | No per-file copy-count badge anywhere: `grep 'copies' lib/features` → 0 hits. The only user-visible verification string is transfers' `'Done • verified'` (`transfers_screen.dart:180`). Server exposes `x-degraded` / `x-replica-count` (`pool_router.dart:249-251`) and `pool_service.getChunk` ignores them (`pool_service.dart:471-478`). |
| B8 | §4.8 **"Add-device CTA with projected gain: `+ Add contributor → pool becomes 40 GB`"** (:175) | **(b)** | The projection exists **inside the contribute sheet only** (`contribute_sheet.dart:199-204`, goal-gradient `:179`); the `Add device` TextButton itself carries no projection (`pool_contributor_tile.dart:555-570`). |
| B9 | §4 avoid: "show the *effective* pool (`20 GB usable now · 30 GB when Laptop returns`), never a magic number" (:179) | **(a)** | Degraded centre switches to `availableQuota` + `"11 GB offline"` sub-line (`pool_capacity_card.dart:60-78`) |
| B10 | §4 avoid: "A pool with zero contributors must not render as `0 B used, all good` — it must render as the onboarding state" (:181) | **(a)** | `pool_models.dart:283-289` → `PoolViewState.empty` → A13 |
| B11 | §4 avoid: "Silent write failure. Every refused write names the fix: `Pool full — free 1.4 GB or raise a contributor cap`" (:182) | **(b)** | Server message built (`pool_coordinator.dart:765`), quota-exceeded card built (A15); but any *menu* action with no callback still degrades to a **fake success** instead of an error (A8/A9) — the exact violation `INEFFICIENCIES.md:181` records as UX friction 9. |
| B12 | §3 "Capacity forecast (`Pool full in 12 days at current growth`)" (:158) + §6 backlog item 10 (:255) | **(c)** | `grep forecast|estimated lib/` → nothing user-facing. `INEFFICIENCIES.md:47` marks backlog #10 **MISSING** and it is still missing. |
| B13 | §3 "Degraded-read path: serve from surviving replica, **flag file `1 of 2 copies`**, queue repair" (:146) and §5.5 "Return data + `stale` badge with the contributing device's last-seen time" (:240) | **(c)** | Server computes `degraded` (`pool_coordinator.dart:88-92`) and sends `x-degraded`; **no client/UI surface reads it** (grep `x-degraded lib/client` → 0). |
| B14 | §6 backlog #7 "status machine ONLINE/DEGRADED/OFFLINE/**DRAINING**/REVOKED" (:252) + §4.3 "Status chips map 1:1 to the §3 state machine" (:170) | **(c)** | `ContributorStatus` = `ALIVE/SUSPECT/DEAD/REVOKED/LEFT` — **no `DRAINING`** (`lib/data/models/contributor.dart:8-13`); UI collapses to `online/offline/joining/failed` (`pool_models.dart:15-27`), so chips can never map 1:1. `INEFFICIENCIES.md:44` records "no DRAINING" and `:46` "drain-before-revoke MISSING". |
| B15 | §6 backlog #3 "Pool screen: headline + rows + segmented donut" (:250) | **(a)** | built + wired (`lib/app/router.dart:87-118`) — see §2, this one is **fixed** relative to `INEFFICIENCIES.md:40` |
| B16 | §6 backlog #8 "Automatic repair worker **+ resilver progress row**" (:253) | **(b)** | worker built (`pool_coordinator.dart:repairStep`), progress row unwired → **B4** |
| B17 | §6 backlog #10 "audit-log polish" (pool entries in the dashboard icon map) (:255) | **(c)** | `host_dashboard_screen.dart:951-967` icon map has **no `pool.*` / `chunk.*` keys**; `AuditLogViewer`'s icon switch has none either (`audit_log.dart:23-44`) and its filter chips are `All/Login/Upload/Download/Delete/Share` only (`audit_log.dart:108-142`) — so pool rows fall to `info_outline`+blue and are not filterable. Matches `INEFFICIENCIES.md:31,164` (D28). |

### C. Pool obligations from `RESEARCH/CONSULT.md` (UI sentences only)

| # | Promise (doc:line) | Verdict | Evidence |
|---|---|---|---|
| C1 | §1 pitfall: "revocation is not instant — **the UI must show `revoking… (re-replicating N chunks)`**" (:71-72) | **(c)** | `PoolService.revoke()` decodes and **drops** the `chunks_to_repair` counter (`pool_service.dart:354-365`); the tile's only such string is the unreachable fallback snackbar (`pool_contributor_tile.dart:506-510`, shown only when `onRevoke` is null — it is passed). |
| C2 | §2 pitfall: "…**showing `reserved` bytes separately on the pool screen**" (:151-153) | **(a)** | `_ReservedLine` + tooltip (`pool_capacity_card.dart:136-139,289-313`); test `pool_ui_test.dart:587-612` |
| C3 | §4 UI: "compute the donut in ONE query inside ONE transaction, so the number and the ring can never disagree; display **`≈` + `updated Xs ago`**" (:262-264) | **(b)** | One snapshot: partial on the server — `snapshot()` still does four reads (`INEFFICIENCIES.md:115-117` D11, **not re-verified as fixed in this audit**); the **`≈ … updated Xs ago` label is not built at all** (no such string in `lib/`). |
| C4 | §4 UI: "while a contributor is `SUSPECT` **show it dimmed but keep it in the total until `DEAD`**" (:264) | **(b)** | Kept in the total server-side (`contributor_repository` sums `ALIVE`,`SUSPECT`); but the UI maps `suspect → offline` (`pool_models.dart:146-152`) and renders a normal `Offline` pill with full-alpha arc — **not** a dimmed-in-total treatment. |

### D. `PROJECT.md` v2.4.0 features with a UI surface

| # | Feature (doc:line) | Verdict | Evidence |
|---|---|---|---|
| D1 | #2 "UI shows ONE 30GB cloud" (:7) | **(b)** | Screen + math wired, **but file data never reaches the pool** (see §Contradictions #1): `PoolStorage.putFile/getFile/deleteFile` has **zero production callers** — `pool_storage.dart` is imported only by `test/integration/pool_storage_test.dart:14`. So `used_bytes` can never grow from real uploads and the donut's "used" half of every arc is permanently 0 in the real app. |
| D2 | #4 "single donut + single number that sums every contributor" (:9) | **(b)** | built (D1 caveat; plus defect D12 below was about the UI recomputing — now fixed) |
| D3 | #10 "Offline/degraded handling: pool reports which contributors are down, reads repair from replicas" (:15) | **(a)** | banner + `repairStep` (`pool_screen.dart:309-320`, `pool_coordinator.dart:repairStep`) |
| D4 | #11 "Security score + audit log entries for pool join/leave/write/read failures" (:16) | **(b)** | Audit rows exist server-side (`pool_coordinator.dart:423,574,614,771,949`) but **the score has no pool items** (`host_dashboard_screen.dart:845-869` — only TLS/login/tokens/retention/quota) and the audit **UI has no pool icons or filters** (B17). Matches `INEFFICIENCIES.md:31`. |
| D5 | #12 "Pool management screen: list contributors, capacity, status, revoke, **promote this device**" (:17) | **(b)** | list/capacity/status/revoke ✓; **promote has no backend and no wiring** (A8). `INEFFICIENCIES.md:32` already recorded "no promote/`set as registry` backend at all" — still true. |

### E. `README.md` promises (public surface)

| # | Promise (doc:line) | Verdict | Evidence |
|---|---|---|---|
| E1 | v2.4.0 "**Contribute this device** — one bottom sheet, slider capped at this device's real free space (never a fabricated number)" (:80-81) | **(a)** | `contribute_sheet.dart:42-43,131-145`; hard-block when free space unknown (`pool_screen.dart:348-383`) |
| E2 | v2.4.0 "Health at a glance — one donut ring … plus a ZFS-style headline: `ONLINE` / `DEGRADED` / `AT RISK` / `OFFLINE`" (:82-83) | **(b)** | see B2 — `ONLINE` unreachable |
| E3 | v2.4.0 "Contributors list — see what each device gives and uses, **resize a share**, or revoke a device and let its chunks re-replicate" (:84-85) | **(b)** | resize+revoke wired (`router.dart:97-99`); the *visible* re-replication progress is unwired (B4, C1) |
| E4 | v2.4.0 "**Replication, not luck** — every chunk is written to R=2 copies … the coordinator resolves every read and repairs missing copies" (:86-88) | **(c)** | engine exists, **no production writer/reader** (D1) — nothing in `lib/client/services/transfer_manager.dart` touches the pool (grep `pool` → 0) |
| E5 | v2.4.0 "**Honest reads** — a file whose slots are missing or unreadable is reported incomplete rather than returned short" (:89-90) | **(c)** | server flag exists (`pool_storage.dart:434-435,461`), unreachable because no file path uses `PoolStorage` (D1), and no UI renders "incomplete" |
| E6 | "The screen has five shapes: empty pool, healthy, degraded, quota exceeded, and joining — plus a contributors list with revoke/resize" (:191-192) | **(a)** | `PoolViewState` (`pool_models.dart:314-329`) + screen branches (`pool_screen.dart:229-250`) |
| E7 | v2.3.0 "**Help center** — searchable articles, FAQ accordion, contact support" (:72) | **(c)** | `HelpCenter`, `FaqAccordion`, `ContactSupport` are defined in `lib/widgets/help_center.dart` and **instantiated nowhere** (grep across `lib/features|lib/app|lib/client|lib/server|lib/core` → 0). No Help/FAQ entry in `settings_screen.dart`. |
| E8 | v2.3.0 "**Conflict resolver** — side-by-side comparison for sync conflicts" (:70) | **(c)** | `ConflictResolver` unused (0 refs). `files_screen.dart:1346-1403` has a *different*, inline "files already exist" overwrite dialog. |
| E9 | v2.3.0 "**Audit log** — track all file operations with filtering and search" (:67) | **(b)** | `AuditLogViewer` (the widget with filter chips + search) is **unused**; reachable UI is the host dashboard's 20-row feed (`host_dashboard_screen.dart:946-974`) with no filter/search, plus per-file activity in `preview_screen.dart:909-920`. |
| E10 | v2.3.0 "**Security score** — 0-100 score with security checks and tips" (:66) | **(b)** | `SecurityScore`/`SecurityTips` widgets unused; dashboard shows `'$pass/$total'` (`host_dashboard_screen.dart:868`) — not 0-100, and **no tips**. |
| E11 | v2.3.0 "**Session manager** — view and revoke active device sessions" (:68) | **(b)** | `SessionManager` widget unused; devices can be revoked (`devices_screen.dart:46-71`) and API tokens managed, but there is no session list with expiry/rotation. |
| E12 | v2.3.0 "**Offline files manager** — manage pinned files with storage info" (:69) | **(b)** | `OfflineFileManager` unused; you can pin/unpin (`files_screen.dart:716,1037-1055`), see an offline banner (`:1667`) and a total in Privacy center (`privacy_screen.dart:115-120`) — but no list-with-actions screen. |
| E13 | v2.3.0 "**Custom page transitions** — slide-up, fade-through, shared-axis animations" (:59) | **(c)** | `lib/widgets/transitions.dart` (`AppTransitions`, `FadeThroughRoute`, `SlideUpRoute`) has **0 users**; no `pageTransitionsTheme` in `lib/app/theme.dart`; every `go_router` route uses plain `builder:` (`lib/app/router.dart:47-157`). |
| E14 | v2.3.0 "**Glassmorphism UI** — backdrop blur cards, buttons, and overlays" (:58) | **(b)** | `GlassCard/GlassOverlay/GlassButton` used **only** by the new pool card (`pool_capacity_card.dart:101,150`). No other screen uses them (grep whole repo → 3 hits, all pool). |
| E15 | v2.3.0 "**Accessibility** — semantic labels, high contrast mode, reduced motion support" (:61) | **(b)** | Semantic labels exist ad hoc (pool widgets, `accessibility.dart` users = 0); **`HighContrastWrapper` is never mounted** (the only `highContrast` read in `lib/` is inside the unused wrapper, `accessibility.dart:103`); reduced motion is honoured via `MediaQuery.disableAnimations` in pool/storage screens, but `ReducedMotionWrapper` itself has 0 users. |
| E16 | v2.3.0 "**Onboarding tooltips, feature highlights**" (STATUS `:16`, `lib/widgets/onboarding.dart`) | **(b)** | First-run `OnboardingFlow` is real (`welcome_screen.dart:23-37`, `features/onboarding/onboarding_screen.dart`); `OnboardingTooltip`/`FeatureHighlight`/`QuickActionFab` have 0 users. |
| E17 | v2.3.0 "Haptic feedback — distinct tactile patterns for taps, selections, success, errors" (:56) | **(a)** | `core/haptics` + `AppHaptics` used broadly; `HapticButton/IconButton/Switch/Tap` unused but `HapticListTile` is (`pool_contributor_tile.dart:145`). |
| E18 | v2.3.0 "Smart search with filters" (:60), "Batch operations" (:62), "Enhanced image viewer" (:63), "Video player controls" (:64), "File info panel" (:65), "LRU image cache" (:71) | **(a)** | implemented inline: filter chips `files_screen.dart:1572,1729-1810`; selection `_selected`/`_selectionMode` `:249-250,400`; viewer `preview_screen.dart:269`; video `:383-411`; info/checksum `:703-713`; cache in `lib/core/performance`. (`SmartSearchBar`, `LazyLoadList/Grid`, `BatchActionBar` widgets themselves are unused — implementation lives in the screens.) |
| E19 | Experience design: "**Instant feedback** — stars, comments, and uploads acknowledge the tap immediately (optimistic UI with rollback)" (:279-281) | **(a)** | pre-existing pattern (see also quota sheet success-before-result) |
| E20 | Experience design: "**No dead ends** — deletes are undoable, trash states its safety window, **errors name the fix and offer Retry**, offline mode says so honestly" (:282-283) | **(b)** | honored by the pool error paths (`contribute_sheet.dart:769-790` "name the fix + Retry", `pool_screen.dart:219,344-346`) but violated by the fake promote/audit fallbacks (A8/A9) and by B11 |
| E21 | Experience design: "**Thumb-first** — 5 bottom tabs, bottom sheets, FAB, swipe-to-star/delete with button fallbacks; **destructive actions live away from thumbs**" (:283-285) | **(a)** | 5 tabs (`router.dart:63-131`), revoke sheet `SizedBox(height: 96)` before the destructive button (`pool_contributor_tile.dart:472-474`), contribute sheet stop-action below the fold (`contribute_sheet.dart:698-699`) |
| E22 | Experience design: "**Recency language** — lists speak in `2h ago`, details keep exact dates" (:285-286) | **(b)** | `formatRelative` exists (`common.dart:350-356`) but is not shown on offline pool rows (B3-ii); `devices_screen.dart:115` still prints a raw `toString()` timestamp |
| E23 | Experience design: "**Trust is visible** — the host Security scorecard, pinned-certificate flow, and checksum `verified` badges show the safety" (:286-288) | **(b)** | pinned flow ✓ (`pool_node_client.dart`), transfer `verified` ✓, per-file copy badge ✗ (B7), scorecard partial (E10) |
| E24 | "Current status (honest)": video/PDF/Office thumbnails not generated; Auto Backup background is future work; no relay server (:299-304) | **(d)** | explicit descope — do not "fix" these |

### F. `DESIGN.md` (root) screen descriptions — spot-checked

| Promise (doc:line) | Verdict | Evidence |
|---|---|---|
| Welcome max-width 560, logo → name → tagline → LAN pill → action card → 3 feature rows → footer (:20-21) | **(a)** | `welcome_screen.dart:53` (`maxWidth: 560`) |
| Files: AppBar → breadcrumbs (ActionChips) → SearchBar → FilterChips → list or responsive grid (2/3/4/5/6 cols) → FAB.extended "New" (:22-24) | **(a)** | `files_screen.dart:1622,1717,1729,2069-2078` |
| Host setup: step headers, storage card, strength meter, error card, rocket CTA (:25-26) | **(a)** | `host_setup_screen.dart:157,238-240` |
| Host dashboard: status pills row, CONNECT / DEVICES / STORAGE cards (:27) | **(a)** | `host_dashboard_screen.dart:106,127,155` |
| Client connect: STEP 1 scan + STEP 2 code, validation, last-URL memory (:28) | **(a)** | `client_connect_screen.dart:244,363` |
| Transfers: `x / y • n%`, Up/Download-aware label (:29) | **(a)** | `transfers_screen.dart:106-108` |
| Storage/Preview: shared meters, `Today HH:MM` / `12 Sep 2026, 14:30`, copyable checksum, picker-based download (:30-31) | **(a)** | `common.dart:328+`, `preview_screen.dart:708-713` |
| **Rules** — see §"Rules I must not break" | — | `DESIGN.md:33-37` |

### G. Explicitly descoped (d) — don't treat as work items

- `ASSUMPTIONS.md:30` "Host Mode on Android … not implemented in this MVP" — **(d) but stale** (see Contradictions).
- `ASSUMPTIONS.md:38` "Video thumbnails and document previews are not included in the MVP" — (d), echoed by README:299.
- `ASSUMPTIONS.md:34` "No real-time sync … the client must refresh the file list" — (d).
- `RESEARCH/DESIGN.md:110-111` "Offline contributor: … **2px dashed gap is unnecessary** — alpha + the list pill is enough" — (d).
- `RESEARCH/STATUS.md:27`: D9 "rejected as a non-defect", D10 "deliberately skipped" — (d) by later decision, while `INEFFICIENCIES.md:89-91,111-113` still list them as open defects (**contradiction, see §Sources note**).
- `README.md:303-304` "there is no relay server, by design" — (d).

---

## Open UX defects

Ordered by severity. "Open" = recorded in a doc **and** still true in `lib/` as read today.
Three defects recorded by `INEFFICIENCIES.md` are **already fixed** (D2, D12, D13) and are marked
as such below, because that file is the stalest doc in the set.

### Still open — UI/UX

1. **UX-1 · The pool screen's two menu actions either lie or fabricate** (`INEFFICIENCIES.md:32,181`
   — "Revoke/promote/contribute menu items silently do nothing instead of erroring — violates
   'errors name the fix'"). Revoke/contribute/quota are now wired (`router.dart:97-110`), **but
   `onPromote` and `onViewAudit` are still never passed** (`pool_screen.dart:237-249`), and the
   fallbacks now *pretend to succeed*: `SnackBar('${c.name} is now primary')` + success haptic
   (`pool_contributor_tile.dart:263-270`) and a locally fabricated "Audit entry" sheet (`:378-432`).
   Promote has no backend at all. **Work item:** either implement promote/registry + real audit
   navigation, or remove the two menu rows.
2. **UX-2 · Resilver/repair progress row never renders** (`INEFFICIENCIES.md:182` UX friction 10:
   "No repair/resilver progress row (FEATURES §4 copy #4)"). Widget + test exist, but no caller
   passes `repairDone/repairTotal/repairEta` (`pool_screen.dart:309-320`) and the status payload has
   no such fields (`pool_coordinator.dart:140-158`). **Work item:** add `repair_done`/`repair_total`
   (+ optional ETA) to `PoolSnapshot.toJson`, parse into `PoolStatus`, pass into `PoolHealthBanner`.
3. **UX-3 · No freshness label** (`INEFFICIENCIES.md:184` UX friction 12: "No `Last sync 12s ago`
   freshness label (DESIGN §10 / FEATURES §4 copy #6) even though `generated_at` is sent").
   **Work item:** carry `generatedAt` through `fetchStatus()` and render `formatRelative` in the
   `POOLED CLOUD` header row.
4. **UX-4 · Offline rows hide `last seen`** (`FEATURES.md:173`: "per-row `last seen` … staleness must
   be visible, not inferred"; `FEATURES.md:152` "Stale-device honesty (`Laptop last seen 3 h ago`)
   instead of a silent stale total"). `pool_contributor_tile.dart:139-143` renders it only when
   `!c.isOffline`. **Work item:** always render `last seen …` (and prefer it over the bare `Offline`
   word when `lastSeen != null`).
5. **UX-5 · `last_error` never reaches the UI**, although the server records it *for this purpose*:
   "Records the last transport/verification failure … **so the pool screen can say why a row is
   unhappy instead of going silent**" (`contributor_repository.dart:89-91`). `PoolContributor.fromJson`
   has no `last_error` field (`pool_models.dart:96-108`) and `fetchStatus()` drops the diagnostics
   object (`pool_service.dart:263-277`). **Work item:** surface `last_error` on the row / audit sheet.
6. **UX-6 · No per-file trust badge** (`FEATURES.md:174` copy #7 `2/2 copies · verified` → `1/2
   copies` → `unreadable (quarantined)`; README:286-288 "checksum `verified` badges").
   **Work item:** read `x-replica-count`/`x-degraded` (`pool_router.dart:249-251`) in
   `pool_service.getChunk` and show the badge on preview/transfer rows.
7. **UX-7 · `ONLINE` headline unreachable** (`FEATURES.md:169`, README:82-83). `pool_screen.dart:160-164`
   hides the banner when healthy and the card pill says `Healthy`. **Work item:** render the headline
   word in both cases (banner always, or make the pill speak the ZFS vocabulary).
8. **UX-8 · Security score has no pool items** (`INEFFICIENCIES.md:31` matrix #11 and
   `host_dashboard_screen.dart:845-869`) — add pool join/leave/write/read/corrupt checks. **Also**
   README:66 promises "0-100 … with tips"; the built score is `pass/total` with no tips.
9. **UX-9 · No `pool.*` icons/filters in the audit UI** (`INEFFICIENCIES.md:31,164` D28;
   `host_dashboard_screen.dart:951-967`, `audit_log.dart:23-44,108-142`). Pool rows render with a
   generic `info_outline` and cannot be filtered. Related: the `AuditLogViewer` filter chips use
   short names (`login`,`upload`) while the server writes dotted actions (`file.upload`,`pool.join`)
   — if/when the viewer is mounted, its filters match nothing.
10. **UX-10 · `revoking… (re-replicating N chunks)` never shown** (`CONSULT.md:71-72`);
    `PoolService.revoke()` discards `chunks_to_repair` (`pool_service.dart:354-365`).
11. **UX-11 · Numbers that can lie, UI half** (`INEFFICIENCIES.md:186-193` items 15,16,19):
    (a) ~~ghost copies counted as redundancy (`D2`)~~ **fixed / doc stale** — `underReplicated`
    now counts only `STORED` copies on `ALIVE`/`SUSPECT` holders via the `LEFT JOIN`
    (`replica_repository.dart:61-81`, doc comment names D2 explicitly) and that feeds
    `degradedChunks` → health (`pool_coordinator.dart:665-675`); `INEFFICIENCIES.md:30` still calls
    D2 "Broken: repair queue ignores holder liveness" — **that line is stale**. No UI work left
    here except keeping the banner copy in step with a now-more-honest `AT RISK`;
    (b) `total_quota` only advances when someone opens the screen (`D29`,
    `pool_router.dart:106-114` + `pool_coordinator.dart:309` deliberately no timer) → **the headline
    can count capacity on devices that are gone exactly when nobody is watching**; (c) `allOffline`
    with `quotaExceeded=false` can show `0 free` + `usedFraction 0` with no "at risk" copy
    (`INEFFICIENCIES.md:193`) — partly mitigated by the OFFLINE banner copy (`pool_health_banner.dart:169-170`),
    needs a test.
12. **UX-12 · `setLastError` silently drops messages >300 chars to `NULL`** (`INEFFICIENCIES.md:163`
    D27; still `contributor_repository.dart:93-99`) → a long failure reason shows as "no error" in
    the row that UX-5 would render.
13. **UX-13 · `_healthFor` can report `AT RISK` with no hint that the only contributor is also
    suspect** (`INEFFICIENCIES.md:162` D26; `pool_coordinator.dart:684-696`) — banner copy for
    AT RISK assumes a reconnectable device (`pool_health_banner.dart:168`).
14. **UX-14 · Deleting a file never frees pool quota** (`INEFFICIENCIES.md:105-107` D25;
    `deleteChunksForFile`'s only caller is `pool_storage.dart:308`, and `pool_storage` itself has
    **no production caller** — see contradiction 4) → **"the pool reports full while the user
    deleted everything"**, i.e. the quota-exceeded card (A15) can fire for no visible reason.
15. **UX-15 · Status chips cannot express the promised state machine** (`FEATURES.md:170,252`):
    no `DRAINING`, no `pause`, no `set as registry` (B3/B14). Revoke is not blocked while chunks are
    unrepaired, so the UI can say "revoking" while redundancy silently drops (`INEFFICIENCIES.md:44,46`).
16. **UX-16 · `≈ … updated Xs ago` / `SUSPECT dimmed but in total`** (`CONSULT.md:262-264`) — both
    unbuilt (C3, C4).
17. **UX-17 · Docs-promised but unreached screens**: Help center/FAQ (E7), Conflict resolver (E8),
    Audit-log filtering+search (E9), Custom page transitions (E13), High-contrast mode (E15).
    Each has a finished widget that no route mounts — either mount them or descope them in README.

### From the `INEFFICIENCIES.md` ordered fix backlog (top 15, `:220-236`) — UI-related status

| Backlog # | Item | UI-related? | Status today |
|---|---|---|---|
| 1 | Repair queue counts usable copies (`D2`/`D7`) | no (server) → feeds the donut | **done** — `replica_repository.dart:61-81` (`LEFT JOIN`, only `STORED` on `ALIVE`/`SUSPECT`), doc comment names D2; feeds `degraded_chunks`/health (`pool_coordinator.dart:665-675`). `INEFFICIENCIES.md:30` still calls it broken. |
| 6 | Wire the pool screen to a real loader (`D13`) | **yes** | **done** — `router.dart:87-118`, `pool_service.dart:277` |
| 7 | Stop the UI double-subtract / ignore-reserved + add the "reserved" line (`D12`) | **yes** | **done** — `pool_models.dart:255-269`, `pool_capacity_card.dart:136-139` |
| 12 | Pool GC on file delete (`D25`) | **yes (user-visible symptom)** | **open** → UX-14 |
| 13 | Contributor agent invoked from the Contribute CTA (`D14`) | **yes** | **done** — `router.dart:101-111`, `client/services/contributor_agent.dart` |
| 14 | Router+coordinator tests for write/read/repair paths | test | **done** — `test/unit/pool_writepath_test.dart` |
| 2,3,4,5,8,9,10,11,15 | reserve failure, register dedupe, revoke wipe, ledger-owned `used_bytes`, https+fingerprint, atomic commit, repair re-entrancy, idempotent retry, scope+nonce | no (server) | not re-verified here. **D8 partial** (`RESEARCH/STATUS.md:27`: cleartext `http://` register still accepted); **D9/D10 rejected/skipped** (`STATUS.md:27`) vs still listed open in `INEFFICIENCIES.md` |

---

## Rules I must not break

Quoted with source. Category order: copy voice → honesty/numbers → accessibility → motion → haptics →
theme/visual → layout/geometry → performance/architecture → never-do-X.

### R1 · Copy voice and language

1. **Sentence case, honest, no exclamation mark**; vocabulary: `pooled / contributes / uses /
   offline / joining / revoke / promote`. — `RESEARCH/DESIGN.md:205`
2. **Prefer "device" over "node" in UI** ("save `node` for Settings/docs"). — `RESEARCH/DESIGN.md:206`
3. **Recency language everywhere: `last seen 12m ago`, not a raw timestamp.** — `RESEARCH/DESIGN.md:206`;
   also README:285-286 "lists speak in `2h ago`, details keep exact dates".
4. **Errors name the fix and offer Retry.** — README:282; enforced on the pool sheet
   (`contribute_sheet.dart:769-790`); "Revoke/promote … silently do nothing instead of erroring —
   violates 'errors name the fix'" — `INEFFICIENCIES.md:181`.
5. **Every refused write names the fix**: `Pool full — free 1.4 GB or raise a contributor cap`. —
   `RESEARCH/FEATURES.md:182`
6. **No dead ends** — deletes undoable, trash states its safety window, offline mode says so honestly. — README:282-283
7. **Never a healthy-looking total while a member is missing.** — `RESEARCH/FEATURES.md:169`
8. **Staleness must be visible, not inferred** (show `last seen`, `Last sync 12 s ago`). —
   `RESEARCH/FEATURES.md:173`
9. **Don't make the sum clever, make it obvious**; never show a magic number — show the *effective*
   pool: `20 GB usable now · 30 GB when Laptop returns`. — `RESEARCH/FEATURES.md:111,179`
10. **A usage number must equal the sum of what the registry can reach, or be labelled "estimated".** — `RESEARCH/FEATURES.md:180`
11. **A pool with zero contributors must not render as `0 B used, all good` — it must render the
    onboarding state.** — `RESEARCH/FEATURES.md:181`
12. **Ambiguity rule for a dimmed contributor:** "while a contributor is `SUSPECT` show it dimmed but
    keep it in the total until `DEAD`". — `RESEARCH/CONSULT.md:264`
13. **The UI must show `revoking… (re-replicating N chunks)`** — revocation is not instant. — `RESEARCH/CONSULT.md:71-72`
14. **The number/`updated Xs ago` label:** "display `≈` + `updated Xs ago`". — `RESEARCH/CONSULT.md:263`
15. **Progressive onboarding:** a 10-second intro once, then features teach themselves through empty
    states and contextual hints. — README:288-289
16. **Trust is visible** — show the scorecard, pinned-certificate flow and `verified` badges instead
    of claiming safety. — README:286-288
17. **A panel that doesn't change what the user does is decoration** (Ceph rule — kill KPI cards
    that carry no decision). — `RESEARCH/DESIGN.md:13`; operationalised as "threshold the number
    (green/amber/red) instead of adding a fifth KPI card" — `RESEARCH/DESIGN.md:211`

### R2 · Honesty of numbers (never a lying total)

18. **Totals are always derived, never accumulated in the UI**; a "pool total" number is never
    stored. — `RESEARCH/CONSULT.md:241-248`; `lib/features/pool/pool_models.dart:8-11` repeats it.
19. **Compute the donut in ONE query inside ONE transaction so the number and the ring can never
    disagree.** — `RESEARCH/CONSULT.md:262`; violated by the current 4-read `snapshot()`
    (`INEFFICIENCIES.md:115-117`, D11).
20. **Consume the host's `available_quota` / `free_bytes` verbatim — never recompute in the UI.** —
    `INEFFICIENCIES.md:95` (D12 fix), implemented at `pool_models.dart:255-269`.
21. **Show `reserved` bytes separately on the pool screen.** — `RESEARCH/CONSULT.md:152-153`
22. **Registry ledger = truth, contributor reports = advisory**; logical bytes counted once, replica
    overhead a separate line. — `RESEARCH/FEATURES.md:204-207`
23. **The slider's maximum is this device's real free space — never fabricate it; an unknown answer
    must block the sheet, never become a made-up maximum.** — README:80-81;
    `pool_screen.dart:61-65,348-356`.
24. **Never delete the only good copy**; quarantine, don't delete; copy-before-delete. —
    `RESEARCH/FEATURES.md:123,145,147`

### R3 · Accessibility

25. **Text ≥ 4.5:1; chart elements ≥ 3:1 vs background *and* vs adjacent segment (WCAG 1.4.11).** —
    `RESEARCH/DESIGN.md:66`
26. **Never encode meaning by hue alone** — every segment also gets a legend row with name + bytes;
    offline segments drop to **0.30 alpha** so greyscale still reads. — `RESEARCH/DESIGN.md:66-69`
27. **Amber/lime text on dark: use `#111111` if placed *on* the fill.** — `RESEARCH/DESIGN.md:69`
28. **Semantic label on the donut** (`Semantics(label: 'Pooled capacity …', image: true)`) with
    `excludeSemantics: true` internally. — `RESEARCH/DESIGN.md:199-200`
29. **Every icon-only control gets a `tooltip`.** — `RESEARCH/DESIGN.md:201`
30. **Hit targets ≥ 44px.** — `RESEARCH/DESIGN.md:202`
31. **Live-region announcements for state changes** (`SemanticsService.announce('Pool degraded, 1
    device offline')`) — and **announce once per state entry, never per rebuild**. —
    `RESEARCH/DESIGN.md:203`; implemented `pool_health_banner.dart:114-141`, guard rule also at
    `pool_screen.dart:79-82`.
32. **Reduced motion**: wrap animations in `ReducedMotionWrapper` / `MediaQuery.disableAnimations`;
    durations collapse to `Duration.zero` and count-ups jump to the final value. —
    `RESEARCH/DESIGN.md:185-188`; README:61 promises reduced-motion support.
33. **High-contrast mode is a promised capability** (`MediaQuery.highContrast`). — README:61;
    `lib/widgets/accessibility.dart:93-118` (currently unmounted — E15).

### R4 · Motion

34. **The exact motion table**: count-up `700ms easeOutExpo` + `tabularFigures`, re-run only if
    `|Δ| ≥ 0.5%` of total; ring sweep `600ms easeOutCubic`; join rebalance `600ms easeOutCubic` +
    spark `900ms easeInOut`; tile entrance `320ms` staggered `60ms`; segment focus `180ms easeOut`;
    status change `200ms easeInOut`, **no bounce, no shake**; degraded banner `AnimatedSize 240ms
    easeOutCubic` + 12px slide; quota halo `400ms easeOut`. — `RESEARCH/DESIGN.md:177-183`
35. **Never let `duration: 0` break `AnimationController`** — guard with
    `if (reduce) return finalValue;` before constructing. — `RESEARCH/DESIGN.md:187-188`
36. **Never animate on every poll tick**; **calm default view / progressive disclosure / generous
    whitespace is functional** (2026 dashboard trend). — `RESEARCH/DESIGN.md:214,16-19`
37. **One ring, one number, list as the legend.** — `RESEARCH/DESIGN.md:210`

### R5 · Haptics

38. **The map**: `light` = tile tap/legend chip · `selection` = quota slider, filter change ·
    `medium` = revoke confirm, promote · `success` = join complete, quota raised · `error` = quota
    exceeded, join failed, revoke failed. — `RESEARCH/DESIGN.md:192-194`
39. **All haptic calls fire on the gesture, not after the async result** (optimistic feedback). —
    `RESEARCH/DESIGN.md:194-195`; README:280 "haptics confirm what fingers do".
40. **Never haptic on a passive status refresh.** — `RESEARCH/DESIGN.md:195`
41. **Error haptic fires once per state entry, never per rebuild.** — `RESEARCH/DESIGN.md:165-166`;
    implemented `pool_screen.dart:130-137`.
42. **Destructive = `heavy` on the gesture**, confirmation afterwards. — `RESEARCH/DESIGN.md:138-139,193`

### R6 · Theme / visual system

43. **"Must sit inside the existing design language (`DESIGN.md`: deep-teal `#0E7C7B` seed,
    8/12/16/24/28 radii, M3 `englishLike2021`, glassmorphism, AMOLED, haptics) — do *not* invent a
    second visual system."** — `RESEARCH/DESIGN.md:4-6`
44. **Keep Roboto / `Typography.englishLike2021` — "a second UI font would break every screen."** —
    `RESEARCH/DESIGN.md:23-24`; `DESIGN.md:6`.
45. **Roboto Mono only for byte figures in columns, "Never Mono for prose."** — `RESEARCH/DESIGN.md:34`
46. **One component-theme builder for light+dark; no duplicated literals.** — `DESIGN.md:35`;
    implemented as one builder (`lib/app/theme.dart:7`); pool palette literals are centralised once
    in `lib/widgets/pool_donut.dart:14-46` (do not re-declare them in a widget).
47. **Radii scale: `8` chips/mini-bar, `12` buttons/inputs, `16` cards, `20` hero pool card, `24`
    bottom sheet, `28` search.** — `RESEARCH/DESIGN.md:76-77`; `DESIGN.md:5`.
48. **Spacing scale `4/8/12/16/20/24/32`; card padding 20, list-tile vertical gap 12, section gap 16,
    screen padding 16, hero card top padding 24.** — `RESEARCH/DESIGN.md:73-75`
49. **Mini bar height 10, radius 5 — identical to the existing `StorageMeter`; ring 168/120,
    strokeWidth 16/10, `StrokeCap.round`.** — `RESEARCH/DESIGN.md:77-78`
50. **No drop shadows — depth comes from `GlassCard(blur: 20, opacity: 0.15, borderColor:
    outlineVariant@0.2)`; AMOLED hero uses `surfaceContainer (#111111) @0.72`.** —
    `RESEARCH/DESIGN.md:79-82`
51. **Segment colours are assigned by stable slot index, never by status — colours must never
    reshuffle when a device goes offline.** — `RESEARCH/DESIGN.md:42-44`
52. **Reuse `StatusPill`, `SectionHeader`, `StorageMeter`, `EmptyState`, `GlassCard`, and
    `formatBytes` — "do not write a new formatter"** (`formatBytes` to TB). —
    `RESEARCH/DESIGN.md:212,117`; `DESIGN.md:36`.
53. **`AppLogo` gradient tile + soft shadow; `VaultFileIcon` 16% bg tint / 30% radius; `SkeletonList`
    6 shimmer-less rows for first paint.** — `DESIGN.md:9-17` (pool first paint reuses the shimmer
    language: `pool_screen.dart:413-446`).

### R7 · Layout / interaction

54. **Thumb-first: 5 bottom tabs, bottom sheets, FAB; destructive actions live away from thumbs.** —
    README:283-285; `RESEARCH/DESIGN.md:140-141` (destructive primary action below the sheet fold).
55. **Quota edits are bottom sheets, never dialogs.** — `RESEARCH/DESIGN.md:137`
56. **Hide infrequent actions behind a `PopupMenuButton` — "never on the surface"** (edit quota /
    token / audit). — `RESEARCH/DESIGN.md:18-19`
57. **The quota sheet carries exactly one decision** (Hick's law), ending on success haptic +
    confirmation (peak–end). — `RESEARCH/DESIGN.md:74-76` (contribute sheet doc).
58. **Keep the 3 stat rows at `0 GB` in the empty state so the layout doesn't jump.** —
    `RESEARCH/DESIGN.md:150-151`
59. **The hero card stays `GlassCard` radius 20 / padding 20 and is the page anchor; the hero number
    is `fontSize 40, w800, letterSpacing -1.0`; uppercase micro-labels `labelSmall` w700
    `letterSpacing 1.2` in `primary`.** — `RESEARCH/DESIGN.md:91-97,30-37`
60. **Icons-only rows need shape + word, never hue alone** (reserved line: clock icon + `reserved`). —
    `RESEARCH/DESIGN.md:66-67`, applied `pool_capacity_card.dart:303-308`

### R8 · Performance / architecture

61. **Controllers live in `State.initState`, never inside `build`.** — `DESIGN.md:37`.
62. **Never force `Size(double.infinity, …)` on buttons — constrains desktop.** — `DESIGN.md:34`
63. **Don't block the serving isolate with UI-visible work / avoid N+1 and full-table scans on the
    status poll** — `INEFFICIENCIES.md:170-177` items 1-7 (snapshot = 4 round trips; `BEGIN IMMEDIATE`
    on reads; full scans per request; blocking file IO on the request isolate = "UI jank on the
    device that is also the host").
64. **Nothing may animate/rebuild on every poll tick** (see R4-36) — the screen polls via
    `RefreshIndicator` + 10s host-dashboard timer (`host_dashboard_screen.dart:25`).
65. **State haptics/announcements are once-per-entry, not per rebuild** (R5-41, R3-31).

### R9 · Structural / never-do-X (pool-specific)

66. ❌ **Donut-per-contributor; pie with >6 slices; rainbow gradients; legends without bytes;
    animating on every poll tick; new fonts, new radii, drop shadows; `Size(double.infinity, …)`
    on buttons.** — `RESEARCH/DESIGN.md:213-215`
67. ❌ **Don't invent a second visual system.** — `RESEARCH/DESIGN.md:5-6`
68. ❌ **No new trust root: all pool traffic rides the existing pinned-TLS channel with the
    contributor token.** — `RESEARCH/FEATURES.md:218`; `PROJECT.md:8` (note the README contradiction below).
69. ❌ **Never trust a contributor's claim** for accounting (host ledger authoritative); **never let
    `free_bytes` claims admit writes** — `RESEARCH/CONSULT.md:349`.
70. ❌ **Never show a healthy state while redundancy is actually 1-of-2** (ghost copies) —
    `INEFFICIENCIES.md:60`.
71. ❌ **No silent empty/zero states** (B10) and **no silent write failures** (B11).
72. ❌ **Don't run haptics/announcements from a passive refresh or a rebuild** (R5-40, R5-41).

---

## Test obligations

### What `TEST_PLAN.md` says must be verified (all of it is manual or pre-pool)

`TEST_PLAN.md:3-14` lists **automated** tests: `unit/file_names_test.dart`, `unit/cipher_test.dart`,
`widget/welcome_screen_test.dart`, `widget/common_widgets_test.dart`,
`integration/vault_integration_test.dart`. **This list is stale** — counted today the repo has
**22** `*_test.dart` files and **251** `test()`/`testWidgets()` calls:
`find test -name '*_test.dart' | wc -l` → 22; `grep -rhoE '^\s*(test|testWidgets)\(' test | wc -l` → 251.
Pool suites: `unit/pool_cipher`, `unit/pool_node`, `unit/pool_node_tls`, `unit/pool_coordinator`,
`unit/pool_service`, `unit/pool_api`, `unit/pool_writepath`, `unit/pool_node_test`,
`integration/pool_end_to_end`, `integration/pool_storage`, `widget/pool_ui`, `widget/pool_widgets`.
(`RESEARCH/STATUS.md:25` declared 249 and itself says "re-run the command instead of trusting the
figure"; `STATUS.md:29` claims `flutter test` 249/249 — both are one case-file behind today's 251.)

**Manual cases (`TEST_PLAN.md:16-91`)** — the UI ones you must keep aligned with automated tests:

- **Host Mode Flow H1-H10** (`:18-30`): Welcome → "Start Storage Node" opens Host Setup; storage
  location selector opens the file picker; device name + password fields accept input; Start →
  Host Dashboard with server running; **server URL displayed** (`http://192.168.x.x:8484`);
  **QR code visible**; **6-digit pairing code visible**; **Regenerate produces a new code**;
  storage info shows total / free / vault / trash sizes; Stop flips status to stopped.
- **Client Mode Flow C1-C26** (`:32-60`): Connect screen; URL + pairing code fields; Connect →
  Files root; New Folder dialog; folder appears; Upload File picker; upload queued and shown in the
  transfer screen with progress; upload completes and file appears; tap → preview with metadata;
  download queued; long-press → Rename dialog → name updates; long-press → Move folder picker →
  "Move Here" moves it; long-press → Delete confirmation → disappears; **Trash tab** shows it;
  restore works; delete-permanently works; **Empty Trash** works; **Devices tab** lists paired
  devices; **Storage tab** shows disk usage; **Settings tab** shows theme toggle + disconnect;
  **theme toggle flips light/dark**; Disconnect returns to Welcome; **search returns results**.
- **Upload/Download U1-U3, D1-D3** (`:62-71`): 10 MB upload shows progress in the Transfer Manager;
  **cancel during upload** cancels; **retry failed upload restarts from beginning**; download lands
  with correct content; **SHA-256 checksum matches the original**; cancel during download cancels.
- **Edge cases E1-E8** (`:72-83`): duplicate name auto-renamed `file (1).ext`; duplicate folder name
  auto-renamed; moving a folder into its own subfolder rejected with an error; root folder delete
  not allowed; invalid token → 401 / re-login; expired pairing code rejected; wrong password fails;
  **network disconnected → error message shown, retry available**.
- **Android A1-A5** (`:84-91`): APK installs; camera permission prompts for QR scan; QR scan
  populates the URL; upload from Android shows progress and completes; download saves to device
  storage.

### Gap you should close (documented, not inferred)

- **`TEST_PLAN.md` contains zero pooled-cloud cases** even though `PROJECT.md:5-17` makes the pool
  this version's feature list and `PROJECT.md:20` requires it "covered by tests". Manual pool cases
  that the docs imply but nobody wrote down: contribute this device (slider capped at real free
  space; unknown free space blocks the sheet), second device joins → ONE summed number + segmented
  donut, degraded banner when a device goes offline (with `last seen`), `AT RISK` on a
  single-contributor pool (README:305-308), quota-exceeded card + "Manage space", join >15s →
  `Retry`, revoke → re-replication progress, quota resize, `How pooling works` sheet, theme
  light/dark contrast on the ring, reduced-motion pass over the whole pool screen.
- Keep automated tests aligned with **R3/R4/R5**: the existing suite already covers state words,
  repair row, announcements, reduced motion, tooltips, `reserved` line, and the mid-tween frame
  (`test/widget/pool_ui_test.dart`) — the two known animation bugs (`Tween<int>` returning double,
  decimal labels overflowing the 168px ring) were only caught by tests that pump *through* the
  animation (`RESEARCH/STATUS.md:29`); keep that style.
- `TEST_PLAN.md` is **not** in `PROJECT.md`'s done criteria (`:24-25` lists README + STATUS only) —
  that is why it drifted.

---

## Sources

| Claim group | Source doc(s) |
|---|---|
| v2.4.0 feature list + done criteria | `PROJECT.md:5-25` |
| Pool feature map, competitor-derived UI patterns, avoid-list, backlog ordering, failure modes | `RESEARCH/FEATURES.md:9-47` (diff), `:129-160` (features), `:164-183` (UI patterns/avoid), `:186-241` (failure modes), `:244-255` (backlog) |
| Widget-by-widget spec: card, donut, contributor list, 4 states, motion table, haptics map, a11y+copy, do/don't | `RESEARCH/DESIGN.md:1-215` |
| UI sentences in the consult: revoking-progress, reserved line, one-transaction donut, `≈ … updated Xs ago`, SUSPECT dimmed | `RESEARCH/CONSULT.md:71-72,151-153,262-264` |
| Spec-vs-code matrix, defect list D1-D29, inefficiency lists (performance / UX friction / lying numbers), test gaps, ordered fix backlog | `RESEARCH/INEFFICIENCIES.md:15-251` |
| Later decisions that supersede parts of the above (D8 partial, D9 rejected, D10 skipped) | `RESEARCH/STATUS.md:27` |
| Current build/test/deploy state | `RESEARCH/STATUS.md:19-30` |
| Design-language rules (identity, components, screens, 4 rules) | `DESIGN.md:1-37` |
| Public promises (v1.3→v2.4 feature bullets, pooled-cloud section, security model, experience design, honest status) | `README.md:19-103,162-204,206-238,275-309` |
| Manual + automated test obligations | `TEST_PLAN.md:1-91` |
| Platform/design assumptions (some stale — see contradictions) | `ASSUMPTIONS.md:1-54` |
| Build/verify commands | `BUILD.md:1-50` |
| Everything marked "Evidence (`lib/`)" | direct `grep`/read of `lib/**` and `test/**` on 2026-09-28 |

### Contradictions between docs (also findings)

1. **`RESEARCH/INEFFICIENCIES.md` is stale in both directions.** D12 (`:93-95`), D13 (`:97-99`,
   plus UX friction 8 `:180`, backlog #6/#7) and **D2** (`:30`, backlog #1) are **fixed**
   (`pool_models.dart:255-269`, `router.dart:87-118`, `replica_repository.dart:61-81`), while D9/D10
   are listed as open defects (`:89-91,:111-113`) but **rejected/skipped** by `RESEARCH/STATUS.md:27`.
   Read the matrix with the STATUS line next to it.
2. **Pinned TLS vs plain HTTP.** `PROJECT.md:8` / `RESEARCH/FEATURES.md:218` / `RESEARCH/CONSULT.md:218`
   require the pinned-TLS channel with no new trust root; `README.md:196-204` documents that "a
   contributor node serves plain HTTP on the LAN by default … an endpoint registered as `http://`
   has no TLS and therefore no pin", and `RESEARCH/STATUS.md:27` leaves the cleartext half of D8 open.
3. **`ASSUMPTIONS.md` vs `README.md` vs code** (three stale statements): `ASSUMPTIONS.md:30` "Host
   Mode on Android … not implemented" vs README:110,131 foreground service (`lib/server/server.dart:114`);
   `ASSUMPTIONS.md:32` "Transfer tasks are in-memory, do not persist across restarts" vs README:124
   "Transfers survive app restarts" and `transfer_manager.dart:160-180` persistence; `ASSUMPTIONS.md:36`
   "server runs on a single isolate" vs README:292 "background isolate" and `host_runner.dart:88`.
4. **README promises an end-to-end pooled cloud; the file path into the pool does not exist.**
   README:76-90 / `PROJECT.md:20` ("end-to-end") vs `lib/server/pool/pool_storage.dart` having **no
   production caller** and `transfer_manager.dart` never touching the pool — the UI can never show a
   non-zero "used" arc from real data.
5. **`RESEARCH/DESIGN.md:169` "single colored word above everything: `ONLINE`…" vs
   `pool_screen.dart:160-164`** which hides that word exactly when the pool is healthy (and README:82-83
   repeats the four-word promise).
6. **`TEST_PLAN.md` vs everything else:** 5 automated files listed vs 22 present (251 cases); 0 pool
   manual cases vs `PROJECT.md`'s entire v2.4.0 feature list.
7. **README "0-100 security score with tips" (`:66`) vs the built `'$pass/$total'` with no tips**
   (`host_dashboard_screen.dart:868`) — README also promises an audit log "with filtering and search"
   (`:67`) whose widget is never mounted (E7-E10).
