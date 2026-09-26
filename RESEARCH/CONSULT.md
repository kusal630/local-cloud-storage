# CONSULT — v2.4.0 Pooled Data Cloud (hardest problems)

Consulted via OpenRouter (`POST /api/v1/chat/completions`).

- **Model used:** `qwen/qwen3-235b-a22b-2507` (3 calls, temperature 0.2).
- **Note on `qwen/qwen3-max`:** first attempt was rejected with HTTP 402
  ("can only afford 393 tokens" — account out of OpenRouter credits), so the
  consult ran on the largest model the balance could afford. One tiny
  `qwen3-max` probe call succeeded but produced nothing usable.
- **Calls:** A = problems 1+2 (registry, capacity races), B = problem 3
  (placement), C = problems 4+5+6 (summed totals, keying, threat model).
- Model answers summarized below; each section ends with the **RECOMMENDATION**
  actually to be built (I corrected a few model weak spots — flagged ⚠).

Context assumed by all answers: ONE host device runs the coordinator (Shelf HTTP
on a background isolate, SQLite + WAL, pinned self-signed TLS, SHA-256-hashed
bearer tokens); N contributors donate quota-capped free disk; files are chunked,
AES-256-GCM encrypted, R=2 replicas.

---

## 1. Registry design (registration over pinned TLS)

**Question:** exact registration handshake, replay protection, heartbeat cadence +
stale detection, revocation.

**Model answer (summary):** Host issues a scoped SHA-256-hashed bearer token via
`POST /register` returning `contributor_id`, `token_hash`, `expires_at`,
`quota_bytes`; mutual auth = host's pinned self-signed cert + contributor
ephemeral X.509 client cert from a locally stored keypair. Replay protection =
per-contributor 10-entry nonce cache, 5 min TTL, monotonic counters (±30 s clock
skew). Heartbeat every 90 s, stale at 180 s, coordinator is the liveness
authority. Revocation: host pushes `DELETE`/`revoke` to the contributor, in-flight
writes fail with 410 Gone, contributor's chunks purged within 5 min.
*Pitfall:* revoked contributor can still serve stale chunks while deletion lags.

**RECOMMENDATION (ONE approach):**

- **Handshake:** `POST /pool/register` over the existing pinned-TLS channel.
  1. Contributor sends `device_id, nonce_c, ts_c, ed25519_pub, quota_bytes,
     storage_path_hash` where `nonce_c` is 32 random bytes.
  2. Host verifies TLS pin of itself (it *is* the pinned endpoint — the
     contributor validates the pin it already stores; the host validates the
     contributor by pairing history), records `nonce_c` in the replay table,
     and replies with `contributor_id, nonce_h = H(nonce_c), token (256-bit),
     token_hash, expires_at, heartbeat_sec, quota_bytes` plus an Ed25519
     signature over `nonce_h || contributor_id || expires_at` by the host key.
  3. Contributor stores `token` in the platform keystore only.
  **Store only `SHA-256(token)` in SQLite** (matches the app's existing token
  discipline). Tokens are *capability tokens*: scope string `pool:{read,write,
  report}` stored with the hash.
- **Replay protection:** table `nonces(nonce TEXT PRIMARY KEY, ts INT)` —
  INSERT, reject on conflict; sweep rows older than **300 s**; accept
  `|ts - now| ≤ 120 s`. Bound the table to ~1000 rows (LRU delete). That's it —
  no counters, no clock sync; the pinned TLS channel already prevents
  off-path replay, this only stops captured-request reuse.
- **Heartbeat:** contributor POSTs `/pool/heartbeat` every **60 s** (with
  `free_bytes, used_bytes, epoch_seen`), host marks `SUSPECT` at **180 s**
  (missed 3), `DEAD` at **600 s** (NAT/sleep tolerance). **Host is the sole
  liveness authority** — contributors never decide a peer is dead
  (split-brain avoidance). A contributor that wakes from sleep just sends one
  immediate heartbeat; no re-registration needed while its token is unexpired.
- **Revocation:** host flips `contributors.status='REVOKED'` in one transaction,
  then (a) fails all in-flight reservations for that contributor
  (`410 Gone` to clients), (b) sends `POST /pool/revoke` to the contributor
  (best-effort; it self-deletes its chunks and wipes its token), (c) queues the
  contributor's stored chunks for **re-replication BEFORE** any deletion is
  considered complete. *Correction to model:* do **not** purge chunks first —
  chunks the revoked contributor holds may be the only copy until re-replication
  finishes.
  *Pitfall (kept):* revocation is not instant — the UI must show
  "revoking… (re-replicating N chunks)".

---

## 2. Capacity accounting races (optimistic reservation + commit/rollback)

**Question:** two contributors assigned the same free space concurrently.

**Model answer (summary):** `reservations(idempotency_key TEXT PRIMARY KEY,
contributor_id, bytes_reserved, state CHECK IN ('RESERVED','COMMITTED',
'ROLLED_BACK'), expires_at)` with index on `(contributor_id, expires_at)`;
`INSERT OR IGNORE` on the idempotency key inside a single transaction that sums
`RESERVED` bytes against quota; fixed contributor order (ascending
`contributor_id`) to avoid deadlock; background sweep deletes rows where
`expires_at < now - 300`; partial success returned as
`{"committed":[…], "failed":[…]}`.

**RECOMMENDATION (ONE approach):** *two-phase reserve → commit with idempotency
key and TTL, all inside one `BEGIN IMMEDIATE` transaction per contributor.*

```sql
CREATE TABLE reservations (
  idempotency_key TEXT NOT NULL,        -- client-generated, one per upload
  chunk_id        TEXT NOT NULL,
  contributor_id  TEXT NOT NULL,
  bytes           INTEGER NOT NULL,
  state           TEXT NOT NULL DEFAULT 'RESERVED'
                  CHECK (state IN ('RESERVED','COMMITTED','ROLLED_BACK')),
  created_at      INTEGER NOT NULL,
  expires_at      INTEGER NOT NULL,
  PRIMARY KEY (idempotency_key, contributor_id)
);
CREATE INDEX idx_res_open ON reservations(contributor_id, state, expires_at);
-- effective usage is ALWAYS computed as:
--   (SELECT COALESCE(SUM(bytes),0) FROM reservations
--     WHERE contributor_id=? AND state='RESERVED' AND expires_at > ?)
--   + (SELECT COALESCE(SUM(bytes),0) FROM chunk_replicas
--       WHERE contributor_id=? AND state='STORED')
-- must be <= contributors.quota_bytes
```

Protocol:
1. **Reserve (single SQL statement, no read-modify-write):**
   ```sql
   BEGIN IMMEDIATE;                     -- one writer at a time, WAL, no deadlock
   INSERT INTO reservations(...)        -- idempotency_key, state='RESERVED'
     SELECT ?, ?, ? WHERE
       (SELECT COALESCE(SUM(bytes),0) FROM reservations
         WHERE contributor_id=? AND state='RESERVED' AND expires_at > now)
     + (SELECT COALESCE(SUM(bytes),0) FROM chunk_replicas
         WHERE contributor_id=? AND state='STORED')
     + ? <= (SELECT quota_bytes FROM contributors WHERE id=? AND status='ALIVE');
   COMMIT;                              -- 0 rows affected == no room
   ```
   The conditional `INSERT … SELECT … WHERE` is the oversubscription invariant:
   two concurrent uploads racing for the last 100 MB produce exactly one
   affected row. `BEGIN IMMEDIATE` takes the write lock upfront so concurrent
   reservations **queue for microseconds instead of deadlocking**, and it's only
   per-chunk (a few ms) — writers are not serialized for the whole upload.
   Order across multiple contributors: acquire in ascending `contributor_id`
   order, or (simpler, recommended) reserve contributors **one at a time in a
   loop** — a failed reserve just moves to the next candidate, no multi-row
   atomicity needed.
2. **Commit:** after the contributor ACKs the stored chunk + hash verify, one
   statement: `UPDATE reservations SET state='COMMITTED' WHERE idempotency_key=?`
   + insert into `chunk_replicas`.
3. **Rollback:** on failure/timeout → `state='ROLLED_BACK'` (or just let the TTL
   lapse).
4. **TTL:** `expires_at = now + 600 s` (longer than the slowest realistic chunk
   upload). Sweeper deletes `RESERVED AND expires_at < now` every 30 s — a
   crashed client therefore never leaks quota for more than 10 min.
5. **Retry:** client re-sends the same `idempotency_key`; `INSERT OR IGNORE`
   makes a retry return the existing row → exactly-once reservation.
6. **Partial success:** HTTP **207 multi-status**:
   `{"committed":[{"contributor":"c1","replica":0},…],
     "failed":[{"contributor":"c3","reason":"no_space"}],
     "chunk_id":…}` — the caller keeps the replicas it got and re-places the
   shortfall (see §3).

*Pitfall (kept):* stale `RESERVED` rows under-count free space until TTL expiry —
mitigated by the 30 s sweeper and by showing "reserved" bytes separately on the
pool screen.

---

## 3. Chunk placement (N contributors, K chunks, R=2, deterministic recovery)

**Question:** placement by free space, hot-spot avoidance, deterministic
re-placement when a contributor dies.

**Model answer (summary):** **Accept weighted rendezvous hashing (HRW)** with
free-space virtual nodes: `weight_i = max(1, floor(free_bytes / 100 MiB))`,
score each virtual node `hash64(chunk_id + " " + id#i)`, take top-R distinct
physical contributors. Reader recomputes from `chunk_id + current_epoch +
contributors@epoch`. Epoch bumps on join/leave/quota change/>20 % free-space
change, debounced to ≥30 s, max every 5 min; readers tolerate ±1 epoch
(`current`, then `current-1`). Re-replication: scan chunks whose replica set
contains a `last_seen > 90 s`-stale contributor, source = a healthy replica,
idempotent content-addressed writes (`chunk_<sha>.data`, temp+fsync+rename).
Ack a write only after **both** replicas verify.

**RECOMMENDATION (ONE approach):** weighted HRW + a **placement epoch that only
bumps on membership change**, plus an explicit `chunk_replicas` table (the model
skipped this — see ⚠).

- **Inputs:** `chunk_id` (content-addressed: `SHA-256(file_id || index)`),
  and the *live contributor set* (id, weight).
- **Weight:** `weight_i = clamp(floor(free_bytes / 64 MiB), 1, 64)` — capped so a
  1 TB contributor doesn't dominate and doesn't blow up the virtual-node loop.
- **Selection:** for each contributor, compute
  `score = hash64_blake3_like(chunk_id || contributor_id)` then apply the
  standard HRW weight transform `score' = -weight / ln(u)` where
  `u = (hash64(chunk_id || contributor_id) mod 2^53) / 2^53`
  (the classic weighted-rendezvous formula — cleaner than enumerating virtual
  nodes). Sort descending, take top **R=2**, requiring **2 distinct physical
  contributors** (if only 1 is alive, write it and mark the chunk
  `UNDER_REPLICATED`).
- **Reader path:** the host *is* the placer — readers ask the host
  `GET /pool/chunk/{chunk_id}/locations` (one round-trip, response cached by
  epoch). Readers never recompute placement themselves; this keeps the
  contributor list off client devices and kills the whole "reader needs
  contributors@epoch" consistency problem. Fallback: client tries listed
  replica 1, then replica 2, then falls back to `GET …/locations?refresh=1`.
- **Storage:** ⚠ the model's "no central record" is wrong for this codebase —
  you need it for accounting anyway:
  ```sql
  CREATE TABLE chunk_replicas (
    chunk_id TEXT NOT NULL, contributor_id TEXT NOT NULL,
    state TEXT CHECK(state IN ('STORING','STORED','DEGRADED','DELETED')),
    sha256 TEXT NOT NULL, bytes INTEGER NOT NULL, updated_at INTEGER,
    PRIMARY KEY (chunk_id, contributor_id));
  ```
  Placement is then *both* derivable (HRW) and recorded (this table); the table
  is authoritative for reads, HRW is authoritative for **re**-placement.
- **Epoch policy:** `cluster_config.current_epoch` bumps **only on membership
  change** (join / leave / REVOKED / DEAD transition) — **not** on free-space
  fluctuation (weights are read live from `contributors`, they don't need an
  epoch). Debounce: at most one bump per 30 s. Writers pin `epoch` at write
  start; readers never need old epochs because the host resolves locations.
- **Re-replication on death:** background job every 60 s selects
  `SELECT c.chunk_id FROM chunk_replicas c WHERE c.contributor_id IN
  (dead set) AND c.state='STORED'`; for each, recompute ideal pair with HRW
  over ALIVE contributors; copy from a surviving replica (verify SHA-256 before
  and after), insert the new row `STORING→STORED`, then mark the dead row
  `DELETED`. Idempotent: `INSERT OR IGNORE` on the primary key, so a crashed
  job re-runs safely. **Only after** all `DEGRADED` chunks reach R=2 is a dead
  contributor's row removable from `contributors`.
- **Ack rule:** write ACKed to the client only after **both** replicas return
  `SHA-256 == expected` (R=2 durability at ack time). Reads may proceed with 1
  replica but the chunk stays `DEGRADED` until repaired.

*Pitfall:* epoch churn if membership flaps (a phone sleeping >600 s toggles
DEAD) — debounce membership changes with hysteresis: only bump epoch when a
contributor is `DEAD > 5 min` or explicitly revoked.

---

## 4. Summed-total consistency (no double/undercount on join/leave/report)

**Question:** single donut = one correct number through join, leave, crash
mid-write, periodic usage reports.

**Model answer (summary):** host-local table
`contributors(peer_id, quota_assigned, last_reported_used, valid_until, seq)`;
authoritative total = `SUM(quota_assigned) - SUM(last_reported_used)` over rows
with `valid_until > NOW()` and the highest `seq` per peer; single-statement
atomic upserts; stale/old-`seq` reports discarded; UI renders the last
consistent snapshot (freezes during reconciliation to stay monotone).

**RECOMMENDATION (ONE approach):** *host-owned single-source-of-truth table +
monotonic report sequence; the total is always derived, never accumulated.*

- **Never store a "pool total" number.** `pool_total = SELECT
  COALESCE(SUM(quota_bytes),0) FROM contributors WHERE status IN ('ALIVE',
  'SUSPECT')` and `pool_used = SELECT COALESCE(SUM(used_bytes),0)` from the
  same rows (rows in `DEAD/REVOKED/LEFT` are excluded — that's how leave stops
  counting, and there's no "subtract" step to get wrong).
- `used_bytes` comes only from `contributors.used_bytes`, which is updated by a
  **single `UPDATE`** triggered by (a) commit/rollback of reservations
  (`used_bytes = used_bytes + chunk bytes`) and (b) heartbeat usage reports —
  each report carries `report_seq INTEGER` and is applied only if
  `report_seq > last_report_seq` (per-contributor, monotonic). Reports older
  than `last_report_seq` or with `ts` older than 300 s are dropped → no
  out-of-order double-count.
- **Join:** one `INSERT OR REPLACE` in a transaction → total grows by exactly
  that quota on the next read. **Leave/revoke:** status flip in the same
  transaction that queues re-replication → total shrinks atomically.
- **Crash mid-write:** reservations (§2) are the only partially-applied state,
  and they're TTL'd and transactional — a crash leaves either a `RESERVED` row
  that expires or a `COMMITTED` row + `chunk_replicas` row, never half.
- **UI:** compute the donut in ONE query inside ONE transaction, so the number
  and the ring can never disagree; display `≈` + "updated Xs ago", and while a
  contributor is `SUSPECT` show it dimmed but keep it in the total until `DEAD`.

*Pitfall (kept from model):* any multi-field update (status + seq + used) must be
one `UPDATE`/`INSERT OR REPLACE` inside one transaction, or a crash strands
`seq` ahead of `used`.

---

## 5. Encryption / keying (per-chunk keys, no plaintext secrets at rest, unpaired readers)

**Question:** derive per-chunk AES-256-GCM key from contributor pairing secret;
host stores secrets without plaintext at rest; reader fetches a chunk from a
contributor it never paired with.

**Model answer (summary):** `HKDF-SHA256(pairing_secret, info="chunk-key",
chunk_id)`; host wraps contributor secrets under a host-master key (HMK) in the
OS keystore, using AES-256-GCM with a fixed all-zero nonce + AAD = contributor
id; unpaired readers get a host-issued time-limited token so the host unwraps,
derives the chunk key and proxies/re-encrypts for the reader; 96-bit random
nonce per chunk stored with ciphertext; AAD = `chunk_id || contributor_id`;
SHA-256 checked on plaintext after GCM decryption. *Pitfall:* nonce reuse on the
wrapping key would expose all pairing secrets.

**RECOMMENDATION (ONE approach):** *host-mediated unwrap: the contributor never
serves plaintext-worthy key material, and readers go through the host's existing
authenticated channel.*

1. **Per-chunk key:** `K_chunk = HKDF-SHA256(ikm = pairing_secret, salt =
   "lv-pool-v1", info = "chunk-key" || chunk_id)` (32 bytes). Both host and the
   owning contributor can derive it; nobody else can.
2. **Encryption:** AES-256-GCM, **96-bit random nonce** stored alongside the
   ciphertext (12 B nonce ‖ ciphertext ‖ 16 B tag), AAD =
   `chunk_id || contributor_id || epoch` so a chunk can't be replayed onto a
   different contributor or chunk id. SHA-256 of the **plaintext** is the
   content id (verified on write and on read, as PROJECT.md requires — it is the
   file's dedup key, GCM is the confidentiality/integrity layer; do both).
3. **No plaintext at rest:** host stores
   `contributor_secrets(contributor_id, wrapped BLOB, wrap_nonce BLOB)` where
   `wrapped = AES-256-GCM(HKDF(master_kek, "contrib-secret-wrap"), nonce,
   pairing_secret, aad=contributor_id)` and `master_kek` comes from the
   **platform keystore** (Android Keystore / Keychain / DPAPI / libsecret),
   file-permission-locked `0700` fallback on headless Linux. ⚠ *Correction to
   model:* do **not** use a fixed all-zero nonce for wrapping — generate a fresh
   random 12-byte nonce per wrap (it's stored next to the ciphertext, so it
   costs nothing and removes the model's own stated pitfall).
4. **Unpaired reader — the ONE mechanism:** the reader asks the **host**
   (`GET /pool/chunk/{id}/plaintext` or a byte-range) over the existing
   pinned-TLS + its own access token. The host unwraps the contributor's pairing
   secret from the keystore, derives `K_chunk`, decrypts, and streams plaintext
   to the reader. The contributor only ever sees: encrypted blob in/out, and the
   host's scoped token — so **a reader never needs to pair with a contributor,
   and a contributor never holds key material for chunks it shouldn't open.**
   (The alternative — host sends the contributor the key — would let the
   contributor decrypt on behalf of anyone holding a token; rejected.)
   *Scale note:* LAN speeds make host-mediated decryption fine; if it ever
   becomes a bottleneck, phase 2 can hand the reader the derived `K_chunk`
   directly (reader is already authenticated + TLS-pinned) — same HKDF, no
   protocol change.
5. **Contributor-side:** the contributor encrypts chunks itself (it derives
   `K_chunk` from its own pairing secret) and stores
   `ciphertext ‖ nonce ‖ tag` only — so a contributor's disk leaks nothing even
   if fully compromised, and the host never needs to re-encrypt on upload.

*Pitfall:* never let the HMK/wrap key and the chunk-key derivation share IKM;
keep `info` labels distinct (`"contrib-secret-wrap"` vs `"chunk-key"`) so HKDF
domain separation holds.

---

## 6. Security checklist / threat model (severity-ordered)

**Model answer (summary):** (1) corrupted chunks — verify against host-signed
manifest, mismatch ⇒ revoke; (2) stolen token — TTL ≤ 1 h, per-operation scopes,
per-contributor revocation; (3) quota abuse — host pre-allocates writes,
contributor signs `chunk_id + hash`, refusal ⇒ reputation decay/exclusion;
(4) path traversal — chunk ids are base64url 256-bit random, reject `.. / \`;
*pitfall:* bare SHA-256 gives no authenticity — hash must be bound to identity
(HMAC/signature) or old valid hashes can be replayed.

**RECOMMENDATION — build checklist, severity-ordered:**

| # | Severity | Threat | Control (the one to implement) |
|---|----------|--------|--------------------------------|
| 1 | **Critical** | Malicious/corrupted chunk | Every read re-verifies **SHA-256(plaintext) against the host's `chunk_replicas.sha256`** before handing bytes to the client. Mismatch ⇒ quarantine (`state='CORRUPT'`), auto-re-replicate from the other replica, audit-log + security-score penalty, and if it repeats ⇒ auto-`REVOKED`. Hash is **recorded by the host at commit time**, never trusted from the contributor — this closes the model's "replay of old valid hashes" pitfall. |
| 2 | **High** | Stolen contributor token | Tokens are 256-bit, **SHA-256-hashed at rest**, scope string `pool:write\|read\|report`, TTL 24 h with refresh rotation (reuse existing refresh-token machinery), revocable in one statement; blast radius = one contributor (its own chunks), never other contributors or the vault. Pinned TLS means a token is useless off-path. |
| 3 | **High** | Contributor lies about free space / refuses writes | **Host-side accounting is authoritative**: reservations (§2) count against `quota_bytes` regardless of claims; a contributor that NACKs or times out 3× in 10 min is marked `SUSPECT` and excluded from placement; `free_bytes` reported by heartbeat is only ever used for **weighting**, never for admitting writes. Its own disk filling up is its problem, not the pool's. |
| 4 | **High** | Replay of register/heartbeat/write requests | `nonces` table + ±120 s window + 300 s TTL (§1); plus every write body carries `chunk_id` so a replayed write is idempotent (`INSERT OR IGNORE`). |
| 5 | **Medium** | Path traversal in chunk IDs | Chunk ids are **hex/base64url SHA-256 only**; canonicalize with `RegExp(r'^[0-9a-f]{64}$')` before any file open; store on disk as `blobs/<2>/<2>/<id>` sharded paths built **only** from the validated id; reject `.`, `..`, `/`, `\`, NUL, and >64 chars with 400. Never concatenate a client string into a path. |
| 6 | **Medium** | Pool exhaustion / quota abuse by a writer | Per-token rate limit + the global rule "pool rejects writes past `pool_total`" evaluated in the same `BEGIN IMMEDIATE` as reservation. |
| 7 | **Medium** | Contributor serving stale data after revocation | Reads from a `REVOKED` contributor are rejected by the host's location service (host is the only router) even before deletion finishes. |
| 8 | **Low** | Metadata leakage to contributors | Contributors see only opaque `chunk_id`s and sizes — never file names/paths (those stay host-side). Enforced by the API shape: `PUT /chunk/{id}` takes raw bytes only. |
| 9 | **Low** | Audit gaps | Audit-log every `pool.join`, `pool.leave`, `pool.revoke`, `chunk.write.fail`, `chunk.read.corrupt` — feeds the existing Security Score screen. |

---

## Priority order for implementation

1. §2 reservations (everything else blocks on admission control).
2. §1 registry (needed to have contributors at all).
3. §5 keying + §6 controls 1 & 5 (done-criteria security items).
4. §3 placement + re-replication (needs §1 liveness + §2 reservations).
5. §4 summed totals (thin once §2's `chunk_replicas`/`contributors` exist).
