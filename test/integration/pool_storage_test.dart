import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/core/utils/cipher.dart';
import 'package:localvault/core/utils/pool_cipher.dart';
import 'package:localvault/data/datasources/vault.dart';
import 'package:localvault/data/models/contributor.dart';
import 'package:localvault/server/pool/pool_coordinator.dart';
import 'package:localvault/server/pool/pool_node.dart';
import 'package:localvault/server/pool/pool_node_server.dart';
import 'package:localvault/server/pool/pool_storage.dart';

/// v2.4.0 features 5, 8, 9 and 10 in one place: a file is split, encrypted,
/// placed across two real contributor nodes, read back, degraded honestly
/// when a device disappears, and freed again.
///
/// These tests use real sockets and real AES-256-GCM on purpose — the whole
/// point of the feature is what actually lands on someone else's disk.
void main() {
  // `TestWidgetsFlutterBinding` stubs every HttpClient to 400; these tests
  // need real sockets.
  final previousOverrides = HttpOverrides.current;
  HttpOverrides.global = null;

  late Directory root;
  late Vault vault;
  late PoolCoordinator coordinator;
  late PoolStorage storage;
  final stores = <PoolNodeStore>[];
  final nodes = <PoolNodeServer>[];
  final dirs = <Directory>[];
  final ids = <String>[];

  Future<void> joinDevice(
    int i, {
    int ledgerQuota = 64 << 20,
    int nodeQuota = 64 << 20,
  }) async {
    final registration = await coordinator.register(
      deviceId: 'dev-$i',
      name: 'Device $i',
      quotaBytes: ledgerQuota,
      endpoint: 'http://127.0.0.1:9',
    );
    final dir = Directory('${root.path}/node$i')..createSync(recursive: true);
    final store = PoolNodeStore(dir: dir, quotaBytes: nodeQuota);
    await store.open();
    final node = await PoolNodeServer.start(
      store: store,
      tokenHash: Cipher.sha256String(registration.token),
      preferredPort: 0,
    );
    coordinator.setEndpoint(
      registration.contributorId,
      endpoint: 'http://127.0.0.1:${node.port}',
    );
    ids.add(registration.contributorId);
    stores.add(store);
    dirs.add(dir);
    nodes.add(node);
  }

  /// Deterministic bytes carrying [marker] so a test can prove the marker
  /// never appears on a contributor's disk.
  Uint8List payload(int length, String marker) {
    final m = utf8.encode(marker);
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = m[i % m.length];
    }
    return out;
  }

  Iterable<File> nodeChunkFiles(int device) sync* {
    final base = Directory('${root.path}/node$device/chunks');
    if (!base.existsSync()) return;
    yield* base.listSync(recursive: true).whereType<File>();
  }

  setUp(() async {
    root = Directory(
        '${Directory.systemTemp.path}/lv_store_${DateTime.now().microsecondsSinceEpoch}')
      ..createSync(recursive: true);
    vault = await Vault.create(root);
    coordinator = PoolCoordinator(
      vault: vault,
      keyStore: FilePoolKeyStore(vaultDir: vault.vaultDir),
    );
    storage = PoolStorage(vault: vault, coordinator: coordinator);
    stores.clear();
    nodes.clear();
    dirs.clear();
    ids.clear();
    await joinDevice(0);
    await joinDevice(1);
  });

  tearDown(() async {
    for (final node in nodes) {
      try {
        await node.stop();
      } catch (_) {}
    }
    nodes.clear();
    stores.clear();
    dirs.clear();
    ids.clear();
    coordinator.dispose();
    vault.close();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
    HttpOverrides.global = previousOverrides;
  });

  group('chunking (feature 5)', () {
    test('chunk ids are derived, stable and fixed-length hex', () {
      expect(PoolStorage.chunkIdFor('file-a', 0),
          PoolStorage.chunkIdFor('file-a', 0));
      expect(PoolStorage.chunkIdFor('file-a', 0),
          isNot(PoolStorage.chunkIdFor('file-a', 1)));
      expect(PoolStorage.chunkIdFor('file-a', 0),
          isNot(PoolStorage.chunkIdFor('file-b', 0)));
      expect(PoolStorage.chunkIdFor('file-a', 0), matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('a file is split, placed on both devices, and reassembled', () async {
      final bytes = payload(PoolStorage.chunkSize + 1024, 'LOCALVAULT-POOL-MARKER');
      final report = await storage.putFile(fileId: 'alpha', bytes: bytes);

      expect(report.chunkCount, 2, reason: '5 MiB + 1 kB is exactly two slots');
      expect(report.isComplete, isTrue);
      expect(report.failedSequences, isEmpty);
      expect(report.underReplicated, isFalse, reason: 'two devices at R=2');
      expect(report.protectedBytes, greaterThan(bytes.length),
          reason: 'AEAD overhead is real and must be counted');

      // Both devices hold both chunks: R=2 is satisfied, not assumed.
      for (var i = 0; i < 2; i++) {
        final stored = vault.contributors
            .listReplicasByContributor(ids[i])
            .where((r) => r.state == ReplicaState.stored);
        expect(stored.length, 2, reason: 'device $i holds both chunks');
      }

      final read = await storage.getFile('alpha');
      expect(read, isNotNull);
      expect(read!.isComplete, isTrue);
      expect(read.degraded, isFalse);
      expect(read.bytes, bytes, reason: 'byte-for-byte reassembly');
      expect(
        sha256.convert(read.bytes),
        sha256.convert(bytes),
        reason: 'the plaintext hash recorded at protect time still matches',
      );

      final status = storage.statusOf('alpha');
      expect(status.chunkCount, 2);
      expect(status.storedChunks, 2);
      expect(status.completeChunks, 2);
      expect(status.isComplete, isTrue);
      expect(status.isPending, isFalse);
      expect(status.byteLength, bytes.length);
      expect(storage.protectedFileIds(), ['alpha']);

      // R=2 means the pool physically holds two copies, and the quota figure
      // the UI sums is physical — that is what makes "30 GB of devices"
      // actually mean 30 GB.
      final snapshot = coordinator.snapshot();
      expect(snapshot.usedBytes, report.protectedBytes * 2);
      expect(snapshot.totalQuota, (64 << 20) * 2);
      expect(snapshot.health, PoolHealth.online,
          reason: 'R=2 is actually met, so the headline is allowed to say so');
      expect(coordinator.snapshot().degradedChunks, 0);
    });

    test('progress is reported once per slot', () async {
      final bytes = payload(PoolStorage.chunkSize + 7, 'progress');
      final seen = <int, int>{};
      await storage.putFile(
        fileId: 'progress',
        bytes: bytes,
        onProgress: (done, total) => seen[done] = total,
      );
      expect(seen.keys.toList()..sort(), [1, 2]);
      expect(seen[2], 2);
    });
  });

  group('encryption and integrity (features 8, 9)', () {
    test('plaintext never reaches a contributor', () async {
      const marker = 'LOCALVAULT-PLAINTEXT-CANARY-0123456789';
      final bytes = payload(PoolStorage.chunkSize + 512, marker);

      await storage.putFile(fileId: 'secret', bytes: bytes);

      var files = 0;
      for (var device = 0; device < 2; device++) {
        for (final file in nodeChunkFiles(device)) {
          files++;
          final onDisk = file.readAsBytesSync();
          expect(onDisk.length, greaterThan(0));
          expect(
            String.fromCharCodes(onDisk).contains(marker),
            isFalse,
            reason: '${file.path} must hold ciphertext only',
          );
        }
      }
      expect(files, 4, reason: '2 chunks x 2 devices');
    });

    test('one bad copy still lets the file through, and is quarantined',
        () async {
      final bytes = payload(3000, 'redundant');
      await storage.putFile(fileId: 'rot-one', bytes: bytes);
      final chunkId = PoolStorage.chunkIdFor('rot-one', 0);

      // Pin the read order. "Healthiest first" falls back to "most recently
      // touched", so touching device 0 last makes it the copy the reader
      // tries first — the one we then damage. Without this the test would be
      // asserting on coin-flip ordering.
      final rows = vault.contributors.listReplicas(chunkId);
      final second = rows.singleWhere((r) => r.contributorId == ids[1]);
      vault.contributors.upsertReplica(
          chunkId, second.contributorId, ReplicaState.stored, second.sha256, second.bytes);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final first = rows.singleWhere((r) => r.contributorId == ids[0]);
      vault.contributors.upsertReplica(
          chunkId, first.contributorId, ReplicaState.stored, first.sha256, first.bytes);

      final path = '${dirs[0].path}/chunks/'
          '${chunkId.substring(0, 2)}/${chunkId.substring(2, 4)}/$chunkId';
      expect(File(path).existsSync(), isTrue, reason: 'sharded layout: $path');
      final onDisk = await File(path).readAsBytes();
      onDisk[0] ^= 0xff;
      await File(path).writeAsBytes(onDisk);

      final read = await storage.getFile('rot-one');
      expect(read!.isComplete, isTrue,
          reason: 'the healthy replica still serves the file');
      expect(read.bytes, bytes);
      expect(read.degraded, isTrue,
          reason: 'a copy was thrown out, so this answer was thinner '
              'than R=2 and must say so');
      expect(
        vault.contributors
            .listReplicas(chunkId)
            .singleWhere((r) => r.contributorId == ids[0])
            .state,
        ReplicaState.corrupt,
        reason: 'the damaged copy is quarantined — kept, not deleted, '
            'because repair needs the row to know what to replace',
      );
    });

    test('bit-rot on every copy is refused instead of served', () async {
      final bytes = payload(3000, 'integrity');
      await storage.putFile(fileId: 'rot-all', bytes: bytes);
      final chunkId = PoolStorage.chunkIdFor('rot-all', 0);

      // Damage BOTH copies, so the outcome cannot depend on which device the
      // reader happened to reach for first.
      for (var i = 0; i < 2; i++) {
        final path = '${dirs[i].path}/chunks/'
            '${chunkId.substring(0, 2)}/${chunkId.substring(2, 4)}/$chunkId';
        expect(File(path).existsSync(), isTrue, reason: 'sharded: $path');
        final onDisk = await File(path).readAsBytes();
        onDisk[0] ^= 0xff;
        await File(path).writeAsBytes(onDisk);
      }

      final read = await storage.getFile('rot-all');
      expect(read!.isComplete, isFalse);
      expect(read.bytes, isEmpty,
          reason: 'rotted bytes are refused, never handed back');
      expect(read.missingSequences, [0]);
      expect(read.degraded, isTrue);
      expect(
        vault.contributors.listReplicas(chunkId).map((r) => r.state).toSet(),
        {ReplicaState.corrupt},
        reason: 'every damaged copy is quarantined rather than dropped',
      );
    });
  });

  group('accounting (features 2, 6)', () {
    test('re-protecting unchanged content changes nothing', () async {
      final bytes = payload(2048, 'stable-content');
      await storage.putFile(fileId: 'stable', bytes: bytes);
      final usedAfterFirst = coordinator.snapshot().usedBytes;

      final second = await storage.putFile(fileId: 'stable', bytes: bytes);
      expect(second.skippedSequences, [0]);
      expect(second.storedChunks, 1);
      expect(second.isComplete, isTrue);
      expect(coordinator.snapshot().usedBytes, usedAfterFirst,
          reason: 'a re-protect must not charge the pool again');
    });

    test('changed content replaces its slot instead of doubling it', () async {
      final v1 = payload(2048, 'version-one');
      final v2 = payload(4096, 'version-two');
      await storage.putFile(fileId: 'edit', bytes: v1);
      final afterV1 = coordinator.snapshot().usedBytes;

      final report = await storage.putFile(fileId: 'edit', bytes: v2);
      expect(report.skippedSequences, isEmpty);
      expect(report.isComplete, isTrue);
      expect(vault.contributors.chunksForFile('edit'), hasLength(1));
      expect(vault.contributors.detachedChunkIds(limit: 100), isEmpty,
          reason: 'both devices confirmed the old copy was deleted');
      expect(coordinator.snapshot().usedBytes, greaterThan(afterV1));

      final read = await storage.getFile('edit');
      expect(read!.isComplete, isTrue);
      expect(read.bytes, v2, reason: 'the reader sees the new version only');
    });

    test('a shrunken file does not leave its old tail behind', () async {
      final long = payload(PoolStorage.chunkSize + 1024, 'long-version');
      final short = payload(1000, 'short');
      await storage.putFile(fileId: 'shrink', bytes: long);
      expect(storage.statusOf('shrink').chunkCount, 2);

      final report = await storage.putFile(fileId: 'shrink', bytes: short);
      expect(report.chunkCount, 1);
      expect(report.isComplete, isTrue);
      expect(storage.statusOf('shrink').chunkCount, 1);

      final read = await storage.getFile('shrink');
      expect(read!.isComplete, isTrue);
      expect(read.bytes, short,
          reason: 'the stale tail must never be reassembled onto the end');
      expect(vault.contributors.chunksForFile('shrink'), hasLength(1));
      expect(vault.contributors.detachedChunkIds(limit: 100), isEmpty,
          reason: 'the delete landed immediately while both devices were up');
      for (var i = 0; i < 2; i++) {
        expect(stores[i].chunkCount, 1, reason: 'device $i freed the tail');
      }
    });

    test('delete frees the quota on every device', () async {
      final bytes = payload(4096, 'goodbye');
      await storage.putFile(fileId: 'gone', bytes: bytes);
      expect(coordinator.snapshot().usedBytes, greaterThan(0));

      final report = await storage.deleteFile('gone');
      expect(report.isFullyReleased, isTrue);
      expect(report.released, 1);
      expect(coordinator.snapshot().usedBytes, 0,
          reason: 'quota actually returned to the devices');
      expect(storage.protectedFileIds(), isEmpty);
      expect(await storage.getFile('gone'), isNull);
      for (var i = 0; i < 2; i++) {
        expect(stores[i].chunkCount, 0, reason: 'device $i purged its copy');
      }
    });

    test('a slot is placed only where there is room for it', () async {
      // Device 0 can afford exactly one chunk; device 1 can afford both.
      coordinator.setQuota(ids[0], PoolStorage.chunkSize + 500);
      stores[0].setQuota(PoolStorage.chunkSize + 500);

      final bytes = payload(PoolStorage.chunkSize + 1000, 'fits-or-not');
      final report = await storage.putFile(fileId: 'tight', bytes: bytes);

      expect(report.isComplete, isTrue,
          reason: 'device 1 has room for every slot');
      expect(report.underReplicated, isTrue,
          reason: 'the small slot had only one place left to go');

      final stored = <int>[];
      for (var i = 0; i < 2; i++) {
        stored.add(vault.contributors
            .listReplicasByContributor(ids[i])
            .where((r) => r.state == ReplicaState.stored)
            .length);
      }
      expect(stored, [1, 2],
          reason: 'device 0 filled up after the first chunk');

      final status = storage.statusOf('tight');
      expect(status.storedChunks, 2);
      expect(status.completeChunks, 1, reason: 'only one slot is at R=2');
      expect(status.isComplete, isFalse);
      expect(status.isPending, isFalse, reason: 'stored, just not redundant');

      final read = await storage.getFile('tight');
      expect(read!.isComplete, isTrue,
          reason: 'a degraded read still returns the file');
      expect(read.degraded, isTrue, reason: 'and says that it was degraded');
      expect(read.bytes, bytes);
    });
  });

  group('degraded and lost data (feature 10)', () {
    test('losing one device degrades the file without losing it', () async {
      final bytes = payload(3000, 'survive');
      await storage.putFile(fileId: 'survive', bytes: bytes);
      expect(storage.statusOf('survive').isComplete, isTrue);

      await coordinator.revoke(ids[1]);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final status = storage.statusOf('survive');
      expect(status.storedChunks, 1, reason: 'the manifest row survives');
      expect(status.completeChunks, 0,
          reason: 'one copy is not R=2, however healthy it looks');
      expect(status.isComplete, isFalse);
      expect(status.degraded, isTrue);

      final read = await storage.getFile('survive');
      expect(read!.isComplete, isTrue,
          reason: 'the surviving copy serves the file');
      expect(read.degraded, isTrue, reason: 'and reports that it had to');
      expect(read.bytes, bytes);
    });

    test('an empty protect is reported as pending, never read as whole',
        () async {
      // Exactly what an interrupted writer leaves behind: the expectation
      // was recorded, only some of the slots landed.
      vault.contributors.upsertFileMeta(
        fileId: 'ghost',
        chunkCount: 2,
        byteLength: 100,
      );

      final status = storage.statusOf('ghost');
      expect(status.isPending, isTrue);
      expect(status.isComplete, isFalse);
      expect(status.storedChunks, 0);
      expect(status.chunkCount, 2,
          reason: 'the expected slot count is known, not guessed');

      final read = await storage.getFile('ghost');
      expect(read, isNotNull, reason: 'the file is known to exist');
      expect(read!.isComplete, isFalse);
      expect(read.bytes, isEmpty,
          reason: 'a partial read is refused, never truncated');
      expect(read.missingSequences, [0, 1]);
      expect(read.chunkCount, 2);
    });

    test('a missing slot is reported instead of silently skipped', () async {
      await storage.putFile(
        fileId: 'gap',
        bytes: payload(PoolStorage.chunkSize + 64, 'gap'),
      );
      expect(vault.contributors.chunksForFile('gap'), hasLength(2));

      // Drop the manifest row for the second slot, as a failed write would.
      vault.contributors.deleteChunkManifest(
          PoolStorage.chunkIdFor('gap', 1));

      final read = await storage.getFile('gap');
      expect(read!.isComplete, isFalse);
      expect(read.bytes, isEmpty);
      expect(read.missingSequences, [1],
          reason: 'only the hole is named, and no bytes are handed back');
      expect(read.chunkCount, 2);
    });

    test('losing every device reports loss rather than a short file', () async {
      final bytes = payload(5000, 'vanish');
      await storage.putFile(fileId: 'vanish', bytes: bytes);

      await coordinator.revoke(ids[0]);
      await coordinator.revoke(ids[1]);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final read = await storage.getFile('vanish');
      expect(read, isNotNull, reason: 'the file still exists on paper');
      expect(read!.isComplete, isFalse);
      expect(read.bytes, isEmpty,
          reason: 'never return a file that looks complete but is not');
      expect(read.missingSequences, [0]);
      expect(coordinator.snapshot().health, PoolHealth.offline);
      expect(coordinator.snapshot().totalQuota, 0);
    });

    test('a file that was never protected reads as null', () async {
      expect(await storage.getFile('nope'), isNull);
      expect(storage.statusOf('nope').isProtected, isFalse);
      expect(storage.protectedFileIds(), isEmpty);
    });
  });
}
