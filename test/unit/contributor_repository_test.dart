import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/data/database/vault_database.dart';
import 'package:localvault/data/models/contributor.dart';
import 'package:localvault/data/repositories/contributor_repository.dart';

void main() {
  late Directory dir;
  late VaultDatabase db;
  late ContributorRepository repo;

  setUp(() async {
    dir = Directory(
        '${Directory.systemTemp.path}/lv_pool_${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    db = VaultDatabase.open(dir);
    repo = ContributorRepository(db);
    repo.register(id: 'c1', deviceId: 'd1', name: 'Phone', quotaBytes: 1000);
  });

  tearDown(() {
    db.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('two reservations racing for the last bytes admit exactly one', () {
    final first = repo.reserveChunk('k1', 'ch1', 'c1', 600);
    final second = repo.reserveChunk('k2', 'ch2', 'c1', 600);
    expect(first, isNotNull);
    expect(second, isNull, reason: '600 + 600 exceeds the 1000-byte quota');

    // A committed replica consumes quota the same way, and the boundary is
    // inclusive: 600 stored + 400 reserved == 1000 still fits.
    expect(repo.commitReservation('k1', 'c1', 'aa'), isTrue);
    expect(repo.reserveChunk('k3', 'ch3', 'c1', 500), isNull);
    final edge = repo.reserveChunk('k4', 'ch4', 'c1', 400);
    expect(edge, isNotNull);
    expect(repo.reserveChunk('k5', 'ch5', 'c1', 1), isNull);
  });

  test('idempotent retry returns the existing row and holds quota once', () {
    final a = repo.reserveChunk('idem', 'ch1', 'c1', 700);
    final b = repo.reserveChunk('idem', 'ch1', 'c1', 700);
    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(b!.idempotencyKey, a!.idempotencyKey);
    expect(b.bytes, 700);
    expect(repo.poolTotals().reservedBytes, 700,
        reason: 'a retry must not double-count the hold');
    expect(repo.reserveChunk('other', 'ch2', 'c1', 400), isNull);
  });

  test('TTL sweep frees quota', () async {
    final held =
        repo.reserveChunk('ttl', 'ch1', 'c1', 900, ttl: const Duration(milliseconds: 500));
    expect(held, isNotNull);
    expect(repo.reserveChunk('later', 'ch2', 'c1', 500), isNull);

    await Future<void>.delayed(const Duration(milliseconds: 700));

    expect(repo.reserveChunk('later', 'ch2', 'c1', 500), isNotNull,
        reason: 'an expired hold no longer counts against quota');
    expect(repo.sweepExpiredReservations(), 1);
    expect(repo.poolTotals().reservedBytes, 500);
    expect(repo.reserveChunk('later', 'ch2', 'c1', 500), isNotNull,
        reason: 'idempotent retry still resolves after the sweep');
  });

  test('revoked and dead contributors are excluded from poolTotals', () {
    repo.register(id: 'c2', deviceId: 'd2', name: 'Laptop', quotaBytes: 2000);
    expect(repo.poolTotals().totalQuota, 3000);

    repo.heartbeat(
        contributorId: 'c2', reportSeq: 1, usedBytes: 500, freeBytes: 1500);
    expect(repo.poolTotals().usedBytes, 500);

    // SUSPECT stays in the total (dimmed in the UI, counted until DEAD).
    expect(repo.markSuspect('c1'), isTrue);
    expect(repo.markSuspect('c1'), isFalse, reason: 'not ALIVE anymore');
    expect(repo.poolTotals().totalQuota, 3000);

    // Revocation shrinks the total atomically — no subtract step to get wrong.
    expect(repo.revoke('c1'), isTrue);
    expect(repo.revoke('c1'), isFalse, reason: 'already revoked');
    expect(repo.poolTotals().totalQuota, 2000);
    expect(repo.poolTotals().usedBytes, 500);

    expect(repo.markDead('c2'), isTrue);
    expect(repo.markDead('c2'), isFalse, reason: 'not ALIVE/SUSPECT anymore');
    expect(repo.poolTotals().totalQuota, 0);
    expect(repo.poolTotals().usedBytes, 0);
    expect(repo.poolTotals().freeBytes, 0);
  });

  test('stale report_seq is dropped whole', () {
    expect(
        repo.heartbeat(
            contributorId: 'c1', reportSeq: 5, usedBytes: 500, freeBytes: 500),
        isTrue);
    expect(
        repo.heartbeat(
            contributorId: 'c1', reportSeq: 5, usedBytes: 999, freeBytes: 1),
        isFalse,
        reason: 'equal seq is a replay');
    expect(
        repo.heartbeat(
            contributorId: 'c1', reportSeq: 3, usedBytes: 1, freeBytes: 999),
        isFalse,
        reason: 'older seq is out of order');

    final c = repo.getById('c1');
    expect(c.usedBytes, 500);
    expect(c.lastReportSeq, 5);
    expect(repo.poolTotals().usedBytes, 500);
  });

  test('nonce insert rejects replays and the sweep frees expired rows', () {
    expect(repo.insertNonce('fresh'), isTrue);
    expect(repo.insertNonce('fresh'), isFalse, reason: 'replay');
    expect(
        repo.insertNonce('stale',
            at: DateTime.now().subtract(const Duration(seconds: 400))),
        isTrue);
    expect(repo.sweepNonces(), 1);
    expect(repo.insertNonce('stale'), isTrue, reason: 'evicted after TTL');
  });

  test('replica records drive the under-replicated repair queue', () {
    repo.reserveChunk('r1', 'chX', 'c1', 100);
    expect(repo.commitReservation('r1', 'c1', 'aa'), isTrue);
    expect(repo.listReplicasByContributor('c1').single.chunkId, 'chX');
    expect(repo.underReplicatedChunks(), ['chX'], reason: '1 of R=2 copies');

    repo.upsertReplica('chX', 'c2', ReplicaState.stored, 'bb', 100);
    expect(repo.underReplicatedChunks(), isEmpty);
    expect(repo.getById('c1').usedBytes, 100);
  });
}
