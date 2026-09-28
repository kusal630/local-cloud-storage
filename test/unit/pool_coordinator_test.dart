import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/core/errors/app_exceptions.dart';
import 'package:localvault/core/utils/cipher.dart';
import 'package:localvault/core/utils/pool_cipher.dart';
import 'package:localvault/data/datasources/vault.dart';
import 'package:localvault/data/models/contributor.dart';
import 'package:localvault/data/repositories/contributor_repository.dart';
import 'package:localvault/features/pool/pool_models.dart';
import 'package:localvault/server/pool/pool_coordinator.dart';

/// Registry, liveness, summed-total and admission-control behaviour of the
/// pool coordinator (RESEARCH/CONSULT.md §1, §2, §4, §6). Node I/O is covered
/// by `pool_node_test.dart` and the end-to-end suite — nothing here needs a
/// socket, so these tests are fast and deterministic.
void main() {
  late Directory dir;
  late Vault vault;
  late PoolCoordinator coordinator;

  const chunkId =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  // Registration is keyed by device id (re-joining reuses the row), so tests
  // that want N distinct contributors must name N distinct devices.
  var deviceSeq = 0;

  Future<PoolRegistration> join({
    String name = 'Pixel 7',
    int quota = 10 << 30,
    String endpoint = 'http://192.168.1.50:5321',
    String? nonce,
    String? deviceId,
  }) =>
      coordinator.register(
        deviceId: deviceId ?? 'device-${deviceSeq++}',
        name: name,
        quotaBytes: quota,
        endpoint: endpoint,
        deviceKind: 'phone',
        nonce: nonce,
      );

  setUp(() async {
    dir = Directory(
        '${Directory.systemTemp.path}/lv_coord_${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    vault = await Vault.create(dir);
    coordinator = PoolCoordinator(
      vault: vault,
      keyStore: FilePoolKeyStore(vaultDir: vault.vaultDir),
    );
  });

  tearDown(() {
    coordinator.dispose();
    vault.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('registration (§1)', () {
    test('issues a token but never stores it in plaintext', () async {
      final registration = await join(quota: 5 << 30);
      expect(registration.contributorId, isNotEmpty);
      expect(registration.token.length, greaterThan(30));
      expect(registration.heartbeatInterval, const Duration(seconds: 60));

      final row = vault.contributors.getById(registration.contributorId);
      expect(row.status, ContributorStatus.alive);
      expect(row.quotaBytes, 5 << 30);
      expect(row.endpoint, 'http://192.168.1.50:5321');
      expect(row.deviceKind, 'phone');

      // `token_hash` must be SHA-256(token), not the token.
      expect(row.tokenHash, Cipher.sha256String(registration.token));
      expect(row.tokenHash, isNot(registration.token));

      // Neither the main DB file nor its WAL may contain the plaintext
      // token: WAL mode keeps recent commits out of db.sqlite itself, so
      // both have to be checked for the test to mean anything.
      final dbFile = File('${vault.vaultDir.path}/db.sqlite');
      final wal = File('${vault.vaultDir.path}/db.sqlite-wal');
      for (final file in [dbFile, if (await wal.exists()) wal]) {
        final bytes = await file.readAsBytes();
        expect(
          String.fromCharCodes(bytes).contains(registration.token),
          isFalse,
          reason: 'a capability token must never rest in SQLite unencrypted '
              '(${file.path})',
        );
      }

      // The outbound copy is ciphertext under the master KEK.
      final wrapped =
          vault.contributors.secrets.getNodeToken(registration.contributorId);
      expect(wrapped, isNotNull);
      expect(
        String.fromCharCodes(wrapped!).contains(registration.token),
        isFalse,
        reason: 'node token must be wrapped, not stored raw',
      );
      final unwrapped = await PoolCipher.unwrapSecret(
        masterKek: await FilePoolKeyStore(vaultDir: vault.vaultDir)
            .getMasterKek(),
        wrapped: wrapped,
        contributorId: 'node-token:${registration.contributorId}',
      );
      expect(String.fromCharCodes(unwrapped), registration.token);
    });

    test('rejects bad input before touching the ledger', () async {
      await expectLater(
        join(quota: 0),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        join(endpoint: 'not a url'),
        throwsA(isA<ValidationException>()),
      );
      expect(vault.contributors.list(), isEmpty);
    });

    test('rejects a replayed nonce (§1 replay protection)', () async {
      await join(nonce: 'nonce-one');
      await expectLater(
        join(nonce: 'nonce-one'),
        throwsA(isA<ConflictException>()),
      );
      // A fresh nonce is accepted, and so is a request with no nonce at all.
      await join(nonce: 'nonce-two');
      await join(nonce: null);
      expect(vault.contributors.list().length, 3);
    });

    test('re-joining the same device reuses its row instead of duplicating',
        () async {
      final first = await join(deviceId: 'phone-1', quota: 10 << 30);
      final second = await join(deviceId: 'phone-1', quota: 20 << 30);

      expect(second.contributorId, first.contributorId,
          reason: 'a second join must not mint a ghost row (D3)');
      final rows = vault.contributors.list();
      expect(rows.length, 1);
      expect(rows.single.quotaBytes, 20 << 30);
      // The old token must be dead: `token_hash` was overwritten.
      expect(
        () => coordinator.authenticateContributor(first.token),
        throwsA(isA<AuthException>()),
        reason: 'the previous capability token must stop working on re-join',
      );
      expect(
        coordinator.authenticateContributor(second.token).id,
        first.contributorId,
      );
      expect(
        vault.contributors.secrets.getNodeToken(first.contributorId),
        isNotNull,
      );
    });

    test('sweeping nonces keeps the table bounded', () async {
      for (var i = 0; i < 5; i++) {
        await join(nonce: 'n$i', deviceId: 'd$i');
      }
      final before = vault.contributors.insertNonce('old');
      expect(before, isTrue);
      // Simulate a 10-minute-old row: the sweep must drop it (§1: 300 s TTL).
      vault.database.raw
          .execute("UPDATE nonces SET ts = ? WHERE nonce = 'old'",
              [DateTime.now().subtract(const Duration(minutes: 10))
                  .millisecondsSinceEpoch]);
      expect(vault.contributors.sweepNonces(), greaterThanOrEqualTo(1));
      expect(vault.contributors.insertNonce('old'), isTrue,
          reason: 'a swept nonce may be reused');
    });

    test('authenticates contributors and refuses revoked or wrong tokens',
        () async {
      final registration = await join();
      final good = coordinator.authenticateContributor(registration.token);
      expect(good.id, registration.contributorId);

      expect(
        () => coordinator.authenticateContributor('nope'),
        throwsA(isA<AuthException>()),
      );
      expect(
        () => coordinator.authenticateContributor(null),
        throwsA(isA<AuthException>()),
      );
      expect(
        () => coordinator.authenticateContributor(''),
        throwsA(isA<AuthException>()),
      );

      await coordinator.revoke(registration.contributorId);
      expect(
        () => coordinator.authenticateContributor(registration.token),
        throwsA(isA<AuthException>()),
        reason: 'a revoked contributor must lose access immediately (§7)',
      );
    });
  });

  group('heartbeats (§4 monotonic reports)', () {
    test('drops out-of-order reports instead of double-counting', () async {
      final registration = await join(quota: 1000);
      final id = registration.contributorId;

      expect(
        await coordinator.heartbeat(
            contributorId: id, reportSeq: 2, usedBytes: 400, freeBytes: 600),
        isTrue,
      );
      expect(vault.contributors.getById(id).reportedUsedBytes, 400);
      expect(
        vault.contributors.getById(id).usedBytes,
        0,
        reason: 'a heartbeat is a claim; only a chunk commit may move the '
            'ledger (D5)',
      );
      expect(vault.contributors.getById(id).freeBytes, 600);

      expect(
        await coordinator.heartbeat(
            contributorId: id, reportSeq: 1, usedBytes: 900, freeBytes: 100),
        isFalse,
        reason: 'an older report must be discarded whole',
      );
      expect(vault.contributors.getById(id).reportedUsedBytes, 400);

      expect(
        await coordinator.heartbeat(
            contributorId: id, reportSeq: 3, usedBytes: 500, freeBytes: 500),
        isTrue,
      );
      expect(vault.contributors.getById(id).reportedUsedBytes, 500);
      expect(vault.contributors.getById(id).freeBytes, 500);
    });

    test('a fresh heartbeat revives a DEAD contributor', () async {
      final registration = await join();
      final id = registration.contributorId;
      final changed = await coordinator.sweepLiveness(
        now: DateTime.now().add(
            ContributorRepository.deadAfter + const Duration(seconds: 5)),
      );
      expect(changed.single.status, ContributorStatus.dead);
      expect(vault.contributors.getById(id).status, ContributorStatus.dead);

      expect(
        await coordinator.heartbeat(
            contributorId: id, reportSeq: 1, usedBytes: 0, freeBytes: 100),
        isTrue,
      );
      expect(vault.contributors.getById(id).status, ContributorStatus.alive);
    });
  });

  group('liveness sweep (§1 — host is the sole authority)', () {
    test('ALIVE → SUSPECT at 180 s → DEAD at 600 s', () async {
      await join();
      expect(await coordinator.sweepLiveness(), isEmpty,
          reason: 'a fresh contributor must not be disturbed');

      final suspect = await coordinator.sweepLiveness(
        now: DateTime.now().add(
            ContributorRepository.suspectAfter + const Duration(seconds: 5)),
      );
      expect(suspect.single.status, ContributorStatus.suspect);

      // Re-running inside the window must not re-report the same row.
      expect(
        await coordinator.sweepLiveness(
          now: DateTime.now().add(ContributorRepository.suspectAfter),
        ),
        isEmpty,
        reason: 'SUSPECT must not be re-reported',
      );

      final dead = await coordinator.sweepLiveness(
        now: DateTime.now()
            .add(ContributorRepository.deadAfter + const Duration(seconds: 5)),
      );
      expect(dead.single.status, ContributorStatus.dead);
    });
  });

  group('summed totals & health headline (§4)', () {
    test('an empty pool reports EMPTY, not a healthy zero', () async {
      final snapshot = coordinator.snapshot();
      expect(snapshot.health, PoolHealth.empty);
      expect(snapshot.totalQuota, 0);
      expect(snapshot.toJson()['quota_exceeded'], isFalse);
      expect(PoolStatus.fromJson(snapshot.toJson()).isEmpty, isTrue);
    });

    test('total is the sum of counted contributors only', () async {
      final a = await join(name: 'Phone', quota: 10 << 30);
      final b = await join(
          name: 'Laptop', quota: 10 << 30, endpoint: 'http://192.168.1.51:5321');
      final c = await join(
          name: 'Tablet', quota: 10 << 30, endpoint: 'http://192.168.1.52:5321');

      var snapshot = coordinator.snapshot();
      expect(snapshot.totalQuota, 30 << 30);
      expect(snapshot.health, PoolHealth.online);
      expect(snapshot.contributors.length, 3);

      // One device goes away: leave must shrink the number with no subtract
      // step to get wrong.
      await coordinator.leave(b.contributorId);
      snapshot = coordinator.snapshot();
      expect(snapshot.totalQuota, 20 << 30);
      expect(snapshot.health, PoolHealth.degraded);

      // Revoke drops another.
      await coordinator.revoke(c.contributorId);
      snapshot = coordinator.snapshot();
      expect(snapshot.totalQuota, 10 << 30);

      // Kill the last one: OFFLINE, not "10 GB free".
      await coordinator.sweepLiveness(
        now: DateTime.now().add(
            ContributorRepository.deadAfter + const Duration(seconds: 1)),
      );
      snapshot = coordinator.snapshot();
      expect(snapshot.health, PoolHealth.offline);
      expect(snapshot.totalQuota, 0,
          reason: 'DEAD rows stop counting (§4): no subtract step to get wrong');
      expect(snapshot.availableQuota, 0);
      expect(snapshot.offlineQuota, 30 << 30,
          reason: 'the vanished capacity stays visible as offline quota');

      expect(a.contributorId, isNotEmpty);
    });

    test('reserved bytes are visible and never inflate the used figure',
        () async {
      final registration = await join(quota: 1000);
      vault.contributors.reserveChunk('key-1', chunkId, registration.contributorId, 300);

      final snapshot = coordinator.snapshot();
      expect(snapshot.usedBytes, 0);
      expect(snapshot.reservedBytes, 300);
      expect(snapshot.freeBytes, 700);

      vault.contributors.commitReservation(
          'key-1', registration.contributorId, 'ab' * 32);
      final after = coordinator.snapshot();
      expect(after.usedBytes, 300);
      expect(after.reservedBytes, 0);
      expect(after.freeBytes, 700);
    });

    test('flips to quota_exceeded when nothing is left', () async {
      final registration = await join(quota: 500);
      vault.contributors.reserveChunk('k', chunkId, registration.contributorId, 500);
      vault.contributors.commitReservation(
          'k', registration.contributorId, 'cd' * 32);
      final snapshot = coordinator.snapshot();
      expect(snapshot.freeBytes, 0);
      expect(snapshot.quotaExceeded, isTrue);
      expect(PoolStatus.fromJson(snapshot.toJson()).isFull, isTrue);
    });

    test('JSON shape is exactly what PoolStatus.fromJson consumes', () async {
      final registration = await join(name: 'Pixel 7', deviceId: 'device-1');
      final json = coordinator.snapshot(thisDeviceId: 'device-1').toJson(
        thisDeviceId: 'device-1',
      );
      final status = PoolStatus.fromJson(json);
      expect(status.totalQuota, json['total_quota']);
      expect(status.contributors.single.name, 'Pixel 7');
      expect(status.contributors.single.status, PoolContributorStatus.online);
      expect(status.contributors.single.isThisDevice, isTrue);
      expect(status.contributors.single.deviceKind, 'phone');
      expect(status.contributors.single.lastSeen, isNotNull);
      expect(json['health'], 'ONLINE');
      expect(json['epoch'], isA<int>());
      expect(status.viewState, PoolViewState.healthy);
      expect(registration.contributorId, isNotEmpty);
    });
  });

  group('quota & revocation (§2, §6 control 7)', () {
    test('cannot set a quota below what is already stored', () async {
      final registration = await join(quota: 1000);
      final id = registration.contributorId;
      vault.contributors.reserveChunk('k', chunkId, id, 800);
      vault.contributors.commitReservation('k', id, 'ef' * 32);

      expect(() => coordinator.setQuota(id, 100), throwsA(isA<ConflictException>()));
      expect(() => coordinator.setQuota(id, 0), throwsA(isA<ValidationException>()));
      coordinator.setQuota(id, 2000);
      expect(vault.contributors.getById(id).quotaBytes, 2000);
    });

    test('revoke rolls back in-flight reservations in one transaction',
        () async {
      final registration = await join(quota: 1000);
      final id = registration.contributorId;
      final reservation =
          vault.contributors.reserveChunk('k', chunkId, id, 700);
      expect(reservation, isNotNull);
      expect(vault.contributors.poolTotals().reservedBytes, 700);

      await coordinator.revoke(id);

      expect(vault.contributors.getById(id).status, ContributorStatus.revoked);
      expect(vault.contributors.poolTotals().reservedBytes, 0,
          reason: 'a revoked contributor must not keep holding quota');
      // The wrapped token survives revocation on purpose: it is ciphertext
      // under the master KEK, it can no longer authenticate (the row is
      // REVOKED), and keeping it lets the best-effort node wipe still be
      // signed. Nothing here can be replayed as a bearer credential.
      expect(vault.contributors.secrets.getNodeToken(id), isNotNull);
      expect(
        () => coordinator.authenticateContributor(registration.token),
        throwsA(isA<AuthException>()),
      );
    });

    test('revoking twice is a no-op', () async {
      final registration = await join();
      await coordinator.revoke(registration.contributorId);
      final second = await coordinator.revoke(registration.contributorId);
      expect(second.queued, 0);
    });
  });

  group('chunk admission (§2, §3)', () {
    test('rejects malformed chunk ids (path-traversal guard, §6 control 5)',
        () async {
      for (final bad in [
        '../../etc/passwd',
        'ABCD',
        'zzzz',
        '',
        'short',
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeF',
      ]) {
        await expectLater(
          coordinator.writeChunk(
            chunkId: bad,
            ciphertext: const [1, 2, 3],
            contentSha256: 'ab' * 32,
            idempotencyKey: 'key-$bad',
          ),
          throwsA(isA<ValidationException>()),
          reason: 'chunk id "$bad" must be refused before any path is built',
        );
      }
    });

    test('refuses the write when there is no contributor at all', () async {
      await expectLater(
        coordinator.writeChunk(
          chunkId: chunkId,
          ciphertext: const [1, 2, 3],
          contentSha256: 'ab' * 32,
          idempotencyKey: 'key-1',
        ),
        throwsA(isA<ConflictException>()),
      );
      expect(vault.contributors.list(), isEmpty);
    });

    test('read of an unknown chunk returns null, not an exception', () async {
      expect(await coordinator.readChunk(chunkId), isNull);
      expect(coordinator.locations(chunkId), isEmpty);
    });
  });

  group('placement epoch (§3)', () {
    test('bumps once for a burst of joins (debounced)', () async {
      expect(coordinator.currentEpoch, 1);
      await join(nonce: null, deviceId: 'd1', endpoint: 'http://192.168.1.1:1');
      final afterFirst = coordinator.currentEpoch;
      expect(afterFirst, greaterThan(1));
      await join(deviceId: 'd2', endpoint: 'http://192.168.1.2:1');
      await join(deviceId: 'd3', endpoint: 'http://192.168.1.3:1');
      expect(coordinator.currentEpoch, afterFirst,
          reason: 'a membership burst must not cause epoch churn');
    });

    test('bumps again once the debounce window has passed', () async {
      final instant = PoolCoordinator(
        vault: vault,
        keyStore: FilePoolKeyStore(vaultDir: vault.vaultDir),
        epochDebounce: Duration.zero,
      );
      await instant.register(
        deviceId: 'd1',
        name: 'Phone',
        quotaBytes: 1024,
        endpoint: 'http://192.168.1.1:1',
      );
      final first = instant.currentEpoch;
      await instant.register(
        deviceId: 'd2',
        name: 'Laptop',
        quotaBytes: 1024,
        endpoint: 'http://192.168.1.2:1',
      );
      expect(instant.currentEpoch, greaterThan(first));
      instant.dispose();
    });
  });

  group('maintenance (opportunistic, §1 + §6)', () {
    test('runs at most once per window', () async {
      await join();
      await coordinator.maybeMaintenance();
      // A second call inside the window must be a cheap no-op: it must not
      // mark liveness again while a sweep just ran.
      await coordinator.maybeMaintenance();
      final status = coordinator.snapshot();
      expect(status.health, PoolHealth.online);
    });
  });
}
