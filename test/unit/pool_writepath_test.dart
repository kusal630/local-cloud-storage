import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/core/errors/app_exceptions.dart';
import 'package:localvault/core/utils/cipher.dart';
import 'package:localvault/core/utils/pool_cipher.dart';
import 'package:localvault/data/datasources/vault.dart';
import 'package:localvault/data/models/contributor.dart';
import 'package:localvault/server/pool/pool_coordinator.dart';
import 'package:localvault/server/pool/pool_node_client.dart';

/// Write-path failure modes of the pooled data cloud
/// (RESEARCH/FEATURES.md §5, coverage gaps listed in
/// RESEARCH/INEFFICIENCIES.md §4), driven entirely through
/// [FakeNodeClient] — no socket is ever opened:
///
/// * §5.1 mid-write death — the node accepted PUT and then the write died
///   before COMMIT, or the node itself went unreachable after HOLD. The
///   reservation must roll back (no phantom quota), the node must be
///   aborted, no `STORED` replica may appear, and a retry with the *same*
///   idempotency key must succeed while charging the pool exactly once.
/// * §5.2 retry double-apply — the same `(chunkId, idempotencyKey, bytes)`
///   written three times runs hold/put/commit once and counts the bytes
///   once; the same key with *different* bytes never overwrites the
///   original.
/// * defect D4 — a contributor that stopped being `ALIVE` between the
///   candidate listing and its reservation is skipped instead of throwing
///   `Contributor is SUSPECT …` out of `writeChunk`.
/// * §5.5 corrupt-on-read — the bad copy is quarantined (`CORRUPT`, never
///   `DELETED`), the good copy serves, and the audit log records every
///   `chunk.read.corrupt`; plus repair re-entrancy (D16).
/// * revoke while a chunk reservation is open.
///
/// Timers: `PoolCoordinator.epochDebounce` is `Duration.zero`, `tearDown`
/// disposes the coordinator, and the two paths that fire unawaited
/// background work (`revoke`, the quarantine repair) are settled with
/// [_settle] before the test ends.
const _endpointA = 'http://127.0.0.1:5321';
const _endpointB = 'http://127.0.0.1:5322';

/// Nothing listens on port 9 (discard): a call that ever reached a real
/// socket here would be refused instantly instead of waiting out a timeout.
const _closedPortEndpoint = 'http://127.0.0.1:9';

/// Fixed pairing secret so `PoolCipher` can seal realistic ciphertext fast.
final List<int> _pairingSecret =
    List<int>.generate(32, (i) => (i * 7 + 3) & 0xff);

/// Lets `unawaited` background work (node wipe, repair drain) land before a
/// test finishes. Every fake reply completes immediately, so one short turn
/// of the event loop is plenty — nothing here waits on the wall clock.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

/// One call the coordinator made to a contributor node, as recorded by
/// [FakeNodeClient].
class FakeCall {
  FakeCall({
    required this.method,
    required this.target,
    this.chunkId,
    this.idempotencyKey,
    this.payload,
  });

  /// `hold`, `put`, `get`, `delete`, `commit`, `abort`, `status` or `wipe`.
  final String method;

  /// Contributor the call was addressed to, or `unbound:<baseUrl>` for an
  /// endpoint [FakeNodeClient] was never told about.
  final String target;

  final String? chunkId;
  final String? idempotencyKey;
  final List<int>? payload;

  /// What tests assert on: `hold:<chunkId>`, `abort:<chunkId>`,
  /// `wipe:<contributorId>`, …
  String get scope => chunkId ?? idempotencyKey ?? target;

  @override
  String toString() => '$method:$scope';
}

/// A programmable stand-in for the HTTP client that talks to storage nodes.
///
/// API:
/// * [bind] — map an endpoint (`NodeTarget.baseUrl`, derived from
///   `contributors.endpoint`) to a contributor id so every call can be
///   attributed to a row.
/// * [script] / [failWith] — replace one method's reply on one contributor:
///   success (the default), `NO_SPACE`, `NodeCall.unavailable` (transport
///   death), a 401, … [hangOn] can produce a future that never completes.
///   An endpoint that was never [bind]ed behaves like a closed port: an
///   immediate [NodeCall.unavailable], no socket, no timeout.
/// * [storage] — the nodes' disks (`contributorId -> chunkId -> bytes`);
///   `get` serves exactly what `put` received until `delete`/`abort`/`wipe`.
/// * [log] / [calls] / [callsFor] — the exact protocol sequence, in order.
/// * [reply] — the default success reply (side effects included), so a
///   script can defer a normal answer by a few milliseconds.
class FakeNodeClient extends PoolNodeClient {
  FakeNodeClient() : super(timeout: const Duration(seconds: 1));

  static const String _unboundPrefix = 'unbound:';

  /// `endpoint -> contributorId`, filled by [bind].
  final Map<String, String> _endpointOwner = {};

  /// `'<method>:<contributorId>' -> scripted reply`.
  final Map<String, FakeReply> _scripts = {};

  /// `contributorId -> idempotencyKey -> chunkId` holds still on the node.
  final Map<String, Map<String, String>> _holds = {};

  /// Everything the nodes saw, in the order they saw it.
  final List<FakeCall> log = [];

  /// The nodes' disks: `contributorId -> chunkId -> bytes`.
  final Map<String, Map<String, List<int>>> storage = {};

  /// Attributes coordinator call targets to contributor rows.
  void bind(String endpoint, String contributorId) {
    _endpointOwner[_trim(endpoint)] = contributorId;
  }

  /// The protocol sequence as plain strings: `hold:<chunkId>`,
  /// `put:<chunkId>`, `commit:<chunkId>`, `abort:<chunkId>`, …
  List<String> get calls => [for (final call in log) call.toString()];

  /// Calls addressed to [target] — a contributor id, or an `unbound:…`
  /// label for an endpoint this fake does not serve.
  List<FakeCall> callsFor(String target) =>
      log.where((c) => c.target == target).toList();

  /// Bytes [target] holds for [chunkId], exactly as `put` received them.
  List<int>? bytesOn(String target, String chunkId) =>
      storage[target]?[chunkId];

  /// Replaces one method's default reply on one contributor.
  void script(String method, String target, FakeReply reply) {
    _scripts['$method:$target'] = reply;
  }

  /// Fixed reply for [method] on [target]: `NO_SPACE`,
  /// `NodeCall.unavailable` (a transport death), `UNAUTHORIZED`, …
  void failWith(String method, String target, NodeCall reply) =>
      script(method, target, (_) async => reply);

  /// A reply that never completes — the caller awaits forever. Nothing in
  /// this suite uses it: a hung write cannot be asserted on and its pending
  /// future would outlive the test. The mid-write-death tests model the same
  /// event with `failWith('commit', id, NodeCall.unavailable)`, which is
  /// exactly what the coordinator observes when its own process dies between
  /// PUT and COMMIT.
  void hangOn(String method, String target) =>
      script(method, target, (_) => Completer<NodeCall>().future);

  /// Drops every scripted reply (storage, bindings and log survive).
  void clearScripts() => _scripts.clear();

  String _resolve(NodeTarget target) {
    final owner = _endpointOwner[_trim(target.baseUrl)];
    return owner ?? '$_unboundPrefix${target.baseUrl}';
  }

  Future<NodeCall> _dispatch(FakeCall call, FakeReply fallback) {
    log.add(call);
    if (call.target.startsWith(_unboundPrefix)) {
      // Not an endpoint this fake serves: behave exactly like a closed port
      // — instant refusal, no socket, no timeout.
      return Future.value(NodeCall.unavailable);
    }
    final scripted = _scripts['${call.method}:${call.target}'];
    if (scripted != null) return scripted(call);
    return fallback(call);
  }

  /// The default success reply for [call], side effects included — a script
  /// can call this to keep the normal behaviour after adding a delay.
  Future<NodeCall> reply(FakeCall call) async {
    switch (call.method) {
      case 'hold':
        (_holds[call.target] ??= <String, String>{})[call.idempotencyKey!] =
            call.chunkId!;
        return NodeCall(ok: true, statusCode: 200, body: {'held': true});
      case 'put':
        (storage[call.target] ??= <String, List<int>>{})[call.chunkId!] =
            List<int>.from(call.payload!);
        return NodeCall(
          ok: true,
          statusCode: 200,
          body: {'bytes': call.payload!.length},
        );
      case 'get':
        final bytes = storage[call.target]?[call.chunkId!];
        if (bytes == null) {
          return const NodeCall(
            ok: false,
            statusCode: 404,
            errorCode: 'NOT_FOUND',
            message: 'No such chunk.',
          );
        }
        return NodeCall(
          ok: true,
          statusCode: 200,
          bytes: List<int>.from(bytes),
        );
      case 'delete':
        storage[call.target]?.remove(call.chunkId!);
        return NodeCall(ok: true, statusCode: 200);
      case 'commit':
        return NodeCall(ok: true, statusCode: 200, body: {'committed': true});
      case 'abort':
        final chunkId = _holds[call.target]?.remove(call.idempotencyKey!);
        if (chunkId != null) storage[call.target]?.remove(chunkId);
        return NodeCall(ok: true, statusCode: 200);
      case 'wipe':
        storage.remove(call.target);
        _holds.remove(call.target);
        return NodeCall(ok: true, statusCode: 200);
      default:
        return NodeCall(ok: true, statusCode: 200, body: {'status': 'ok'});
    }
  }

  @override
  Future<NodeCall> status(NodeTarget target) =>
      _dispatch(FakeCall(method: 'status', target: _resolve(target)), reply);

  @override
  Future<NodeCall> hold(
    NodeTarget target, {
    required String idempotencyKey,
    required String chunkId,
    required int bytes,
  }) =>
      _dispatch(
        FakeCall(
          method: 'hold',
          target: _resolve(target),
          chunkId: chunkId,
          idempotencyKey: idempotencyKey,
        ),
        reply,
      );

  @override
  Future<NodeCall> put(
    NodeTarget target, {
    required String idempotencyKey,
    required String chunkId,
    required List<int> payload,
    String? sha256Hex,
  }) =>
      _dispatch(
        FakeCall(
          method: 'put',
          target: _resolve(target),
          chunkId: chunkId,
          idempotencyKey: idempotencyKey,
          payload: payload,
        ),
        reply,
      );

  @override
  Future<NodeCall> get(NodeTarget target, String chunkId) => _dispatch(
      FakeCall(method: 'get', target: _resolve(target), chunkId: chunkId),
      reply);

  @override
  Future<NodeCall> delete(NodeTarget target, String chunkId) => _dispatch(
      FakeCall(method: 'delete', target: _resolve(target), chunkId: chunkId),
      reply);

  @override
  Future<NodeCall> commit(
    NodeTarget target, {
    required String idempotencyKey,
    required String chunkId,
    required String sha256,
  }) =>
      _dispatch(
        FakeCall(
          method: 'commit',
          target: _resolve(target),
          chunkId: chunkId,
          idempotencyKey: idempotencyKey,
        ),
        reply,
      );

  @override
  Future<NodeCall> abort(NodeTarget target, {required String idempotencyKey}) {
    final resolved = _resolve(target);
    return _dispatch(
      FakeCall(
        method: 'abort',
        target: resolved,
        chunkId: _holds[resolved]?[idempotencyKey],
        idempotencyKey: idempotencyKey,
      ),
      reply,
    );
  }

  @override
  Future<NodeCall> wipe(NodeTarget target) =>
      _dispatch(FakeCall(method: 'wipe', target: _resolve(target)), reply);

  static String _trim(String url) => url.replaceAll(RegExp(r'/+$'), '');
}

/// Signature of a scripted node reply.
typedef FakeReply = Future<NodeCall> Function(FakeCall call);

void main() {
  late Directory dir;
  late Vault vault;
  late FakeNodeClient fake;
  late PoolCoordinator coordinator;

  const chunkId =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  // Registration is keyed by device id (a re-join reuses the row), so every
  // contributor in a test needs its own device.
  var deviceSeq = 0;

  /// Joins a contributor at [endpoint]; `serve: false` leaves the endpoint
  /// unbound in the fake, which then answers every call like a closed port.
  Future<PoolRegistration> join({
    String name = 'Pixel 7',
    int quota = 10 << 30,
    String endpoint = _endpointA,
    String? deviceId,
    bool serve = true,
  }) async {
    final registration = await coordinator.register(
      deviceId: deviceId ?? 'device-${deviceSeq++}',
      name: name,
      quotaBytes: quota,
      endpoint: endpoint,
      deviceKind: 'phone',
    );
    if (serve) fake.bind(endpoint, registration.contributorId);
    return registration;
  }

  /// Seals [label] into real AES-256-GCM chunk ciphertext — the bytes the
  /// coordinator treats as opaque on this path.
  Future<List<int>> ciphertextFor(String label) async {
    final key = await PoolCipher.deriveChunkKey(
      pairingSecret: _pairingSecret,
      chunkId: chunkId,
    );
    return PoolCipher.encryptChunk(
      key: key,
      plaintext: utf8.encode(label),
      aad: '${chunkId}test-host:1',
    );
  }

  Future<ChunkWriteResult> submit({
    required String label,
    required List<int> ciphertext,
    required String key,
  }) =>
      coordinator.writeChunk(
        chunkId: chunkId,
        ciphertext: ciphertext,
        contentSha256: Cipher.sha256String(label),
        idempotencyKey: key,
      );

  setUp(() async {
    dir = Directory(
        '${Directory.systemTemp.path}/lv_writepath_${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    vault = await Vault.create(dir);
    fake = FakeNodeClient();
    coordinator = PoolCoordinator(
      vault: vault,
      client: fake,
      keyStore: FilePoolKeyStore(vaultDir: vault.vaultDir),
      // No 30 s epoch debounce to wait out — nothing here bumps an epoch on
      // purpose, and nothing may outlive the test.
      epochDebounce: Duration.zero,
    );
  });

  tearDown(() {
    coordinator.dispose();
    vault.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('§5.1 mid-write death: COMMIT never answers — rollback, abort, and a '
      'retry that charges exactly once', () async {
    const label = 'mid-write death';
    final registration = await join();
    final id = registration.contributorId;
    final ciphertext = await ciphertextFor(label);

    // The node accepted PUT and then the write died before COMMIT could be
    // answered — the coordinator sees a transport failure.
    fake.failWith('commit', id, NodeCall.unavailable);

    await expectLater(
      submit(label: label, ciphertext: ciphertext, key: 'key-5.1'),
      throwsA(isA<ConflictException>()),
    );

    expect(fake.calls, [
      'hold:$chunkId',
      'put:$chunkId',
      'commit:$chunkId',
      'abort:$chunkId',
      'delete:$chunkId',
    ], reason: 'an uncommitted write must be unwound on the node: '
        'ABORT then DELETE, never a half-written chunk left behind');

    final afterFailure = vault.contributors.poolTotals();
    expect(afterFailure.reservedBytes, 0,
        reason: 'the reservation must be rolled back, not leaked as phantom '
            'quota (§5.1)');
    expect(afterFailure.usedBytes, 0,
        reason: 'unproven data is not stored data — nothing may be charged');
    expect(vault.contributors.listReplicas(chunkId), isEmpty,
        reason: 'no STORED replica row for a write that never committed');
    expect(
      vault.database.raw
          .select('SELECT state FROM reservations WHERE idempotency_key = ?',
              ['key-5.1'])
          .single['state'],
      'ROLLED_BACK',
    );
    expect(vault.contributors.getById(id).lastError, contains('UNREACHABLE'),
        reason: 'the row must say why it is unhappy');

    // A retry with the SAME idempotency key must succeed — and must not
    // charge the pool a second time.
    fake.clearScripts();
    final retried =
        await submit(label: label, ciphertext: ciphertext, key: 'key-5.1');
    expect(retried.replicaIds, [id]);

    expect(fake.calls, [
      'hold:$chunkId',
      'put:$chunkId',
      'commit:$chunkId',
      'abort:$chunkId',
      'delete:$chunkId',
      'hold:$chunkId',
      'put:$chunkId',
      'commit:$chunkId',
    ]);

    final totals = vault.contributors.poolTotals();
    expect(totals.usedBytes, ciphertext.length,
        reason: 'exactly one chunk of bytes: the failed attempt must not '
            'charge and the retry must not double-charge (§5.2)');
    expect(totals.reservedBytes, 0);
    final replicas = vault.contributors.listReplicas(chunkId);
    expect(replicas, hasLength(1));
    expect(replicas.single.state, ReplicaState.stored);
    expect(replicas.single.contributorId, id);
    expect(vault.contributors.getById(id).lastError, isNull,
        reason: 'a clean retry clears the honest "why" again');
  });

  test('§5.1 variant: the node dies between HOLD and PUT — reservation rolled '
      'back, last_error records why', () async {
    const label = 'node died mid-way';
    final registration = await join();
    final id = registration.contributorId;
    final ciphertext = await ciphertextFor(label);

    // HOLD was accepted, then the node went away: PUT never reaches it.
    fake.failWith('put', id, NodeCall.unavailable);

    await expectLater(
      submit(label: label, ciphertext: ciphertext, key: 'key-5.1b'),
      throwsA(isA<ConflictException>()),
    );

    expect(fake.calls, [
      'hold:$chunkId',
      'put:$chunkId',
      'abort:$chunkId',
    ], reason: 'the hold that was granted must be aborted');

    final totals = vault.contributors.poolTotals();
    expect(totals.reservedBytes, 0,
        reason: 'a reservation for bytes that never landed must roll back');
    expect(totals.usedBytes, 0);
    expect(vault.contributors.listReplicas(chunkId), isEmpty,
        reason: 'no replica row for a copy nobody holds');
    expect(fake.bytesOn(id, chunkId), isNull,
        reason: 'the node holds nothing either');

    final row = vault.contributors.getById(id);
    expect(row.lastError, isNotNull);
    expect(row.lastError, contains('UNREACHABLE'),
        reason: 'the contributor row carries the honest "why" for the UI');
    expect(await coordinator.readChunk(chunkId), isNull);
  });

  test('§5.2 retry double-apply: the same write three times runs hold/put/'
      'commit once and counts the bytes once', () async {
    const label = 'idempotent payload';
    final registration = await join();
    final id = registration.contributorId;
    final ciphertext = await ciphertextFor(label);

    for (var attempt = 0; attempt < 3; attempt++) {
      final result =
          await submit(label: label, ciphertext: ciphertext, key: 'key-5.2');
      expect(result.replicaIds, [id],
          reason: 'every replay must still report the chunk as stored');
      expect(result.success, isTrue);
    }

    expect(fake.calls, [
      'hold:$chunkId',
      'put:$chunkId',
      'commit:$chunkId',
    ], reason: 'replays 2 and 3 must stop at the committed reservation — '
        're-running hold/put/commit would double-apply the write (D15)');

    final totals = vault.contributors.poolTotals();
    expect(totals.usedBytes, ciphertext.length,
        reason: 'three applies would be 3× this figure');
    expect(totals.reservedBytes, 0);
    expect(vault.contributors.getById(id).usedBytes, ciphertext.length);

    final replicas = vault.contributors.listReplicas(chunkId);
    expect(replicas, hasLength(1),
        reason: 'chunk_replicas is keyed (chunk, contributor): exactly one row');
    expect(replicas.single.contributorId, id);
    expect(replicas.single.state, ReplicaState.stored);
  });

  test('§5.2 variant: the same idempotency key with different bytes — the '
      'original is never overwritten', () async {
    const originalLabel = 'original content';
    const differentLabel = 'DIFFERENT content, longer than the first payload';
    final registration = await join();
    final id = registration.contributorId;
    final original = await ciphertextFor(originalLabel);
    final different = await ciphertextFor(differentLabel);
    expect(original, isNot(equals(different)));

    final first =
        await submit(label: originalLabel, ciphertext: original, key: 'key-diff');
    expect(first.replicaIds, [id]);

    // Behaviour that holds: the coordinator does NOT fail loudly here — it
    // reports the write as already stored and leaves the original bytes
    // intact. That is correct because the reservation row is keyed by
    // (idempotency_key, contributor_id): once COMMITTED, the key names *this
    // write attempt* and any replay is a no-op (§5.2 "replay is a no-op"),
    // so a client that resubmits different content under the same key can
    // never silently rewrite what the pool already stored or charged. A
    // different payload is a different chunk and must carry a new key.
    final second =
        await submit(label: differentLabel, ciphertext: different, key: 'key-diff');
    expect(second.replicaIds, [id],
        reason: 'the retry is answered as "already stored"');

    expect(fake.calls, [
      'hold:$chunkId',
      'put:$chunkId',
      'commit:$chunkId',
    ], reason: 'a committed key never re-PUTs — the node saw the original once');
    expect(fake.bytesOn(id, chunkId), original,
        reason: 'the original bytes are intact; nothing was overwritten');
    expect(vault.contributors.listReplicas(chunkId).single.sha256,
        Cipher.sha256Hex(original));
    expect(vault.contributors.recordedChunk(chunkId)!.bytes, original.length,
        reason: 'the manifest still describes the bytes that were stored');

    final totals = vault.contributors.poolTotals();
    expect(totals.usedBytes, original.length,
        reason: 'the ledger counts the original once — never original + retry');

    final read = await coordinator.readChunk(chunkId);
    expect(read, isNotNull);
    expect(read!.bytes, original,
        reason: 'reads serve the original content, not the rejected payload');
    expect(read.sha256, Cipher.sha256Hex(original));
  });

  test('defect D4: a contributor that is SUSPECT between planning and '
      'placement is skipped, not thrown out of writeChunk', () async {
    // The alive contributor points at a closed port: if any call ever got past
    // the fake it would be refused instantly instead of timing out.
    final alive = await join(
        name: 'Old phone', endpoint: _closedPortEndpoint, serve: false);
    final suspect = await join(name: 'Tablet', endpoint: _endpointB);

    // SUSPECT rows are still *listed* by `placementCandidates()` (planning),
    // but `reserveChunk` only admits ALIVE — the exact D4 window. Flipping it
    // here means every placement attempt in this write hits that window.
    expect(
        vault.contributors.markSuspect(suspect.contributorId), isTrue);
    expect(vault.contributors.placementCandidates().map((c) => c.id),
        containsAll([alive.contributorId, suspect.contributorId]),
        reason: 'both are still on the candidate list — that is the bug window');

    final label = 'd4';
    final ciphertext = await ciphertextFor(label);

    await expectLater(
      submit(label: label, ciphertext: ciphertext, key: 'key-d4'),
      throwsA(isA<ConflictException>().having(
        (e) => e.message,
        'message',
        'Every contributor refused the write.',
      )),
      reason: 'the SUSPECT refusal must be caught inside the candidate loop '
          "and reported as a refusal — never thrown as 'Contributor is SUSPECT "
          'and cannot accept writes.`',
    );

    expect(fake.callsFor(suspect.contributorId), isEmpty,
        reason: 'the SUSPECT candidate must be skipped before any node call');
    expect(fake.calls, hasLength(1),
        reason: 'only the alive contributor was even tried');
    expect(fake.log.single.method, 'hold');
    expect(vault.contributors.getById(suspect.contributorId).lastError,
        'Left the pool before this write could be placed.',
        reason: 'the skipped candidate still says why it was not used');
    expect(vault.contributors.getById(alive.contributorId).lastError,
        contains('UNREACHABLE'),
        reason: 'the candidate that was tried says why it refused');

    final totals = vault.contributors.poolTotals();
    expect(totals.reservedBytes, 0);
    expect(totals.usedBytes, 0);
    expect(vault.contributors.listReplicas(chunkId), isEmpty);
  });

  test('§5.5 corrupt-on-read: quarantine the bad copy, serve the good one, '
      'never delete', () async {
    const label = 'corruption payload';
    await join(name: 'Pixel 7', endpoint: _endpointA);
    await join(name: 'Tablet', endpoint: _endpointB);
    final ciphertext = await ciphertextFor(label);

    final written =
        await submit(label: label, ciphertext: ciphertext, key: 'key-5.5');
    expect(written.replicaIds, hasLength(2),
        reason: 'R=2: both contributors hold a verified copy');

    // Read order is the coordinator's own preference order — use it so the
    // "first" and "second" copy below are exactly what `readChunk` tries.
    final order = coordinator.locations(chunkId);
    expect(order, hasLength(2));
    final first = order.first;
    final second = order.last;

    // Bit-rot on the SECOND copy only, as a failing sector would.
    final secondBytes = fake.storage[second]![chunkId]!;
    secondBytes[0] = secondBytes[0] ^ 0xff;

    final served = await coordinator.readChunk(chunkId);
    expect(served, isNotNull, reason: 'the healthy first copy serves');
    expect(served!.bytes, ciphertext);
    expect(served.sha256, Cipher.sha256Hex(ciphertext));
    expect(served.replicaCount, 2);
    expect(served.quarantined, isEmpty,
        reason: 'the first copy was clean, so the bad one was not even tried');
    expect(
      vault.contributors
          .listReplicas(chunkId)
          .singleWhere((r) => r.contributorId == second)
          .state,
      ReplicaState.stored,
      reason: 'an unread copy is not condemned before it is ever read',
    );

    // Now rot the first copy too: nothing healthy is left.
    final firstBytes = fake.storage[first]![chunkId]!;
    firstBytes[0] = firstBytes[0] ^ 0xff;

    expect(await coordinator.readChunk(chunkId), isNull,
        reason: 'corrupt bytes must never be handed to the caller');

    final after = vault.contributors.listReplicas(chunkId);
    expect(after, hasLength(2));
    for (final row in after) {
      expect(row.state, ReplicaState.corrupt,
          reason: 'quarantined (so it can be repaired), never DELETED');
    }

    final corruptEntries = vault.audit
        .recent(limit: 20)
        .where((e) => e.action == 'chunk.read.corrupt')
        .toList();
    expect(corruptEntries, hasLength(2),
        reason: 'one audit entry per quarantined copy');
    expect({for (final e in corruptEntries) e.targetId}, {chunkId});
    expect(
      {for (final e in corruptEntries) e.targetName},
      {
        vault.contributors.getById(first).name,
        vault.contributors.getById(second).name,
      },
    );
    expect(
      fake.log.where((c) => c.method == 'get'),
      hasLength(3),
      reason: 'one get for the successful read, two for the full sweep',
    );

    // The quarantine path fires an unawaited `repairStep`. Both copies are
    // CORRUPT now, so the queue is empty and the pass has no work to start —
    // still give it a turn to land before `tearDown` disposes the coordinator.
    expect(vault.contributors.underReplicatedChunks(targetReplicas: 2), isEmpty);
    await _settle();
  });

  test('repair re-entrancy: a second repairStep during a pass returns an '
      'empty report', () async {
    const label = 'repair me';
    final first = await join(name: 'Pixel 7', endpoint: _endpointA);
    final ciphertext = await ciphertextFor(label);
    await submit(label: label, ciphertext: ciphertext, key: 'key-repair');

    expect(vault.contributors.underReplicatedChunks(targetReplicas: 2),
        [chunkId],
        reason: '1 of 2 copies is already repair work');
    final second = await join(name: 'Tablet', endpoint: _endpointB);

    // Make the overlap observable: the first pass reads its source copy from
    // a node whose `get` takes a few milliseconds to answer.
    fake.script('get', first.contributorId, (call) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return fake.reply(call);
    });

    var firstPassDone = false;
    final firstPass = coordinator.repairStep().then((report) {
      firstPassDone = true;
      return report;
    });
    final secondPass = await coordinator.repairStep();

    expect(firstPassDone, isFalse,
        reason: 'the overlap must be real: pass 1 is still mid-flight');
    expect(secondPass.didWork, isFalse,
        reason: 'the re-entrant call must do no work at all (D16)');
    expect(secondPass.repaired, 0);
    expect(secondPass.failed, 0);
    expect(secondPass.quarantined, 0);
    expect(secondPass.queued, 0,
        reason: 'it returns the empty report immediately, without even '
            'building a queue');

    final report = await firstPass;
    expect(report.repaired, 1,
        reason: 'exactly one pass actually re-replicated the chunk');
    expect(report.failed, 0);
    expect(report.queued, 0, reason: 'the queue drained');

    expect(
      fake.callsFor(second.contributorId).map((c) => c.method),
      ['hold', 'put', 'commit'],
      reason: 'only the winning pass talked to the new holder — no second '
          'copy was written by a double-entered repair',
    );
    expect(vault.contributors.listReplicas(chunkId), hasLength(2));
    expect(vault.contributors.underReplicatedChunks(targetReplicas: 2), isEmpty);
    expect(vault.contributors.getById(second.contributorId).usedBytes,
        ciphertext.length,
        reason: 'the replacement copy was paid for exactly once');
  });

  test('revoke while a chunk is held rolls the open reservation back in the '
      'same transaction', () async {
    final registration = await join(quota: 1000);
    final id = registration.contributorId;

    final reservation =
        vault.contributors.reserveChunk('key-hold', chunkId, id, 700);
    expect(reservation, isNotNull);
    expect(vault.contributors.poolTotals().reservedBytes, 700);
    expect(vault.contributors.poolTotals().totalQuota, 1000);

    final report = await coordinator.revoke(id);
    // The wipe and the background repair drain run unawaited — let them land
    // before the test ends.
    await _settle();

    expect(vault.contributors.poolTotals().reservedBytes, 0,
        reason: 'the open reservation must roll back inside the revoke '
            'transaction — a revoked node may not keep holding quota');
    expect(
      vault.database.raw
          .select('SELECT state FROM reservations WHERE idempotency_key = ?',
              ['key-hold'])
          .single['state'],
      'ROLLED_BACK',
    );
    expect(vault.contributors.getById(id).status, ContributorStatus.revoked);
    expect(coordinator.snapshot().totalQuota, 0,
        reason: 'a revoked contributor stops counting toward totalQuota at once');
    expect(report.queued, 0,
        reason: 'it held no chunks yet, so nothing was queued for re-replication');

    expect(fake.log.where((c) => c.method == 'wipe'), hasLength(1),
        reason: 'the node is told to wipe itself while its token still works');
    expect(vault.contributors.secrets.getNodeToken(id), isNull,
        reason: 'the acknowledged wipe drops the credential that signed it');
    expect(vault.contributors.listReplicas(chunkId), isEmpty);
  });
}
