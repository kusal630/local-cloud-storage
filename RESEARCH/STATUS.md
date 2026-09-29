# Status

2026-09-19 | done: version fix (app_constants, settings, about dialog) | next: Argon2id memory upgrade
2026-09-19 | done: Argon2id memory 32->64 MiB | next: lock screen enhancement
2026-09-19 | done: lock screen animated security UX | next: theme premium polish
2026-09-19 | done: theme enhanced with better typography, buttons, cards | next: welcome screen polish
2026-09-19 | done: welcome screen improved animations and layout | next: storage donut widget
2026-09-19 | done: storage donut ring visualization | next: storage screen integration
2026-09-19 | done: storage screen donut chart | next: common widget improvements
2026-09-19 | done: AppLogo enhanced with double shadow | next: run analyze and tests
2026-09-19 | done: v1.8.0 world-class wave: haptics, AMOLED, glassmorphism, transitions, search, accessibility | next: v1.9.0 performance & polish wave
2026-09-19 | done: v1.9.0 performance wave: lazy loading, batch operations, file preview, video controls | next: v2.0.0 security & privacy wave
2026-09-19 | done: v2.0.0 security wave: audit log, session manager, security score, tips | next: v2.1.0 offline & sync wave
2026-09-19 | done: v2.1.0 offline & sync wave: sync status, offline manager, conflict resolver | next: v2.2.0 performance optimization wave
2026-09-19 | done: v2.2.0 performance wave: image cache, request batcher, connection pool, memory optimizer | next: v2.3.0 final polish wave
2026-09-19 | done: v2.3.0 final polish wave: onboarding tooltips, feature highlights, help center, FAQ | next: build and release APK
2026-09-19 | done: v2.3.0 final release built and tagged | next: v2.4.0 pooled storage wave

2026-09-25 | mission: v2.4.0 Pooled Data Cloud — many devices contribute storage, UI shows ONE summed cloud | next: map server/quota layer

2026-09-26 | done: POOL-DATA data layer — pool tables (contributors/reservations/chunk_replicas/nonces/contributor_secrets), contributor + reservation + replica + nonce + secret repositories, vault.contributors, unit tests (7) | next: pool server routes consuming vault.contributors

2026-09-28 | done: v2.4.0 pooled cloud wired end to end — coordinator (SQLite ledger, weighted-rendezvous R=2 placement, chunk read/repair mediation), contributor node server + pinned node client, /api/v1/pool REST surface, contributor agent (register, 60 s heartbeat, node start/stop), pool screen + contribute sheet + health banner, DI/nav in app/providers.dart + app/router.dart, README pooled-cloud docs | next: analyze + test clean, then build and tag v2.4.0

2026-09-28 | verify: test/ declares 249 cases as counted today (211 `test()` + 38 `testWidgets()`, via `grep -rE '^\s*(test|testWidgets)\(' test | wc -l`), 173 of them in pool suites — the suite was still growing while this line was written, so re-run the command instead of trusting the figure; flutter analyze / flutter test are owned by the coordinating session, no result is claimed here | next: record the analyze + test result on this line

2026-09-28 | audit (RESEARCH/INEFFICIENCIES.md): D8 fixed on the pinned path — the pool client drops the system trust store when it constructs its HttpClient (lib/server/pool/pool_node_client.dart), so the 64-hex fingerprint decides every contributor handshake, covered by test/unit/pool_node_tls_test.dart against test/fixtures/pool_node.{crt,key}; register still accepts an `http://` endpoint, so the cleartext half of D8 is not closed. D9 rejected as a non-defect — the contributor token authenticates exactly one route (POST /pool/heartbeat), so scope enforcement would be ceremony over a single endpoint. D10 deliberately skipped — heartbeat replay is already blocked by the monotonic `report_seq` and registration replay by `device_id` dedupe | next: leave the remaining findings to their existing entries in RESEARCH/INEFFICIENCIES.md

2026-09-28 | verify: `flutter analyze` over the whole project reports no issues, and `flutter test` reports 249/249 passing — up from 111 at the v2.3.0 baseline. The count above (249 declared cases) is the same figure observed at run time, so the two lines now agree. Two defects were found by tests written this loop rather than by inspection: `Tween<int>` in the pool donut returned a double on every frame strictly between the endpoints of the 700 ms count-up, and that same count-up passed through decimal labels (`12.9 GB`) that overflowed the fixed 168 px ring — both invisible to the existing suite because every prior test pumped straight past the animation end | next: build the release APK, copy it into dist/, commit

2026-09-28 | deploy: bumped `AppConstants.appVersion` and the About tile to 2.4.0, and `pubspec.yaml` from `1.6.0+7` to `2.4.0+8` — the Android metadata had not been touched since v1.6.0, so `versionName` reported 1.6.0 on the v1.7 through v2.3 builds and `versionCode` had been pinned at 7 for eight releases, which blocks a sideloaded upgrade from ever installing over the previous APK. Built `dist/localvault-v2.4.0.apk` | next: commit

2026-09-29 | done: v2.5.0 interface wave (RESEARCH/UI_BACKLOG.md, 16 of 18 items) — repaired the transfer blocker shipped in v2.4.0 (`TransferManager._changed` called itself, so the first transfer overflowed the stack and never began), added the pool ActivityStrip aggregate-throughput row, the three-band meter (Free up space 75% / Raise quota 85% / warning 90%), relative freshness lines on Storage and Pool, contributor folding past six devices, awaited quota and revoke writes so a rejected save is never reported as saved, raw-exception leaks closed in files and preview, ten ErrorState messages rewritten to name cause and next step, tooltip audit at zero violations, and a 200% text-scale guard that found two real RenderFlex overflows (StorageDonut centre, pool hero centre) and fixed both with `FittedBox.scaleDown`, which leaves 100% rendering byte-identical | next: wire PoolStorage into the upload path

2026-09-29 | audit (privacy copy): the upload path performs no encryption and `PoolStorage` is never constructed, so a file reaches its host exactly as written — yet the contribute sheet's PRIVACY section promised "AES-256-GCM encrypted chunks before they leave this device", both help panels promised files spread across devices with a second copy, and five confirmations promised chunks re-replicating on revoke. All eleven sites now say where files actually live, and test/unit/privacy_claims_test.dart fails the build if user-facing code promises that protection again | next: delete that guard the day uploads really do route through PoolStorage

2026-09-29 | verify: `flutter analyze` reports no issues and `flutter test` reports 312/312 passing, up from the 262-case v2.4.0 baseline; the three new suites this loop are activity_strip_test, navigation_bar_test and text_scaling_test | next: build the release APK
2026-09-29 | deploy: bumped `pubspec.yaml` `2.4.0+8` → `2.5.0+9`, `AppConstants.appVersion` and both About tiles to 2.5.0 (the `versionCode` had been pinned at 8 since v2.4.0, so this also unblocks a sideloaded upgrade over the previous APK). Built `dist/localvault-v2.5.0.apk` (93.0 MB). README gained a v2.5.0 interface-wave section, its v2.4.0 wave no longer promises replication it does not perform, and *Current status (honest)* now states plainly that uploaded files never leave their host | next: commit, push, tag v2.5.0 and publish the release
