# Wave 2 — Implement Everything (LocalVault)

Goal: ship every roadmap item with zero new pub dependencies, analyze clean, tests green.

## TODOs

- [x] 1. Critical dashboard async fix + DB migrations (favorites, recent, versions, audit) + model/JSON updates — expect `flutter analyze` clean
- [x] 2. Repositories + Vault facade (favorites/recent/versions/audit/retention/quota/breakdown) — expect unit tests pass
- [x] 3. Server routes (favorite, favorites/recent/open, versions+restore, breakdown, activity, settings, quota enforce, audit hooks, replace-upload) — expect integration test passes
- [x] 4. Client services (file_service additions, discovery beacon/listener, PIN store) + transfer persistence/speed — expect `flutter analyze` clean
- [x] 5. UI wave (files chips/star/replace-dialog, preview versions, storage breakdown, dashboard activity+settings, nearby nodes, PIN lock+settings, shortcuts, HTTPS toggle) + README — expect widget tests pass
- [x] 6. Final verify + commit + push — expect push succeeds

## Final Verification Wave

- [x] F1. `flutter analyze` clean — expect zero issues
- [x] F2. `flutter test` passes — expect all tests pass
- [x] F3. API smoke via integration test (favorites, versions, breakdown, activity, settings) — expect APPROVE
- [x] F4. GitHub push verified + README renders — expect APPROVE
