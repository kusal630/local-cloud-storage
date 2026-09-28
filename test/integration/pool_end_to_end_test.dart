import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/core/errors/app_exceptions.dart';
import 'package:localvault/core/utils/cipher.dart';
import 'package:localvault/core/utils/pool_cipher.dart';
import 'package:localvault/data/datasources/vault.dart';
import 'package:localvault/data/models/contributor.dart';
import 'package:localvault/server/pool/pool_coordinator.dart';
import 'package:localvault/server/pool/pool_node.dart';
import 'package:localvault/server/pool/pool_node_server.dart';

/// One contributor device, end to end: coordinator + real storage node over a
/// real socket + real AES-256-GCM chunk encryption + SHA-256 verification on
/// both write and read + revocation.
///
/// This is the test that answers "does the pooled data cloud actually work",
/// rather than "does each piece compile".
void main() {
  // `TestWidgetsFlutterBinding` (if anything pulled it in) stubs every
  // HttpClient to 400; these tests need real sockets.
  final previousOverrides = HttpOverrides.current;
  HttpOverrides.global = null;

  late Directory root;
  late Directory nodeDir;
  late Vault vault;
  late PoolCoordinator coordinator;
  late PoolNodeStore store;
  late PoolNodeServer node;
  late String contributorId;
  late List<int> pairingSecret;

  Future<String> chunkIdFor(String label) async =>
      Cipher.sha256String(label + root.path);

  /// Encrypts [plaintext] exactly the way the file writer will.
  Future<List<int>> seal(String chunkId, List<int> plaintext) async {
    final key = await PoolCipher.deriveChunkKey(
      pairingSecret: pairingSecret,
      chunkId: chunkId,
    );
    final aad = '$chunkId$contributorId:1';
    return PoolCipher.encryptChunk(key: key, plaintext: plaintext, aad: aad);
  }

  setUp(() async {
    root = Directory(
        '${Directory.systemTemp.path}/lv_e2e_${DateTime.now().microsecondsSinceEpoch}');
    await root.create(recursive: true);
    nodeDir = Directory('${root.path}/node')..createSync(recursive: true);

    vault = await Vault.create(root);
    coordinator = PoolCoordinator(
      vault: vault,
      keyStore: FilePoolKeyStore(vaultDir: vault.vaultDir),
    );

    // 1. The device joins with a placeholder endpoint: it does not know its
    //    own port until the node is listening.
    final registration = await coordinator.register(
      deviceId: 'e2e-phone',
      name: 'Pixel 7',
      quotaBytes: 10 << 30,
      endpoint: 'http://127.0.0.1:9',
      deviceKind: 'phone',
    );
    contributorId = registration.contributorId;

    // 2. Bring the storage node up, signed with the token the coordinator
    //    just issued (the SHA-256 hex of it is all the node ever stores).
    store = PoolNodeStore(dir: nodeDir, quotaBytes: 10 << 30);
    await store.open();
    node = await PoolNodeServer.start(
      store: store,
      tokenHash: Cipher.sha256String(registration.token),
      preferredPort: 0,
    );

    // 3. Correct the endpoint to the port it actually got.
    coordinator.setEndpoint(
      contributorId,
      endpoint: 'http://127.0.0.1:${node.port}',
    );

    // 4. The pairing secret both sides derive chunk keys from.
    pairingSecret = List<int>.generate(32, (i) => (i * 7 + 3) & 0xff);
  });

  tearDown(() async {
    await node.stop();
    coordinator.dispose();
    vault.close();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
    HttpOverrides.global = previousOverrides;
  });

  test('a chunk is encrypted, written, verified and read back', () async {
    final chunkId = await chunkIdFor('hello');
    final plaintext = utf8.encode(
        'The quick brown fox jumps over the lazy dog. ' * 20);
    final ciphertext = await seal(chunkId, plaintext);
    final contentSha = Cipher.sha256String(String.fromCharCodes(plaintext));

    // --- write ---------------------------------------------------------
    final result = await coordinator.writeChunk(
      chunkId: chunkId,
      ciphertext: ciphertext,
      contentSha256: contentSha,
      idempotencyKey: 'key-1',
    );
    expect(result.replicaIds, [contributorId],
        reason: 'one device in the pool takes exactly one copy');
    expect(result.isDegradedAgainst(coordinator.replication), isTrue,
        reason: 'R=2 with one device is honestly reported as degraded');

    // The bytes really are on this device's disk, and they are ciphertext.
    final stored = await store.read(chunkId);
    expect(stored, isNotNull);
    expect(stored, ciphertext);
    expect(
      String.fromCharCodes(stored!).contains('quick brown fox'),
      isFalse,
      reason: 'what lands on the contributor is encrypted, never plaintext',
    );

    // The host recorded both hashes: plaintext (content id) and ciphertext
    // (integrity check it recorded itself, never trusted from a contributor).
    final manifest = vault.contributors.recordedChunk(chunkId);
    expect(manifest, isNotNull);
    expect(manifest!.contentSha256, contentSha);
    expect(manifest.cipherSha256, sha256.convert(ciphertext).toString());

    final snapshot = coordinator.snapshot();
    expect(snapshot.health, PoolHealth.atRisk,
        reason: 'one device cannot give R=2, so the headline says so rather '
            'than reporting a comfortable ONLINE');
    expect(snapshot.degradedChunks, 1);
    expect(snapshot.totalQuota, 10 << 30);
    expect(snapshot.usedBytes, ciphertext.length,
        reason: 'the ledger, not a heartbeat, owns the used figure');

    // --- read ----------------------------------------------------------
    final read = await coordinator.readChunk(chunkId);
    expect(read, isNotNull);
    expect(read!.bytes, ciphertext);
    expect(read.sha256, sha256.convert(ciphertext).toString());
    expect(read.quarantined, isEmpty);

    // And the ciphertext really is a valid AEAD blob under the chunk key.
    final key = await PoolCipher.deriveChunkKey(
      pairingSecret: pairingSecret,
      chunkId: chunkId,
    );
    final decrypted = await PoolCipher.decryptChunk(
      key: key,
      data: read.bytes,
      aad: '$chunkId$contributorId:1',
    );
    expect(decrypted, plaintext);
    expect(PoolCipher.verifyPlaintextSha256(decrypted, contentSha), isTrue);
  });

  test('a retried write is idempotent instead of double-counting', () async {
    final chunkId = await chunkIdFor('retry');
    final ciphertext = await seal(chunkId, utf8.encode('retry me'));

    final first = await coordinator.writeChunk(
      chunkId: chunkId,
      ciphertext: ciphertext,
      contentSha256: Cipher.sha256String('retry me'),
      idempotencyKey: 'same-key',
    );
    final usedAfterFirst = coordinator.snapshot().usedBytes;

    final second = await coordinator.writeChunk(
      chunkId: chunkId,
      ciphertext: ciphertext,
      contentSha256: Cipher.sha256String('retry me'),
      idempotencyKey: 'same-key',
    );

    expect(second.replicaIds, first.replicaIds);
    expect(coordinator.snapshot().usedBytes, usedAfterFirst,
        reason: 'a retry must not charge the pool twice (D15)');
    expect(vault.contributors.getById(contributorId).usedBytes, ciphertext.length);
  });

  test('the contributor cap is authoritative, even against a big pool quota',
      () async {
    final chunkId = await chunkIdFor('space');
    final ciphertext = await seal(chunkId, utf8.encode('x' * 4096));

    // The host believes there is 10 GB; the node only has a few bytes left.
    store.setQuota(store.usedBytes + 64);

    await expectLater(
      coordinator.writeChunk(
        chunkId: chunkId,
        ciphertext: ciphertext,
        contentSha256: Cipher.sha256String('x' * 4096),
        idempotencyKey: 'key-space',
      ),
      throwsA(isA<ConflictException>().having(
        (e) => e.message,
        'message',
        contains('Pool full'),
      )),
      reason: 'the node says NO_SPACE and the planner reports it as full, '
          'never as a success',
    );
    expect(store.chunkCount, 0,
        reason: 'a refused write must leave no partial file behind');
    expect(
      vault.contributors.poolTotals().reservedBytes,
      0,
      reason: 'the reservation was rolled back, not leaked',
    );
  });

  test('bit-rot on read quarantines the copy instead of serving it', () async {
    final chunkId = await chunkIdFor('rot');
    final ciphertext = await seal(chunkId, utf8.encode('trustworthy'));
    await coordinator.writeChunk(
      chunkId: chunkId,
      ciphertext: ciphertext,
      contentSha256: Cipher.sha256String('trustworthy'),
      idempotencyKey: 'key-rot',
    );

    // Flip a byte on the contributor's disk, exactly as a failing sector
    // would.
    final path = '${nodeDir.path}/chunks/'
        '${chunkId.substring(0, 2)}/${chunkId.substring(2, 4)}/$chunkId';
    expect(File(path).existsSync(), isTrue, reason: 'sharded layout: $path');
    final onDisk = await File(path).readAsBytes();
    onDisk[0] = onDisk[0] ^ 0xff;
    await File(path).writeAsBytes(onDisk);

    final read = await coordinator.readChunk(chunkId);
    expect(read, isNull,
        reason: 'corrupt bytes must never be handed to the caller');
    expect(
      vault.contributors
          .listReplicas(chunkId)
          .single
          .state,
      ReplicaState.corrupt,
      reason: 'the copy is quarantined (not deleted) so it can be repaired',
    );
  });

  test('revoke wipes the node and forgets the credential that signed it',
      () async {
    final chunkId = await chunkIdFor('revoke');
    final ciphertext = await seal(chunkId, utf8.encode('to be revoked'));
    await coordinator.writeChunk(
      chunkId: chunkId,
      ciphertext: ciphertext,
      contentSha256: Cipher.sha256String('to be revoked'),
      idempotencyKey: 'key-revoke',
    );
    expect(store.chunkCount, 1);

    await coordinator.revoke(contributorId);

    // The wipe runs off the request path; wait for its acknowledged landing.
    final wiped = await Future<bool>.delayed(const Duration(milliseconds: 100),
        () => vault.contributors.secrets.getNodeToken(contributorId) == null);
    var settle = wiped;
    for (var i = 0; i < 40 && !settle; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      settle =
          vault.contributors.secrets.getNodeToken(contributorId) == null;
    }
    expect(settle, isTrue,
        reason: 'an acknowledged wipe drops the wrapped node token (D1)');
    expect(store.chunkCount, 0, reason: 'the node purged its bytes');

    expect(coordinator.snapshot().health, PoolHealth.offline);
    expect(coordinator.snapshot().totalQuota, 0,
        reason: 'a revoked device stops counting immediately');
  });

  test('repair queues chunks whose only copy sits on an unusable holder',
      () async {
    final chunkId = await chunkIdFor('repair-queue');
    final ciphertext = await seal(chunkId, utf8.encode('needs a sibling'));
    await coordinator.writeChunk(
      chunkId: chunkId,
      ciphertext: ciphertext,
      contentSha256: Cipher.sha256String('needs a sibling'),
      idempotencyKey: 'key-queue',
    );

    expect(vault.contributors.underReplicatedChunks(targetReplicas: 2),
        [chunkId], reason: '1 of 2 usable copies is already under-replicated');

    // A second device joins: still under-replicated until it actually holds
    // a copy (joining is not a backup).
    await coordinator.register(
      deviceId: 'e2e-tablet',
      name: 'Tablet',
      quotaBytes: 10 << 30,
      endpoint: 'http://127.0.0.1:9',
      deviceKind: 'tablet',
    );
    expect(vault.contributors.underReplicatedChunks(targetReplicas: 2),
        [chunkId]);

    // Revoke the holder: the copy is still marked STORED, but it is no longer
    // readable, so it must NOT be counted as redundancy (D2).
    await coordinator.revoke(contributorId);
    expect(
      vault.contributors.underReplicatedChunks(targetReplicas: 2),
      [chunkId],
      reason: 'a copy on a revoked device cannot count toward R=2',
    );
  });

  test('re-registering this device reuses its row and rotates the token',
      () async {
    final before = await coordinator.register(
      deviceId: 'e2e-phone',
      name: 'Pixel 7',
      quotaBytes: 5 << 30,
      endpoint: 'http://127.0.0.1:9',
    );
    expect(before.contributorId, contributorId,
        reason: 'a second join must not mint a ghost row (D3)');
    expect(vault.contributors.list().length, 1,
        reason: 'otherwise this device would be counted twice');

    final status = coordinator.snapshot();
    expect(status.totalQuota, 5 << 30,
        reason: 'the SAME row took the new quota — it was never duplicated');
    expect(vault.contributors.getByDeviceId('e2e-phone')!.name, 'Pixel 7');
  });
}
