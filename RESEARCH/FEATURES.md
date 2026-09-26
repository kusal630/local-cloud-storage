# FEATURES — v2.4.0 Pooled Data Cloud (competitive research)

**Run:** 2026-09-26 · **Deliverable:** competitor feature map + pooled-cloud feature list + pool UI patterns + failure modes
**Tools used this run:** Firecrawl (priority #1) — `firecrawl search` × 8, `firecrawl scrape` × 5 (5/10 web-fetch budget used). No fallback needed; nothing below is written from memory-only sources except where explicitly marked *(knowledge)*.
**Context files read:** `PROJECT.md`, `RESEARCH/STATUS.md`, `RESEARCH/CONSULT.md` (registry, capacity races, placement, summed-total, encryption, threat model already analyzed there — this file is the *external feature evidence* layer and does not repeat those designs).

---

## 0. Diff vs. what is already built (STATUS.md / README / lib/)

| Pooled-cloud capability | Built today? | Where it would live |
|---|---|---|
| Storage Node + client, pinned TLS, tokens, Argon2id | ✅ (v1.x–v2.3.0) | `lib/server`, `lib/core/auth` |
| Storage donut + storage screen (single device) | ✅ (v1.7/1.8 wave) | `lib/features/storage` |
| Audit log, security score, session manager, offline manager, conflict resolver | ✅ (v2.0–v2.1 waves) | `lib/features/settings`, `lib/data` |
| Per-vault quota, trash retention, content-addressed dedupe by checksum | ✅ (host-side only) | `lib/data` |
| **Contributor registry / join / leave / heartbeat** | ❌ | new `lib/server/pool` |
| **Summed multi-device capacity accounting** | ❌ | registry ledger + `lib/features/storage` |
| **Chunk placement across contributors** | ❌ | `lib/client` uploader + server |
| **Replica tracking + repair on node failure** | ❌ | background repair worker |
| **Per-contributor quota enforcement / reservation** | ❌ | pool write path |
| **Pool management screen (list/revoke/promote)** | ❌ | `lib/features/pool` (new) |
| `grep -r "pool" lib/` | only `connection_pool.dart` (HTTP, unrelated) | — |

Everything in §3 below is net-new. `RESEARCH/STATUS.md` last line: *"next: map server/quota layer"* — §3 is that map.

---

## 1. Top 10 pooled / decentralized storage competitors

Dimensions: **capacity aggregation · chunk placement · replication · repair on node failure · quota accounting**.

### 1. Storj — the closest analogue to "many disks, one bucket"
- **Capacity aggregation:** independent storage nodes each contribute free disk; the *satellite* (coordinator) treats the whole overlay as one object store. Users see a single bucket/namespace; node selection is weighted by free space + uptime + audit score — no user-visible "pool" math. *(evidence: storj.dev concepts, forum)*
- **Chunk placement:** object → 64 MiB segments → Reed–Solomon erasure coding **k=29, n=40** pieces; pieces are placed on *distinct* nodes chosen from the overlay with diversity constraints (no two pieces of a segment on one node). *(forum: "Currently the ratio is 29…")*
- **Replication:** none — pure erasure coding. Their own docs argue replication ties durability to expansion factor, whereas EC lets you raise durability at fixed 2× overhead by spreading over more nodes. *(scrape: storj.dev/learn/concepts/file-redundancy)*
- **Repair on node failure:** random **audits** (hash challenges) build an audit score; below **60 %** a node is **suspended** (gets no new data, and *can lose data when repair is triggered*); still bad at end of review period → **disqualified**. The repair worker re-encodes a segment once its healthy-piece count drops too low, pulling surviving pieces from healthy/suspended nodes onto new ones. *(forum.storj.io/t/what-is-suspension-audit/9683, /t/questions-regarding-audit-and-online/23110, storj.dev/node/faq/why-is-my-node-disqualified)*
- **Quota accounting:** pay-as-you-go **storage byte-hours + egress** billed by the satellite; node payout ∝ bytes stored × time + bandwidth served. Per-bucket usage is authoritative on the satellite side. *(knowledge + Storj docs)*

### 2. Filecoin (Lotus / Curio) — economic deals, not a summed pool
- **Capacity aggregation:** providers publish capacity + ask price on-chain; the "pool" is a market. A client aggregates capacity by making deals, not by reading one number. Capacity is bounded by **pledge collateral** and hardware. *(scrape: filecoin.io/blog/how-storage-and-retrieval-deals-work)*
- **Chunk placement:** file → UnixFS DAG → CAR → **File Piece**, split to fit a **sector** (32/64 GiB). The *client* picks the miner (price/reputation) — placement is negotiated, not automatic, and never rebalanced by the network.
- **Replication:** one physical replica per deal by default; real redundancy = *multiple deals with different miners*. **PoRep** proves each replica is physically unique. *(docs.filecoin.io glossary)*
- **Repair:** **WindowPoSt** submitted every proof period; a missed proof = **fault** → slashing/fee; a sector faulty **42 consecutive days** is auto-removed with a termination fee (FIP #712). There is **no automatic network-level repair** — the client or provider must re-deal. Data is "audited daily, errors cause a fault, therefore SPs have an incentive to repair or get penalized." *(filecoin.io blog, github.com/filecoin-project/FIPs/discussions/712)*
- **Quota accounting:** on-chain sector/deal state; price per GiB per 30 s epoch; duration ≥ 180 days; collateral locks capacity.

### 3. Sia (renterd) — closest *behavioral* match to our repair goal
- **Capacity aggregation:** the renter scores the whole host pool (price, uptime, score) and presents one logical volume; capacity = sum of hosts it chose to contract.
- **Chunk placement:** every file split into **30 segments**; Reed–Solomon **any 10 of 30** recover the file; each segment's pieces go to *different* hosts worldwide. *(scrape: docs.sia.tech/legacy/renting/is-my-data-secure)*
- **Replication:** erasure coding only (10/30 default) — no full copies.
- **Repair:** the renter's **redundancy module** continuously monitors redundancy; docs state plainly: *"when hosts go offline, Sia automatically starts to re-duplicate them again."* So: detect (per-host availability) → re-download surviving pieces → re-upload to replacement hosts. **Automatic, no user action.** ← the behavior LocalVault feature #10 promises.
- **Quota accounting:** funds locked per contract; renter-level **allowance** budget; host collateral; spend tracked per host/contract.

### 4. Arweave — pay-once permanence, no explicit repair
- **Capacity aggregation:** miners/gateways each hold chunks; network capacity = whatever miners hold. Users see one permaweb.
- **Chunk placement:** 256 KiB chunks in a blockweave; new miners are incentivized to hold large slices of history because **SPoRA** requires proving access to a random *recall* block. Placement is effectively "everyone stores overlapping history." *(docs.arweave.org/developers/development/overview)*
- **Replication:** no replication factor. Redundancy is **emergent/lazy**: the endowment pays assuming storage gets cheaper, so the network copies data as needed over time.
- **Repair:** no repair daemon. If a chunk lives on few miners and they vanish, recovery relies on remaining copies + gateway caching; this is Arweave's known durability soft spot (worth noting as a *anti-pattern* for us: never rely on "someone will copy it later").
- **Quota accounting:** single upfront upload fee derived from DAG size via the endowment; no quota, no expiry.

### 5. Safe Network (MaidSafe) — pure "device joins, data replicates"
- **Capacity aggregation:** every joined device contributes; capacity is the sum of all vaults. Joiners pass a **resource test**. *(scrape: jpl1.github.io/safenetworkprimer)*
- **Chunk placement:** data split into chunks, hashed, stored on the **close group** by XOR distance — no central allocator.
- **Replication:** each chunk replicated to a **minimum of 4** nodes (close-group members), with extra copies steered to less-loaded nodes for balance. *(silvertonconsulting.com/tag/safe-network)*
- **Repair:** **self-repair** — holders notice nodes leaving and re-replicate chunks to new close-group members; contributors are rewarded per stored chunk. Fully autonomous.
- **Quota accounting:** safecoin spent to store; nodes earn for holding; user balance caps usage.

### 6. Ethereum Swarm — postage stamps as quota
- **Capacity aggregation:** each node keeps a **reserve** sized by *storage radius* (proximity order); network capacity = Σ reserves.
- **Chunk placement:** hash-addressed chunks land with the nodes whose **neighborhood (PO)** matches the chunk's — i.e. all nodes of a neighborhood hold it.
- **Replication:** target replication factor per neighborhood, set dynamically by an **oracle** from supply/demand (stamp price moves when too few/many nodes replicate). *(solarpunk.buzz Arweave-vs-Swarm comparison, docs.ethswarm.org glossary)*
- **Repair:** nodes reconcile their reserve with neighbors; if the target node is offline, neighbors hold the chunk for it *(medium/geekculture intro)*. Under pressure, lowest-utilization/lowest-timestamp stamp batches are evicted.
- **Quota accounting:** **postage stamp** = prepaid capacity × duration, burned in BZZ; batch utilization meter; expired stamps ⇒ data eligible for eviction. *This is the cleanest "quota is an object you can buy and watch run out" model in the set.*

### 7. Tahoe-LAFS — the "is my file actually safe?" metric
- **Capacity aggregation:** a grid of helper servers; one flat namespace; capacity = Σ helpers.
- **Chunk placement:** client picks N servers via a **histogram** so shares spread out; default **3-of-10** erasure coding; each share to a distinct server. *(github tahoe-lafs/docs/architecture.rst)*
- **Replication:** erasure coding only (configurable per file/dir).
- **Repair:** explicit **check & repair** (deep-check) run by the client — verify share count, fetch, re-encode, re-upload. No background daemon by default.
- **Quota accounting:** none network-wide; each helper enforces its own disk limit.
- **The gem — `servers-of-happiness`:** an upload is only declared healthy if a **bipartite matching** over (peer × share) yields ≥ *happy* peers such that any *k* of them reconstruct the file. It exists because count-only health ("10 shares exist") passed files whose shares all sat on **one or two peers**. With 3-of-10 and happy=7, the file survives 4 peer failures. *(scrape: tahoe-lafs.readthedocs.io/en/latest/specifications/servers-of-happiness.html)* → **directly applicable as our placement-diversity test.**

### 8. Ceph — reference for summed capacity + automatic repair at scale
- **Capacity aggregation:** CRUSH map maps a logical pool onto OSDs **weighted by capacity**; one pool = one summed number over the cluster.
- **Chunk placement:** deterministic **CRUSH** placement (pseudo-random, topology-aware rules) — no central allocation table, so placement is recomputable from config alone.
- **Replication:** per-pool replica count (2/3) **or** erasure-coded pools.
- **Repair:** self-healing — degraded PGs trigger recovery/backfill to new OSDs; **scrub** catches bit-rot; `ceph -s` reports `degraded` / `undersized` / `backfilling` explicitly. *(knowledge — standard Ceph semantics; not fetched this run)*
- **Quota accounting:** per-namespace/pool quotas + per-pool usage stats.

### 9. ZFS / TrueNAS — the pool UI language everyone already reads
- **Capacity aggregation:** vdevs concatenated; pool free = Σ vdev free.
- **Chunk placement:** stripe across vdevs — **and data is never restriped** when you add a disk (only new writes use it).
- **Replication:** mirror or RAIDZ parity per vdev.
- **Repair:** **resilver** (rebuild a replaced disk, prioritized over normal I/O), **scrub** (proactive checksum verification), pool state **DEGRADED** while a device is missing but still serving; hot spares. *(reddit r/zfs, forum.proxmox.com "meaning of DEGRADED state")*
- **Quota accounting:** dataset quotas/reservations.
- **Lesson for us:** DEGRADED ≠ DOWN. The pool keeps serving reads with a missing member, shows exactly which member and what's being rebuilt, and never silently pretends to be healthy. Our pool screen should copy this vocabulary wholesale.

### 10. Unraid — the consumer "plug in any disk, get one bigger pool" UX
- **Capacity aggregation:** add disks of *any* size, one or two parity disks; usable ≈ Σ data disks. Capacity grows by inserting a disk — no rebalance.
- **Chunk placement:** each file goes to the **single data disk with the most free space** (simple, explainable policy); shares are *allocation policies*, not containers.
- **Replication:** parity computed across all data disks (1- or 2-disk fault tolerance).
- **Repair:** parity check → **rebuild** a failed disk from parity; array shows `DEGRADED` until rebuilt; "TrustParity" mental model. *(knowledge — Unraid array semantics; not fetched this run)*
- **Quota accounting:** per-share **minimum/free-space** settings that steer placement away from full disks.
- **Lesson for us:** users understand "each file lands on one disk, parity covers you" far better than erasure coding. For a 3-device household pool, **R=2 replication of small chunks** beats k/n EC on explainability, and matches Sia's "just re-duplicate when a host drops."

### Honorable mentions (not in the top 10, but mined for one idea each)
- **SeaweedFS** — master assigns volumes, replication factor R, volume-server **healing** re-replicates under-replicated volumes.
- **MinIO** — erasure N/2+2 per object, background **healing** scanner rewrites under-parity objects.
- **Nextcloud external storage** — per-mount quota shown in one combined usage bar (and users complain when the bar *doesn't* reflect external storage — a warning about lying totals).
- **IPFS Cluster** — pin allocation balanced across peers with `ipfs pin ls` as the single source of truth for "what's where."
- **Google One family pool** — one bar, segmented by service; and a Reddit thread complaining family storage math (85 GB + n×15 GB) is *confusing* → don't make the sum clever, make it obvious.

---

## 2. What the field actually converges on (pattern summary)

| Concern | Converged answer | Adopt? |
|---|---|---|
| Redundancy | Erasure coding for wide internet swarms (Storj 29/40, Sia 10/30, Tahoe 3/10); **replication for small trusted sets** (Safe 4×, ZFS mirror, Unraid parity, Ceph 2–3×) | ✅ **R=2 replication** for 2–5 household devices; EC is overkill and unexplainable |
| Placement | Must be *diverse* (no file's copies on one node) and *capacity-aware*; Tahoe proves count-only placement is a trap | ✅ capacity-weighted + explicit diversity rule + happiness-style health check |
| Detection of failure | Storj **audits** (probabilistic challenges), Ceph **scrub**, ZFS **scrub**, Filecoin **periodic proofs** | ✅ periodic SHA-256 spot-audits + verify-on-read |
| Repair trigger | Sia: automatic redundancy module; Storj: repair worker on unhealthy segments; Ceph: automatic; Tahoe: manual | ✅ **automatic** (Sia/Ceph model) — a household will never run `check&repair` |
| Repair safety | Never let a degraded read look healthy; never lose the last copy during repair (read-before-delete ordering) | ✅ repair copies first, deletes second |
| Quota | Prepaid/reserved before write (Swarm postage, Filecoin deal funds, Sia contract funds) — **never** "write then count" | ✅ reserve → write → commit/rollback (matches CONSULT §2) |
| Pool health UI | ZFS `DEGRADED`, Ceph `degraded/backfilling`, Syncthing "not connected for a long time" | ✅ one honest headline state + per-member rows |

---

## 3. Concrete pooled-cloud feature list

Entry format: `## <Feature> | competitor: <name> | evidence: <link/tool> | impact: H/M/L | effort: easy/med/hard`
`tool` = `firecrawl-search` or `firecrawl-scrape` (no fallback used this run).

## Contributor registry (join/leave/heartbeat over pinned TLS) | competitor: Storj overlay nodes | evidence: https://storj.dev/learn/concepts/definitions (firecrawl-scrape) | impact: H | effort: med
## Capacity advertisement (free bytes + per-device cap, refreshed on heartbeat) | competitor: Unraid / Ceph CRUSH weights | evidence: https://forum.proxmox.com/threads/meaning-of-degraded-state-on-zfs-pool.113960/ (firecrawl-search) | impact: H | effort: easy
## Single summed pool number + segmented donut (one bar, per-contributor slices) | competitor: Google One shared family pool | evidence: https://support.google.com/googleone/answer/9004015 (firecrawl-search) | impact: H | effort: easy
## Capacity-weighted chunk placement across contributors | competitor: Storj / Ceph CRUSH | evidence: https://storj.dev/learn/concepts/file-redundancy (firecrawl-scrape) | impact: H | effort: med
## Replication factor R=2 (two distinct contributors per chunk, no EC) | competitor: Safe Network (4×) / Sia "auto re-duplicate" | evidence: https://docs.sia.tech/legacy/renting/is-my-data-secure (firecrawl-scrape) | impact: H | effort: med
## Placement diversity rule + health metric (reject layouts where copies land on one device) | competitor: Tahoe-LAFS servers-of-happiness | evidence: https://tahoe-lafs.readthedocs.io/en/latest/specifications/servers-of-happiness.html (firecrawl-scrape) | impact: H | effort: med
## Quota reservation → write → commit / TTL rollback | competitor: Filecoin deal funds + Swarm postage | evidence: https://www.filecoin.io/blog/how-storage-and-retrieval-deals-work-on-filecoin (firecrawl-scrape) | impact: H | effort: med
## Per-contributor quota cap enforced on the contributor itself (never trust the planner alone) | competitor: ZFS dataset quota / Unraid share free-space | evidence: https://www.reddit.com/r/google/comments/98pjtm/ (firecrawl-search) | impact: H | effort: easy
## Writes refused when pool has no room (honest "pool full" before the first byte) | competitor: Swarm postage expiry / Sia allowance | evidence: https://docs.ethswarm.org/docs/references/glossary/ (firecrawl-search) | impact: H | effort: easy
## Periodic chunk audits (SHA-256 challenge per sampled chunk → health score per contributor) | competitor: Storj audits + suspension thresholds | evidence: https://forum.storj.io/t/what-is-suspension-audit/9683 (firecrawl-search) | impact: H | effort: med
## Automatic repair worker: under-replicated chunk → re-replicate to a healthy contributor | competitor: Sia redundancy module / Ceph self-healing | evidence: https://docs.sia.tech/legacy/renting/is-my-data-secure (firecrawl-scrape) | impact: H | effort: hard
## Copy-before-delete repair ordering (never delete the last good replica) | competitor: Storj repair worker | evidence: https://forum.storj.io/t/questions-regarding-audit-and-online/23110 (firecrawl-search) | impact: H | effort: med
## Degraded-read path: serve from surviving replica, flag file "1 of 2 copies", queue repair | competitor: ZFS DEGRADED / Sia | evidence: https://forum.proxmox.com/threads/meaning-of-degraded-state-on-zfs-pool.113960/ (firecrawl-search) | impact: H | effort: med
## Verify-on-read + quarantine of mismatching chunks (quarantine, don't delete) | competitor: Ceph scrub / Storj audits | evidence: https://storj.dev/learn/concepts/file-redundancy (firecrawl-scrape) | impact: H | effort: med
## Contributor status machine: ONLINE → DEGRADED → OFFLINE → DRAINING → REVOKED | competitor: Storj suspension→disqualification | evidence: https://storj.dev/node/faq/why-is-my-node-disqualified (firecrawl-search) | impact: H | effort: easy
## Pool health headline ("Pool DEGRADED — 2 of 3 contributors online; reads OK, writes paused") | competitor: ZFS pool state | evidence: https://www.reddit.com/r/zfs/comments/impacf/ (firecrawl-search) | impact: H | effort: easy
## Repair progress reporting ("Rebuilding replicas 3/12 · 4 min left", like resilver) | competitor: ZFS resilver | evidence: https://discourse.practicalzfs.com/t/is-an-automatic-resilver-after-scrub-finds-errors-normal/2271 (firecrawl-search) | impact: M | effort: easy
## Contributor list rows: icon, name, used/total, cap, status chip, last-seen, revoke, "set as registry" | competitor: Syncthing device list | evidence: https://github.com/syncthing/syncthing/issues/7703 (firecrawl-search) | impact: H | effort: easy
## Stale-device honesty ("Laptop last seen 3 h ago") instead of a silent stale total | competitor: Syncthing issue #7703 | evidence: https://github.com/syncthing/syncthing/issues/7703 (firecrawl-search) | impact: M | effort: easy
## Registry lease + fencing epoch (single writer; stale registry demoted to read-only shadow) | competitor: Ceph mon quorum / Filecoin on-chain state *(knowledge)* | evidence: RESEARCH/CONSULT.md §1 + https://docs.filecoin.io/reference/general/glossary (firecrawl-search) | impact: H | effort: hard
## Idempotent usage ledger (commit tokens; contributor reports are advisory, ledger is truth) | competitor: Filecoin on-chain deal state *(knowledge)* | evidence: RESEARCH/CONSULT.md §4 + https://www.filecoin.io/blog/how-storage-and-retrieval-deals-work-on-filecoin (firecrawl-scrape) | impact: H | effort: med
## Per-chunk AES-256-GCM with key derived from contributor pairing secret | competitor: Storj client-side encryption | evidence: https://storj.dev/learn/concepts/definitions (firecrawl-scrape) | impact: H | effort: med
## Least-privilege, revocable per-contributor tokens (hash at rest, scope: read/write/repair) | competitor: Filecoin deal authority / Storj access grants *(knowledge)* | evidence: RESEARCH/CONSULT.md §6 + https://docs.filecoin.io/reference/general/glossary (firecrawl-search) | impact: H | effort: med
## Audit-log entries for join / leave / write-fail / read-fail / revoke / repair (reuses v2.0 audit log) | competitor: Filecoin on-chain fault history | evidence: https://github.com/filecoin-project/FIPs/discussions/712 (firecrawl-search) | impact: M | effort: easy
## Capacity forecast ("Pool full in 12 days at current growth") from summed usage trend | competitor: Google One storage manager *(knowledge)* | evidence: https://support.google.com/drive/answer/6374270 (firecrawl-search) | impact: M | effort: easy
## Add-a-device onboarding with projected pool size before joining (QR + pinned TLS, reuses pairing) | competitor: Unraid add-disk / Storj node setup | evidence: https://storj.dev/learn/concepts/definitions (firecrawl-scrape) | impact: M | effort: easy
## No-reshuffle-on-join policy: new capacity serves *new* writes; rebalance only via background repair | competitor: ZFS (never restripes) / Unraid | evidence: https://www.reddit.com/r/zfs/comments/impacf/ (firecrawl-search) | impact: M | effort: med

---

## 4. Pool UI presentation patterns (what to copy, what to avoid)

**Copy these:**

1. **One number, segmented.** Google One shows a single total with a segmented bar (Drive / Gmail / Photos). Ours: one total `30 GB` + a donut whose segments are the contributors (`Phone 10 · Laptop 10 · Tablet 10`). The segmented donut is already built (`lib/features/storage`) — extend it rather than invent a new chart.
2. **ZFS-style headline state.** A single colored word *above* everything: `ONLINE` (green) / `DEGRADED` (amber, "2 of 3 contributors online — reads OK, writes paused") / `AT RISK` (red, "no redundancy: 1 copy of 14 files"). Never a healthy-looking total while a member is missing.
3. **Member rows like a device list** (Syncthing/TrueNAS): device icon · name · `used / total` · mini bar vs its own cap · status chip · `last seen` · ⋯ menu (pause, revoke, set as registry). Status chips map 1:1 to the §3 state machine.
4. **Resilver-style repair progress.** A persistent, non-blocking row: `Repairing 3 of 12 replicas…` with ETA. ZFS users trust their pool *because* they can watch the rebuild.
5. **Per-contributor quota bar.** Each row shows `4.2 GB / 10 GB used` with the cap as a hard stop — mirrors Unraid share free-space and ZFS quota, and makes "why didn't my upload fit?" answerable per device.
6. **Honest freshness.** `Last sync 12 s ago` on the pool header; per-row `last seen`. Syncthing's own issue tracker begs for "not connected in a long time" visibility — staleness must be visible, not inferred.
7. **Trust badges on files** (already a v2.3 pattern): `2/2 copies · verified` → degrades to `1/2 copies` → `unreadable (quarantined)`. Progressively disclose *why* on tap.
8. **Add-device CTA with projected gain:** `+ Add contributor → pool becomes 40 GB` — Unraid's add-a-disk dopamine, in one line.

**Avoid these:**

- **Clever arithmetic.** A Reddit thread shows users baffled that a "100 GB family plan" is really `85 GB + n×15 GB`. If a contributor is capped or offline, show the *effective* pool (`20 GB usable now · 30 GB when Laptop returns`), never a magic number.
- **A total that ignores external/other storage.** Nextcloud users' top complaint is a usage bar that doesn't reflect external storage. Our number must equal the sum of what the registry can actually reach, or be labeled "estimated."
- **Ambiguous emptiness.** A pool with zero contributors must not render as "0 B used, all good" — it must render as the onboarding state.
- **Silent write failure.** Every refused write names the fix: `Pool full — free 1.4 GB or raise a contributor cap` (matches the app's existing "errors name the fix and offer Retry" principle).

---

## 5. Failure modes (and how the field handles each)

### 5.1 Contributor goes offline mid-write
**What happens:** planner reserved 1 GB on *Tablet*; 4 of 10 chunks landed; tablet sleeps / Wi-Fi drops.
**Why it's dangerous:** half-written chunk on disk (orphan), reservation never released (phantom used-space), file marked "uploaded" though it has < R copies.
**How competitors behave:** Storj/Sia plan segments onto live nodes and re-plan when a node is unreachable; Filecoin only counts a sector after the proof lands — *unproven data is not stored data*; Sia's redundancy module notices missing pieces after the fact and re-uploads.
**LocalVault rule (adopt):**
1. **Two-phase write per contributor:** `RESERVE(token, bytes, TTL)` → `PUT(chunk, token)` → `COMMIT(token)` / `ABORT(token)`. TTL expiry auto-releases.
2. **File is "committed" only when every chunk has ≥ R live replicas**; otherwise state is `pending repair`, and the UI says so.
3. Contributor treats an uncommitted chunk as garbage after TTL (no orphan growth) and reports its deletion, so accounting converges.
4. Read path never sees uncommitted chunks; reads of committed-but-under-replicated chunks return data + `degraded` flag.
5. Repair worker picks up any chunk found below R after reconnect.

### 5.2 Double-counting (usage / capacity)
**What happens:** retry after timeout applies the same `+chunk` delta twice; a reconnecting contributor re-announces an older snapshot; the donut shows 33 GB used in a 30 GB pool; replicas get counted once per copy against the user's logical usage.
**Why it's dangerous:** pool refuses valid writes (false "full"), or admits invalid ones if the error goes the other way.
**How competitors behave:** Filecoin's truth is the **on-chain sector state** (idempotent, single-writer); Swarm meters against a **prepaid batch** (bounded by construction); Storj's satellite is the single accounting authority and node-side numbers are only advisory for payout.
**LocalVault rule (adopt):**
- **Registry ledger = truth, contributor reports = advisory.** Every usage delta carries an idempotency key (`chunkId + op + seq`); replay is a no-op.
- **Monotonic sequence numbers** per contributor; stale snapshots (`seq ≤ last applied`) are discarded, not merged.
- **Logical vs physical:** user-facing usage counts *logical* bytes once; replica overhead is a separate line (`+50% redundancy`). Donut sums logical; per-contributor bars show physical.
- **Reconciliation job** on every heartbeat: contributor's measured bytes vs ledger; mismatch > threshold → flag `accounting drift`, alert in audit log, never silently overwrite.

### 5.3 Split-brain registry (two devices think they own the pool)
**What happens:** network partition; phone promoted to registry while laptop still runs as registry; both accept joins/writes → divergent chunk maps, conflicting placements, two "truths."
**Why it's dangerous:** worst-case = data written to a placement the other side doesn't know → unreachable chunks + double-counted capacity. This is the highest-severity failure in CONSULT §1.
**How competitors behave:** Filecoin avoids it with a blockchain (heavyweight, but a single ordered ledger); Ceph uses monitor quorum; ZFS/NAS has exactly one head. Nobody solves it with "hope."
**LocalVault rule (adopt):**
- **Single registry lease with TTL**, renewed by heartbeat; role carries a **fencing epoch** that increments on every promotion.
- Every mutating pool request carries the epoch; a peer holding a **lower epoch** is refused (`STALE_REGISTRY`) and demoted to read-only shadow automatically.
- Registry state is **append-only journal + periodic snapshot**; the shadow keeps the last snapshot so failover restores instead of re-merges.
- Promotion requires **quorum of live contributors** (or a manual "I am the new registry" with an explicit epoch bump), never a silent self-promotion.
- All registry traffic goes over the **existing pinned-TLS channel with the contributor token** — no new trust root.

### 5.4 Quota races (concurrent writes vs. one cap)
**What happens:** two uploads both see `Laptop: 9.7/10.0 GB free 0.3 GB`, both reserve 0.3 GB → 10.6 GB on a 10 GB device; or a reserve is applied on one path and rolled back on another; or the cap is enforced only by the planner while the contributor accepts anyway.
**Why it's dangerous:** contributor disk fills → OS-level failures, app crash, or silent chunk loss; the whole pool's durability story collapses on the most mundane path.
**How competitors behave:** Filecoin requires **funds locked in the deal** before data transfer; Swarm requires a **purchased stamp** before any chunk is accepted; Sia locks contract funds. Nobody counts bytes after the fact as the primary control.
**LocalVault rule (adopt):**
- **Contributor is authoritative for its own cap:** `reserved + used ≤ cap` checked **inside the contributor's DB transaction** (SQLite `BEGIN IMMEDIATE`), not in the planner.
- Planner-side **optimistic reservation** (CONSULT §2) is an *optimization*; on `E_QUOTA` it re-plans to another contributor — never retries blindly on the same one.
- Reservations are **in-memory + persisted**, TTL-bound, released on abort/timeout/commit (exactly the §5.1 flow — the two modes share one state machine).
- Writes to the *same* contributor are **serialized** through one pool-writer lock; writes to *different* contributors proceed in parallel (keeps throughput without racing a single cap).
- Contributor periodically reports `used` (measured, not remembered); planner clamps its view to `min(reported, reserved-ledger)` when they disagree.

### 5.5 Secondary modes worth designing for now (cheap to prevent, expensive later)
| Mode | Field precedent | Cheap prevention |
|---|---|---|
| **Free-space lies / disk fills underneath us** (quota said 2 GB, disk has 800 MB) | Storj nodes disqualified for failing audits; Unraid array degraded on full disk | Contributor checks **both** quota cap *and* real free bytes before accepting a chunk; low-disk watermark pauses new placements |
| **Corruption discovered on read** | Storj audits, Ceph scrub, ZFS checksum errors | Verify SHA-256 on read; on mismatch → serve other replica, quarantine bad copy, log, trigger repair (never delete the only copy) |
| **Repair storm** (3 contributors offline ⇒ thousands of chunks re-replicate at once) | Storj repair queue; Ceph recovery throttling | Repair worker with **priority queue** (fewest-replicas first), bandwidth cap, and per-contributor rate limit; surface as the §4 resilver row |
| **Clock skew** breaks TTL reservations / `last seen` | Filecoin uses chain epochs, not wall clock | Use **monotonic lease counters** for reservations; wall clock only for display; reject heartbeats with implausible skew |
| **Token replay / stolen contributor token** | Storj access grants are scoped and revocable | Tokens hashed at rest, scoped (`write`/`repair`/`read`), bound to contributor id + epoch, revocable from the pool screen; replay of an old token after revoke fails |
| **Leaving contributor takes chunks with it** ("drain" not honored) | Sia host leaving mid-contract; Safe node leaving triggers self-repair | `DRAINING` state: stop new placements, **wait until replacements are verified**, then allow departure; revoke is blocked while chunks are unrepaired |
| **Reads during partition return a stale-but-consistent file** | Ceph `degraded` reads | Return data + `stale` badge with the contributing device's last-seen time; never silently serve a possibly-overwritten version |

---

## 6. Feature backlog ordering (feeds the swarm loop)

1. **Registry + heartbeat + epoch lease** (blocks everything; CONSULT §1)
2. **Capacity advertisement + summed accounting ledger with idempotent deltas** (blocks UI number)
3. **Pool screen: headline state + contributor rows + segmented donut** (visible proof the pool exists)
4. **Quota reservation/commit/rollback on the contributor** (§5.1 + §5.4 share one state machine)
5. **Chunk placement with R=2 + diversity rule** (Tahoe happiness check as a unit test)
6. **Verify-on-read + degraded-read path**
7. **Audits (spot-checks) + status machine ONLINE/DEGRADED/OFFLINE/DRAINING**
8. **Automatic repair worker + resilver-style progress row**
9. **Quarantine, drain-before-revoke, accounting reconciliation alerts**
10. **Forecast, onboarding projection, audit-log polish**

---

## 7. Sources

| # | URL | Tool |
|---|---|---|
| 1 | https://storj.dev/learn/concepts/file-redundancy | firecrawl-scrape |
| 2 | https://docs.sia.tech/legacy/renting/is-my-data-secure | firecrawl-scrape |
| 3 | https://tahoe-lafs.readthedocs.io/en/latest/specifications/servers-of-happiness.html | firecrawl-scrape |
| 4 | https://jpl1.github.io/safenetworkprimer/ | firecrawl-scrape |
| 5 | https://www.filecoin.io/blog/how-storage-and-retrieval-deals-work-on-filecoin | firecrawl-scrape |
| 6 | https://forum.storj.io/t/what-is-suspension-audit/9683 · /t/questions-regarding-audit-and-online/23110 · https://storj.dev/node/faq/why-is-my-node-disqualified | firecrawl-search |
| 7 | https://github.com/filecoin-project/FIPs/discussions/712 · https://docs.filecoin.io/reference/general/glossary | firecrawl-search |
| 8 | https://docs.arweave.org/developers/development/overview | firecrawl-search |
| 9 | https://docs.ethswarm.org/docs/references/glossary/ · https://solarpunk.buzz/arweave-vs-swarm-decentralized-storage-comparison/ | firecrawl-search |
| 10 | https://silvertonconsulting.com/tag/safe-network/ | firecrawl-search |
| 11 | https://github.com/syncthing/syncthing/issues/7703 | firecrawl-search |
| 12 | https://support.google.com/googleone/answer/9004015 · https://www.reddit.com/r/google/comments/98pjtm/google_one_family_sharing_seems_confusing_how_is/ | firecrawl-search |
| 13 | https://forum.proxmox.com/threads/meaning-of-degraded-state-on-zfs-pool.113960/ · https://www.reddit.com/r/zfs/comments/impacf/ · https://discourse.practicalzfs.com/t/is-an-automatic-resilver-after-scrub-finds-errors-normal/2271 | firecrawl-search |
| 14 | Ceph CRUSH/self-healing, MinIO/SeaweedFS healing, Unraid parity/any-size-disk array | *(knowledge — explicitly marked, not fetched this run)* |
