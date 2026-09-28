# INEFFICIENCIES — v2.4.0 Pooled Data Cloud (read-only audit)

**Date:** 2026-09-27 · **Auditor:** read-only subagent (no file modified except this one)
**Scope read:** `PROJECT.md`, `RESEARCH/{CONSULT,FEATURES,DESIGN,STATUS}.md`, `lib/server/**`,
`lib/data/{database,models,repositories}/**`, `lib/features/pool/**`, `lib/widgets/pool_*.dart`,
`test/**`.

> **Line numbers below were captured while other agents were editing `lib/server/pool/*`
> concurrently** (`pool_coordinator.dart` grew twice during the audit). Treat cited lines as
> ±30 lines and re-locate by symbol name before patching. Files read but *not* treated as final:
> `pool_node*.dart`, `pool_node_router.dart` (concurrent agent).

---

## 1. Spec-vs-code matrix

**PROJECT.md v2.4.0 feature list**

| # | Feature | Status | Evidence (file:symbol) |
|---|---------|--------|------------------------|
| 1 | Contribute this device's free disk (opt-in, quota cap) | **PARTIAL** | server: `pool_router.register_` (:86), `PoolCoordinator.register` (:321), node cap `PoolNodeStore._admit` (`pool_node.dart:285`). Missing: nothing ever calls `PoolNodeServer.start` (`pool_node_server.dart:49`) or POSTs `/pool/register`; `PoolCapacityCard.onContribute` is never supplied (`pool_screen.dart:179`) |
| 2 | Multi-device pool ⇒ UI shows ONE cloud | **PARTIAL** | sums: `ContributorRepository.poolTotals` (:247); UI: `PoolStatus`/`PoolCapacityCard`/`pool_donut.dart`. Broken wiring: `lib/app/router.dart:78` builds `const PoolScreen()` with no loader ⇒ always `PoolStatus.empty()` (`pool_screen.dart:49`); math lies (defect D12) |
| 3 | Pool registry over pinned TLS with own credential | **PARTIAL** | `PoolCoordinator.register`/`authenticateContributor` (:321/:381), nonce table `NonceRepository`. Defects: duplicate rows (D3), optional nonce + dead `withinWindow` (D10), cleartext `http://` endpoints accepted (D8) |
| 4 | Unified capacity/usage accounting, one donut + number | **PARTIAL** | `PoolSnapshot.toJson` (:136), `pool_capacity_card.dart`. But not one transaction (D11) and UI recomputes a wrong number (D12) |
| 5 | Chunk placement across contributors | **PARTIAL** | engine: `PoolPlacement.place/rankedIds` (`placement.dart:119/:141`), `PoolCoordinator.writeChunk` (:602). **No file→chunk splitter exists** (`chunksForFile` has no caller; `recordChunk(fileId:)` always null) ⇒ files are never chunked |
| 6 | Per-contributor quota enforcement, pool rejects past total | **BUILT** | `ReservationRepository.reserveChunk` (:71, conditional `INSERT…SELECT`), `PoolNodeStore.hold/_admit`, `PoolSnapshot.quotaExceeded` (:134) — with the SUSPECT-abort bug D4 |
| 7 | Contributor auth: pinned TLS + token, least-privilege scope, revocable | **PARTIAL** | tokens SHA-256 at rest + master-KEK wrapped (`pool_cipher.dart:165`, `contributor_secret_repository.dart:60`), `ContributorRepository.revoke` (:214). Scope written but never enforced (D9); pin bypass (D8); revoke→wipe is dead code (D1) |
| 8 | Chunk encryption AES-256-GCM, per-chunk key from pairing secret | **MISSING (integration)** | `PoolCipher.deriveChunkKey/encryptChunk` (`pool_cipher.dart:92/:113`) exist **and are tested**, but have **zero production callers**; `contributor_secrets.put` (pairing secret) is never called anywhere in `lib/` |
| 9 | SHA-256 per chunk, verified on write and read, quarantine | **PARTIAL** | node verifies on commit (`pool_node.dart:452`), host verifies on read + quarantines (`pool_coordinator.dart:771` / `:785`), audits `auditStep` (:956). Holes: plaintext hash never verified (D21), quarantined chunks unreachable by repair (D7), no auto-revoke on repeat corruption (§6 control 1) |
| 10 | Offline/degraded reporting + repair from replicas | **PARTIAL** | `sweepLiveness` (:510), degraded read (`ChunkReadResult.degraded` :84), `repairStep` (:857). Broken: repair queue ignores holder liveness (D2), no DRAINING state, liveness only runs when a human looks (D29) |
| 11 | Security score + audit entries for pool join/leave/write/read failures | **PARTIAL** | audit rows exist (`vault.mutated` from :363/:463/:494/:638/:794/:942/:979). Missing: `_securityScore` has no pool items (`host_dashboard_screen.dart:845`); no `chunk.read.fail` action; no audit icon entries for `pool.*` (`host_dashboard_screen.dart:966`) |
| 12 | Pool management screen: list, capacity, status, revoke, promote | **PARTIAL** | widgets + `test/widget/pool_widgets_test.dart` built. Dead: screen never fed (D13), `onRevoke`/`onPromote`/`onContribute` never passed ⇒ menu items no-op (`pool_screen.dart:179`, null checks `pool_contributor_tile.dart:264/:503`); **no promote/"set as registry" backend at all** |

**RESEARCH/FEATURES.md §6 backlog ordering**

| # | Backlog item | Status | Evidence |
|---|--------------|--------|----------|
| 1 | Registry + heartbeat + epoch lease | **PARTIAL** | registry+heartbeat+debounced epoch (`PoolCoordinator.bumpEpoch` :577) built; **no lease / fencing epoch** (nothing refuses a stale registry ⇒ §5.3 split-brain unprotected); no heartbeat sender |
| 2 | Capacity advertisement + idempotent summed ledger | **PARTIAL** | ledger idempotent (`reserveChunk`/`commitReservation`); advertisement = `POST /pool/heartbeat` exists but claims overwrite the ledger (D5), no sender |
| 3 | Pool screen: headline + rows + segmented donut | **PARTIAL** | built + widget-tested; not connected to any data (D13) |
| 4 | Quota reservation → write → commit/rollback | **BUILT** | `reservation_repository.dart:71/:137/:173`, `pool_node.dart:367/:409/:452`; defects D4, D15 |
| 5 | Chunk placement R=2 + diversity (Tahoe happiness test) | **BUILT** | `placement.dart:119/:159/:173/:187` + `test/unit/placement_test.dart` (diversity & happiness groups) |
| 6 | Verify-on-read + degraded-read path | **BUILT** | `PoolCoordinator.readChunk` :771, `pool_router.readChunk` `x-degraded` header :224 — repair side has D7 |
| 7 | Audits + status machine ONLINE/DEGRADED/OFFLINE/DRAINING | **PARTIAL** | `auditStep` :956 built; `ContributorStatus` = ALIVE/SUSPECT/DEAD/REVOKED/LEFT (`contributor.dart:8`) — **no DRAINING**, revoke is not blocked while chunks are unrepaired |
| 8 | Automatic repair worker + resilver progress row | **PARTIAL** | `repairStep`/`_backgroundRepair` (:857/:481) built (but buggy, D2/D16); **no repair progress row in the UI** (`pool_screen.dart` has only capacity + contributor cards) |
| 9 | Quarantine, drain-before-revoke, reconciliation alerts | **PARTIAL** | quarantine built (`ReplicaState.corrupt`); **drain-before-revoke MISSING**; **no ledger-vs-reported drift alert** (D5) |
| 10 | Forecast, onboarding projection, audit-log polish | **MISSING** | no "Pool full in N days", no "+ Add contributor → becomes 40 GB" projection, no pool entries in the dashboard icon map |

---

## 2. Concrete defects

### Critical

**D1 — `revoke()`'s node wipe is dead code; a revoked node never purges** · `pool_coordinator.dart:456-471` + `:1023-1041`
`revoke()` flips the row to `REVOKED` (line 459) and *then* calls `unawaited(_wipeNode(...))` (line 468); `_targetFor` returns `null` for `REVOKED` (line 1026) ⇒ `_wipeNode` returns immediately. A revoked contributor's disk keeps every chunk and keeps accepting writes with its still-valid token (the node stores its own `tokenHash`; nothing rotates it). Violates CONSULT §1 "purged within 5 min".
*Minimal fix:* capture the `NodeTarget` **before** flipping the status (or add a `force:` flag to `_targetFor`), and call `secrets.deleteNodeToken(id)` only after the wipe ACKs.

**D2 — Repair queue ignores holder liveness ⇒ revoke/leave never re-replicates** · `replica_repository.dart:61-72`
`underReplicated()` counts *states* only (`HAVING SUM(state='STORED') < ?`), not whether the holder is usable. After a revoke, the dead contributor's rows are still `STORED` ⇒ chunks with "2 copies" never enter the queue, so `_repairChunk`'s dead-row branch (`pool_coordinator.dart:892-910`) never runs for them. Consequences: `revoke()` returns `queued: held.length` (line 470) for work that will never happen; `countReplicas()` (`contributor_repository.dart:337`) and `degradedChunks` keep counting ghost copies ⇒ `_healthFor` reports `ONLINE` while redundancy is actually 1-of-2 — the exact "lying total" FEATURES §4 forbids.
*Minimal fix:* join `contributors` and count only copies with `status IN ('ALIVE','SUSPECT') AND endpoint <> ''`; also drive the queue from `pool_chunks` LEFT JOIN so 0-copy chunks appear (see D7).

### High

**D3 — `register()` mints a new row per call (no `device_id` uniqueness)** · `contributor_repository.dart:51-87`, `pool_coordinator.dart:343`
Id is a fresh `Uuid().v4()` and the upsert conflicts only on `id`, so a retry/re-register creates a **second contributor for one device**: quota double-counted in `poolTotals`, ghost row stays `ALIVE` in the list, and the *old* token keeps authenticating (`authenticateContributor` scans all rows, `pool_coordinator.dart:386`). There is no `UNIQUE(device_id)` index (`vault_database.dart:181-199`).
*Minimal fix:* `INSERT … ON CONFLICT(device_id) DO UPDATE` (rotate `id`/`token_hash`, delete the old node token), plus a `UNIQUE` index migration.

**D4 — A `SUSPECT` candidate aborts the whole chunk write** · `reservation_repository.dart:121-132` + `contributor_repository.dart:204` + `pool_coordinator.dart:672`
`placementCandidates()` includes `SUSPECT`, but the reserve SQL only admits `status='ALIVE'` (line 92-93), so `_noRoom` throws `ConflictException('Contributor is SUSPECT…')` (line 129). Nothing in `_placeOn` catches it ⇒ `PUT /pool/chunks/<id>` fails with 409 instead of "move to the next candidate", contradicting its own doc comment (`pool_coordinator.dart:600-601`).
*Minimal fix:* wrap the `reserveChunk` call in `try/catch` → `return PlacementOutcome.failed` (one line + one catch).

**D5 — Heartbeat overwrites the ledger's `used_bytes` with a contributor claim** · `contributor_repository.dart:136-147`, `pool_router.dart:52-53`
`used_bytes = ?` applies whatever the node reports; the node also controls `report_seq`. A buggy or malicious contributor can set `used_bytes = 0` (or negative — no validation) ⇒ the pool admits writes past every quota, or inflate it ⇒ false "pool full". Violates FEATURES §5.2 ("ledger = truth, reports = advisory") and CONSULT §6 control 3.
*Minimal fix:* keep `used_bytes` ledger-owned (commit/rollback only); store the report in a new `reported_used_bytes` column and flag `ABS(reported - ledger) > threshold` as `accounting drift` in the audit log.

**D6 — Fallback commit half-applies state** · `pool_coordinator.dart:741-752`
When `commitReservation` returns false (row swept/TTL-lapsed), the code inserts the `STORED` replica but **never** adds `used_bytes`. From then on `poolTotals.usedBytes` (sum of `used_bytes`) and the admission sum (`chunk_replicas`+`reservations`) are two different truths ⇒ donut/`free_bytes` diverge from what is actually admissible.
*Minimal fix:* perform the fallback as one transaction: `upsertReplica` + `UPDATE contributors SET used_bytes = used_bytes + ?`.

**D7 — Quarantined / zero-copy chunks are invisible to repair** · `replica_repository.dart:64-67`
`WHERE state IN ('STORED','DEGRADED')` — a chunk whose only row is `CORRUPT` (or `DELETED`), or a `pool_chunks` row with no replica rows at all, never enters the queue. `readChunk` then returns `null` ⇒ 404 "not found" for data the host thinks exists, health stays `ONLINE`, no repair is ever attempted. Silent data loss.
*Minimal fix:* build the queue from `pool_chunks` LEFT JOIN `chunk_replicas` with `SUM(state='STORED' AND holder-usable) < replication`.

**D8 — TLS pin can be bypassed and cleartext endpoints are accepted** · `pool_node_client.dart:92-99`, `pool_coordinator.dart:1105-1111`
Dart invokes `badCertificateCallback` only when chain validation *fails* ⇒ a publicly-trusted cert for the target host is accepted **without** being compared to the pin. Separately `_validEndpoint` accepts `http://`, where the pin never applies while `X-Pool-Token` is sent in the clear (line 137) — spec says "pinned-TLS channel". A `fingerprint` is optional, and when it is absent every TLS handshake fails closed with no actionable error.
*Minimal fix:* require `scheme == 'https'` + a 64-hex `fingerprint` in `register` (validate with `RegExp(r'^[0-9a-f]{64}$')`), and verify the pin after connect rather than only in `badCertificateCallback`.

**D9 — Token `scope` is written but never enforced** · `pool_coordinator.dart:354`, `pool_router.dart:43`
`scope: 'pool:read,pool:write,pool:report'` is stored; `authenticateContributor(token)` never takes a required scope, so any contributor token can call any pool endpoint. No per-token rate limit either (§6 control 6).
*Minimal fix:* `authenticateContributor(String? token, {required String scope})` and pass `pool:report` from `heartbeat`.

**D12 — UI double-subtracts offline quota and ignores reserved bytes** · `pool_models.dart:211-223`
`availableQuota = totalQuota - offlineQuota`, but `total_quota` from the host **already excludes** `DEAD/LEFT/REVOKED` rows (`contributor_repository.dart:251-252`) while the `contributors` list includes them. Example: 2×10 GB `ALIVE` + 1×10 GB `LEFT` ⇒ host says 20 GB, card shows **10 GB pooled**. Also `freeBytes = totalQuota - usedBytes` ignores the `reserved_bytes` field the host sends ⇒ free space overstated by every in-flight reservation.
*Minimal fix:* consume the host's `available_quota` / `free_bytes` verbatim (both already in `PoolSnapshot.toJson`) instead of recomputing in the UI.

**D13 — Pool screen is never connected to data; revoke/promote/contribute are no-ops** · `lib/app/router.dart:78`, `pool_screen.dart:49-50/:179-184`
`const PoolScreen()` ⇒ `_loader` falls back to `PoolStatus.empty()` ⇒ the screen always renders the EMPTY/onboarding state even with three contributors. `PoolContributorsCard` is built without `onRevoke`/`onPromote`/`onContribute`, so every menu action null-checks and silently does nothing (`pool_contributor_tile.dart:264/:503`).
*Minimal fix:* add `lib/client/services/pool_service.dart` (`GET /api/v1/pool/status` → `PoolStatus.fromJson`) and pass it plus revoke/leave callbacks into `PoolScreen`.

**D14 — No contributor-side agent: nobody serves a node, nobody heartbeats** · grep: no caller of `PoolNodeServer.start`, no caller of `POST /api/v1/pool/register`, no heartbeat sender, no `Timer` for `PoolNodeStore.sweep`
Once a contributor is registered by hand, nothing sends heartbeats ⇒ it reaches `SUSPECT` at 180 s and `DEAD` at 600 s and the pool total collapses to zero. The node's expired holds are only swept lazily on the next mutating call (`pool_node.dart:348`).
*Minimal fix:* one `ContributorAgent` class (start node → register → 60 s heartbeat loop → `sweep()`), wired from the "Contribute this device" action.

**D25 — No GC: deleting a file never frees pool quota** · `contributor_repository.dart:331-333`
`deleteChunksForFile` has no caller; nothing issues `DELETE /node/v1/chunk/<id>` for logical deletes (`_client.delete` is used only in the commit-failure path, `pool_coordinator.dart:728`). Replicas and node storage accumulate forever ⇒ the pool reports full while the user deleted everything.
*Minimal fix:* on file delete/purge, queue `pool_chunks` rows for deletion; delete both replicas only after the first delete verifies (copy-before-delete in reverse).

### Medium

**D10 — Replay protection is opt-in and the freshness window is dead code** · `pool_coordinator.dart:337-341`, `nonce_repository.dart:34-41`
Nonce is recorded only when the client volunteers one (`nonce != null && nonce.length <= 512`); `NonceRepository.withinWindow` is never called; `heartbeat` has no nonce/`ts` at all despite its doc comment (`pool_router.dart:38`).
*Minimal fix:* require `nonce` (≤64 chars) + `ts` on register and heartbeat; reject when `!NonceRepository.withinWindow(ts)`.

**D11 — `snapshot()` is not the single transaction its doc promises** · `pool_coordinator.dart:532-554`
Four separate reads (`poolTotals()` txn, `list()`, `underReplicatedChunks()`, `countReplicas()`) ⇒ a write between them makes the number and the ring disagree (CONSULT §4 forbids exactly this). Worse, `poolTotals` wraps a SELECT in `BEGIN IMMEDIATE` (`vault_database.dart:327`), taking the **write lock** on every status GET and risking `busy_timeout` 500s.
*Minimal fix:* one SELECT with sub-selects (totals + rows + counts) in a plain read; reserve `BEGIN IMMEDIATE` for writers.

**D15 — Write retry is not idempotent ⇒ possible over-replication** · `pool_coordinator.dart:672-678`
`_placeOn` accepts a reservation in any state. On a retry after success the row is `COMMITTED`, so it re-runs hold/put/commit on a node whose hold was consumed; if that node now answers `NO_SPACE`/`CONFLICT`, the planner places the *same* chunk on another contributor (a third replica) under the same idempotency key.
*Minimal fix:* `if (reservation.state == ReservationState.committed) return PlacementOutcome.stored;`

**D16 — No repair lock: four entry points, re-entrant recursion** · `pool_coordinator.dart:811-813/:857/:481/:294`, `pool_router.dart:248`
`readChunk` launches `unawaited(repairStep)` *from inside* `_repairChunk` (which itself calls `readChunk`, line 913) ⇒ concurrent passes can interleave reserve/rollback on one chunk (pass A's rollback releases pass B's reservation). `maybeMaintenance` guards itself (`_maintenanceRunning`) but `revoke`'s `_backgroundRepair` and the `maintenance` route do not.
*Minimal fix:* reuse the `_maintenanceRunning` pattern as a single `repairStep` re-entrancy guard.

**D17 — `authenticateContributor` full-scans the table per request** · `pool_coordinator.dart:381-403`
`list()` = `SELECT *` over every contributor, then `utf8.encode` allocations per row, with no index on `token_hash` (`vault_database.dart:191`).
*Minimal fix:* `SELECT * FROM contributors WHERE token_hash = ? LIMIT 1` (the hash is not secret) + keep the constant-time compare.

**D18 — `sampleReplicas` loads the whole replica table** · `contributor_repository.dart:345-356`
`SELECT *` of every `STORED` row into memory, then a `Set<int>` of random indices — O(table) RAM/CPU on each audit pass.
*Minimal fix:* `SELECT * … WHERE state='STORED' ORDER BY RANDOM() LIMIT ?`.

**D19 — `_readableReplicas` queries inside a sort comparator** · `pool_coordinator.dart:828-845`
`getById` (a full `SELECT *`) runs O(n log n) times during the sort, again in the `.where`, and `getById` **throws `NotFoundException`** if a replica's contributor row is missing ⇒ read 404s instead of skipping the stale row.
*Minimal fix:* build an `id → Contributor` map once and use a non-throwing lookup.

**D20 — Node `PUT` accepts unbounded bodies and mismatched hold sizes** · `pool_node_router.dart:152`, `pool_node.dart:409-443`
`request.read().expand(...).toList()` has no cap (the host caps at 16 MB, `pool_router.dart:30`); `put` never checks `bytes.length == hold.bytes`, so a hold of 10 B can stage 4 GB (quota is still re-checked by `_admit`, but the reservation size and stored size diverge, and the host's ledger is keyed on its own `bytes`).
*Minimal fix:* enforce a body cap and reject `bytes.length != hold.bytes` with `CONFLICT`.

**D21 — Plaintext SHA-256 is never verified anywhere** · `pool_router.dart:192-196`, `pool_coordinator.dart:753-758`
`X-Content-Sha256` is format-checked only; `recordChunk` stores it as `content_sha256`; `PoolCipher.verifyPlaintextSha256` (`pool_cipher.dart:204`) has **no production caller**. PROJECT feature 9 says "verified on write and on read" — only the *ciphertext* hash is verified today.
*Minimal fix:* verify the plaintext hash in the writer (client-side split path, when built) and re-verify after decrypt in the read/serve path; assert `content_sha256` matches at that point.

**D22 — Repair can corrupt the manifest's content hash** · `pool_coordinator.dart:927-929` + `contributor_repository.dart:286-310`
When `recordedChunk` is null the repair falls back to `sha256.convert(source.bytes)` — i.e. the **ciphertext** hash — and `recordChunk`'s `ON CONFLICT … content_sha256 = excluded…` then overwrites a good value with the ciphertext hash.
*Minimal fix:* if the manifest row is missing, skip `recordChunk` entirely (or insert-only).

**D23 — Registration is not atomic** · `pool_coordinator.dart:343-369`
Contributor row → node token → epoch → audit are four separate writes; a crash between 1 and 2 leaves an `ALIVE` row that can never be talked to (`_targetFor` returns null forever) yet still counts toward the pool total.
*Minimal fix:* wrap rows 1-2 (and ideally the epoch write) in one `withTransaction`.

**D29 — Liveness only advances when a human opens the pool screen** · `pool_router.dart:106-114`, `pool_coordinator.dart:294-311`
There is deliberately no timer; `sweepLiveness` runs from `GET /pool/status` (throttled 60 s). On a host nobody looks at, an offline device keeps counting in `total_quota` indefinitely ⇒ the headline number is stale in exactly the "nobody is watching" case FEATURES §4 §6 ("honest freshness") targets.
*Minimal fix:* schedule `maybeMaintenance()` from the existing server isolate/host runner loop (one `Timer.periodic` with an owner that cancels on shutdown).

### Low

**D24 — Dead/unused symbols** · `NonceRepository.withinWindow` (never called), `ContributorRepository.underReplicatedChunks`'s doc vs `list()` overload duplication, `PoolSnapshot.availableQuota` (identical to `totalQuota`, `pool_coordinator.dart:113-119`), `PoolCoordinator.chunkSize` (no splitter uses it), `PoolKeyStore`/`FilePoolKeyStore` TOCTOU documented as "last writer wins" (`pool_cipher.dart:341-342`) — two processes can mint different KEKs and strand every wrapped secret.
**D26 — `_healthFor` can report `AT_RISK` before `OFFLINE` ordering matters** (`pool_coordinator.dart:556-566`): with `counted.isEmpty` it returns `offline` first (correct), but a pool with 1 `SUSPECT` + dead chunks reports `AT_RISK` with no hint that the only contributor is also suspect.
**D27 — `setLastError` silently drops messages >300 chars to `NULL`** (`contributor_repository.dart:93-99`) ⇒ a long failure reason becomes "no error".
**D28 — No audit action for plain read failures** (only `chunk.read.corrupt`), and no `pool.*` icons in the dashboard map (`host_dashboard_screen.dart:966`).

---

## 3. Inefficiencies

**Performance**
1. N+1/scan patterns: `authenticateContributor` full scan per request (D17); comparator queries in `_readableReplicas` (D19); `sampleReplicas` full-table load (D18); `snapshot()` = 4 round trips per status GET (D11).
2. `BEGIN IMMEDIATE` on read-only paths (`poolTotals`, `NonceRepository.sweep`) serializes every status poll against writers (D11).
3. Per-request allocations: `utf8.encode(stored)/utf8.encode(hash)` per contributor row (`pool_coordinator.dart:389-390`), `BytesBuilder` bodies for every node call (`pool_node_client.dart:147-150`), full chunk bytes held in RAM up to 16 MB per read *and* per repair copy (`readChunk` → `_repairChunk` holds `source.bytes` while writing).
4. Unbounded caches: `PoolNodeClient._clients` keyed by `baseUrl|fingerprint` grows forever (`pool_node_client.dart:84-102`); a re-register with a new endpoint leaks an `HttpClient` (and its sockets) until `dispose()` — which nothing calls (`pool_coordinator.dart:1119`, no caller).
5. Repeated SHA-256: `writeChunk` hashes the ciphertext once (good), but repair re-reads + re-hashes the whole chunk on every pass and `auditStep` re-downloads full chunks for sampling — no byte-range sampling.
6. Blocking work on the serving isolate: `PoolNodeStore.open()` walks the whole chunk tree (`pool_node.dart:325-332`), `_removeStaleTmpSync`/`sweep()` are synchronous file IO, `chmod` shells out per directory (`pool_cipher.dart:31`) — all on the request isolate (UI jank on the device that is also the host).
7. `AuthMiddleware._authenticate` writes `updateLastSeen` on **every** request (`auth_middleware.dart:39`) — pre-existing, but it now sits under every pool status poll.

**UX friction**
8. The pool screen can never show real data (D13) — the single biggest gap between the demo and the spec.
9. Revoke/promote/contribute menu items silently do nothing instead of erroring (D13) — violates "errors name the fix".
10. No repair/resilver progress row (FEATURES §4 copy #4) even though `RepairReport.queued` is already returned by the API (`pool_router.dart:148/:168`).
11. No "reserved" line on the pool card although `reserved_bytes` is already in the payload (CONSULT §2 pitfall explicitly asks for it).
12. No `Last sync 12s ago` freshness label (DESIGN §10 / FEATURES §4 copy #6) even though `generated_at` is sent.

**Numbers that can lie (FEATURES §4 "never a lying total")**
13. **UI double-subtracts** DEAD/LEFT/REVOKED quota (D12) — understates the pool.
14. **UI ignores reserved bytes** in `freeBytes` (D12) — overstates free space.
15. **`chunk_count`/`degraded_chunks` count ghost copies** on dead/revoked holders (D2) — reports 2-of-2 redundancy when only 1 copy is reachable.
16. **`total_quota` stays stale** until someone opens the screen (D29) — counts capacity on devices that are gone.
17. **`used_bytes` can be moved by a contributor** (D5) — the donut follows a claim, not the ledger.
18. **Commit-fallback divergence** (D6) — donut `free` and admission `free` disagree.
19. Empty-pool renders as a healthy zero only in `PoolStatus`… actually guarded (`pool_models.dart:235` `isEmpty` → `PoolViewState.empty`), but `PoolStatus.freeBytes` with `quotaExceeded=false` can still show `0 free` + `usedFraction 0` when every contributor is `DEAD` (`allOffline`) — no "at risk" copy.

---

## 4. Test gaps

**Existing test files (13):** `test/unit/{placement,pool_cipher,pool_coordinator,pool_node,contributor_repository,cipher,file_names,file_kinds}_test.dart`, `test/widget/{pool_widgets,common_widgets,welcome_screen}_test.dart`, `test/widget_test.dart`, `test/integration/vault_integration_test.dart`.
Pool-relevant coverage today: placement/diversity/happiness (`placement_test.dart`), crypto + keystores (`pool_cipher_test.dart`), node engine + node HTTP API (`pool_node_test.dart`, 979 lines), reservation/TTL/revocation/nonce/liveness/totals/epoch (`contributor_repository_test.dart`, `pool_coordinator_test.dart`), widget states (`pool_widgets_test.dart`).

**FEATURES §5 failure modes vs coverage**

| Mode | Covered? | Evidence |
|------|----------|----------|
| **5.1 Contributor offline mid-write** (orphan chunk, phantom reservation, "<R copies but marked uploaded") | **NO** | `pool_coordinator_test.dart` never exercises `_placeOn` — there is no fake `PoolNodeClient`; `writeChunk` appears only at :410/:424 (bad-id / no-contributor). Nothing tests hold→put→commit failure ordering, rollback, or "file committed only at ≥R replicas" |
| **5.2 Double-counting** | **PARTIAL** | covered: out-of-order `report_seq` (`contributor_repository_test.dart:98`), reservation idempotency (:44), TTL (:56), "reserved never inflates used" (`pool_coordinator_test.dart:304`). **Missing:** retry-after-timeout applying twice (D15), heartbeat overwriting the ledger (D5), commit-fallback divergence (D6), reported-vs-ledger drift alert |
| **5.3 Split-brain registry** | **NO (feature absent)** | no lease/fencing epoch exists to test; `pool_coordinator_test.dart:441-477` only covers debounce timing |
| **5.4 Quota races** | **MOSTLY** | repo-level race (:29), node-level exact-cap (`pool_node_test.dart:138`). **Missing:** planner re-plan on `E_QUOTA` (D4 currently makes it throw instead), same-contributor serialization (`FEATURES §5.4` bullet 4) |
| **5.5 secondary: free-space lie** | **PARTIAL** | node quota cap tested; **missing:** 64 MiB disk-watermark denial path (`pool_node.dart:172/:291`), unknown-`df` behaviour |
| 5.5: corruption on read | **NO** | no test drives `readChunk` quarantine → `ReplicaState.corrupt` → other-replica fallback |
| 5.5: repair storm / throttle | **NO** | `repairStep` has no test at all |
| 5.5: clock skew | **NO** | `NonceRepository.maxSkew`/`withinWindow` untested (they are unused — D10) |
| 5.5: token replay after revoke | **PARTIAL** | `pool_coordinator_test.dart:150` covers wrong/revoked tokens; node-side token rotation after revoke untested |
| 5.5: DRAINING / leave-mid-contract | **NO (feature absent)** | no `DRAINING` state (matrix item §6.7) |
| 5.5: stale-but-consistent read badge | **NO** | `x-degraded`/`x-replica-count` headers untested (no router-level pool tests exist) |

---

## 5. Ordered fix backlog (top 15, each single-agent sized)

1. **Fix the repair queue to count usable copies** — `replica_repository.dart:61-72` (+ `pool_coordinator.dart:857`). Unblocks revoke/leave repair and honest redundancy counts (D2/D7).
2. **Catch reserve failures inside `_placeOn`** — `pool_coordinator.dart:672-678` → `PlacementOutcome.failed`; makes SUSPECT/DEAD candidates skippable (D4).
3. **De-duplicate registration on `device_id`** — `contributor_repository.dart:51-87` + `UNIQUE` index migration in `vault_database.dart`; rotate token, drop the old node token (D3).
4. **Stop the wipe-after-revoke race / make wipe reachable** — `pool_coordinator.dart:456-471/:1023-1041`: capture `NodeTarget` before the status flip; delete the node token only after the ACK (D1).
5. **Make `used_bytes` ledger-owned** — `contributor_repository.dart:136-147` + `pool_router.dart:52-53`: add `reported_used_bytes`, drift alert in the audit log (D5).
6. **Wire the pool screen to a real loader** — new `lib/client/services/pool_service.dart` + `lib/app/router.dart:78` + pass `onRevoke`/`onContribute` in `pool_screen.dart:179-184` (D13).
7. **Stop the UI double-subtract / ignore-reserved** — `pool_models.dart:211-223`: consume host `available_quota`/`free_bytes` verbatim; add the "reserved" line (D12).
8. **Require `https` + 64-hex fingerprint at register** — `pool_coordinator.dart:1105-1111` + post-handshake pin check in `pool_node_client.dart:92-99` (D8).
9. **Atomic commit-fallback** — `pool_coordinator.dart:741-752` (+ `reservation_repository.dart`): replica + `used_bytes +=` in one transaction (D6).
10. **Re-entrancy guard for `repairStep`** — `pool_coordinator.dart:857`: one `_repairRunning` flag shared by `maybeMaintenance`, `_backgroundRepair`, `readChunk`, and the `maintenance` route (D16).
11. **Idempotent write retry** — `pool_coordinator.dart:672`: return `stored` when the reservation is already `COMMITTED` (D15).
12. **Pool GC on file delete** — `contributor_repository.dart:331-333` + a delete queue that issues `DELETE /node/v1/chunk/<id>` for both replicas after verify (D25).
13. **Contributor agent (register + 60 s heartbeat + node start + `sweep()` timer)** — new `lib/client/services/contributor_agent.dart`, invoked from the Contribute CTA (D14).
14. **Router + coordinator tests for the write/read/repair paths** — new `test/unit/pool_writepath_test.dart` with a fake `PoolNodeClient` covering §5.1 (mid-write death), §5.2 (retry double-apply), corruption-on-read quarantine, and `x-degraded` headers (§4 gaps 5.1/5.2/5.5).
15. **Scope enforcement + required nonce/`ts` on register & heartbeat** — `pool_coordinator.dart:337/:381`, `pool_router.dart:41-62`; delete or wire `NonceRepository.withinWindow` (D9/D10).

---

## 6. Verification

```
$ export PATH="$PATH:/home/kusal/flutter/bin" && flutter analyze lib/server lib/data
Analyzing 2 items...
No issues found! (ran in 0.6s)
```

Analyze is clean **as of this audit** — note it only proves the tree compiles: the defects
above are behavioural/spec defects, not analyzer findings (e.g. `_wipeNode`'s dead branch,
`withinWindow`'s dead code, and the missing feature integrations all pass the analyzer).
`flutter test` was deliberately **not** run (other agents editing concurrently).
