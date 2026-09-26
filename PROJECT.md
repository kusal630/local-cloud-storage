# Project
Idea: LocalVault — A private local cloud storage app that turns any disk into your own cloud. No accounts, no subscriptions, no internet required. Files never leave your devices.
Platform: Flutter (Android, Windows, Linux, macOS, Raspberry Pi)

# Features (v2.4.0 — pooled data cloud)
1. Contribute this device's free disk to a shared pool (opt-in, per-device quota cap)
2. Multi-device pool: phone 10GB + laptop 10GB + tablet 10GB ⇒ UI shows ONE 30GB cloud
3. Pool registry: contributors register over the existing pinned-TLS channel with their own credential
4. Unified capacity/usage accounting: single donut + single number that sums every contributor
5. Chunk placement: files split into chunks and distributed across contributors by free space
6. Per-contributor quota enforcement (no contributor overflows; pool rejects writes past total)
7. Contributor auth: pinned TLS + per-contributor token, least-privilege scope, revocable
8. Chunk encryption (AES-256-GCM, per-chunk key derived from contributor pairing secret)
9. Chunk integrity: SHA-256 per chunk, verified on write and on read, mismatches quarantined
10. Offline/degraded handling: pool reports which contributors are down, reads repair from replicas
11. Security score + audit log entries for pool join/leave/write/read failures
12. Pool management screen: list contributors, capacity, status, revoke, promote this device

# Done criteria (loop stops when ALL true)
- Pool feature implemented end-to-end (server + client + UI) and covered by tests
- flutter analyze clean
- All tests pass
- Security: no plaintext contributor secrets at rest, tokens hashed, chunks encrypted + verified
- Deployment stage reached: version bumped, `flutter build apk --release` succeeds, dist/ APK present,
  README + STATUS.md updated, work committed

# Loop instruction
Each run: read RESEARCH/*.md, find the highest-priority inefficiency or missing pooled-storage
piece, delegate it to a swarm worker, verify with analyze + tests, repeat until every done
criterion above is true.
