import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/core/utils/cipher.dart';
import 'package:localvault/server/pool/pool_node.dart';
import 'package:localvault/server/pool/pool_node_server.dart';
import 'package:localvault/server/routes/pool_node_router.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

/// Capability token every HTTP test presents in `X-Pool-Token`.
const String poolToken = 'pool-node-test-token';

/// `sha256(poolToken)` — the hash the handler is built with.
final String poolTokenHash = Cipher.sha256String(poolToken);

/// Canonical 64-char lowercase hex chunk id for [seed].
String hexId(int seed) => seed.toRadixString(16).padLeft(64, '0');

List<int> utf8Bytes(String value) => utf8.encode(value);

Future<Directory> newTempDir(String tag) =>
    Directory.systemTemp.createTemp('localvault_pool_node_${tag}_');

/// Every regular file under [dir], relative to it, sorted.
Future<List<String>> relativeFiles(Directory dir) async {
  final files = <String>[];
  if (!await dir.exists()) return files;
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) files.add(p.relative(entity.path, from: dir.path));
  }
  files.sort();
  return files;
}

Future<Map<String, dynamic>> jsonOf(Response response) async {
  final decoded = jsonDecode(await response.readAsString());
  expect(decoded, isA<Map<String, dynamic>>());
  return decoded as Map<String, dynamic>;
}

/// Invokes the in-process handler with a shelf [Request] — no sockets.
Future<Response> call(
  Handler handler,
  String method,
  String path, {
  Map<String, String> headers = const {},
  Object? body,
  bool authenticated = true,
}) async {
  final merged = <String, String>{
    if (authenticated) 'x-pool-token': poolToken,
    ...headers,
  };
  return handler(
    Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: merged,
      body: body,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // Engine (pure dart:io, no HTTP)
  // ---------------------------------------------------------------------------
  group('PoolNodeStore engine', () {
    late Directory dir;
    late PoolNodeStore store;

    setUp(() async {
      dir = await newTempDir('engine');
      store = PoolNodeStore(dir: dir, quotaBytes: 4096);
      await store.open();
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('rejects traversal and non-hex chunk ids before touching a path',
        () async {
      // Where a successful `../../etc/passwd` traversal would have landed.
      final trap = File(p.join(Directory.systemTemp.path, 'etc', 'passwd'));
      final trapExisted = trap.existsSync();

      const badIds = [
        '../../etc/passwd',
        '../../../../../../etc/shadow',
        'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz',
        'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789',
        'short',
        '',
      ];
      for (var i = 0; i < badIds.length; i++) {
        final id = badIds[i];
        final hold = await store.hold(
          idempotencyKey: 'bad-hold-$i',
          chunkId: id,
          bytes: 16,
        );
        expect(hold.outcome, PoolNodeOutcome.invalidId, reason: id);

        final put = await store.put(
          idempotencyKey: 'bad-put-$i',
          chunkId: id,
          bytes: utf8Bytes('payload'),
        );
        expect(put.outcome, PoolNodeOutcome.invalidId, reason: id);

        final commit = await store.commit(
          idempotencyKey: 'bad-commit-$i',
          chunkId: id,
          sha256: 'f' * 64,
        );
        expect(commit.outcome, PoolNodeOutcome.invalidId, reason: id);

        expect(await store.read(id), isNull, reason: id);
        expect(await store.delete(id), isFalse, reason: id);
      }

      expect(store.chunkCount, 0);
      expect(store.usedBytes, 0);
      expect(store.heldBytes, 0);
      expect(await relativeFiles(dir), isEmpty);
      expect(trap.existsSync(), trapExisted);
      expect(
        dir.listSync().map((e) => p.basename(e.path)).toSet(),
        {'chunks', 'tmp'},
      );
    });

    test('quota refuses exactly one byte over and admits exactly to the cap',
        () async {
      store.setQuota(500);
      expect(store.quotaBytes, 500);

      final over = await store.hold(
        idempotencyKey: 'over',
        chunkId: hexId(1),
        bytes: 501,
      );
      expect(over.outcome, PoolNodeOutcome.noSpace);
      expect(store.heldBytes, 0);

      final exact = await store.hold(
        idempotencyKey: 'exact',
        chunkId: hexId(2),
        bytes: 500,
      );
      expect(exact.isSuccess, isTrue);
      expect(store.heldBytes, 500);

      // The reservation already owns the whole cap.
      final second = await store.hold(
        idempotencyKey: 'second',
        chunkId: hexId(3),
        bytes: 1,
      );
      expect(second.outcome, PoolNodeOutcome.noSpace);

      final payload = List<int>.filled(500, 7);
      final put = await store.put(
        idempotencyKey: 'exact',
        chunkId: hexId(2),
        bytes: payload,
      );
      expect(put.isSuccess, isTrue);
      expect(store.usedBytes, 0); // staged, not committed yet

      final commit = await store.commit(
        idempotencyKey: 'exact',
        chunkId: hexId(2),
        sha256: Cipher.sha256Hex(payload),
      );
      expect(commit.isSuccess, isTrue);
      expect(store.usedBytes, 500);
      expect(store.heldBytes, 0);

      // Cap fully consumed by committed bytes now.
      final after = await store.hold(
        idempotencyKey: 'after',
        chunkId: hexId(4),
        bytes: 1,
      );
      expect(after.outcome, PoolNodeOutcome.noSpace);
    });

    test('hold → put → commit increments usedBytes exactly once (idempotent)',
        () async {
      final id = hexId(0xA1);
      final payload = utf8Bytes('hello pooled data cloud');
      final sha = Cipher.sha256Hex(payload);

      final hold = await store.hold(
        idempotencyKey: 'upload-1',
        chunkId: id,
        bytes: payload.length,
      );
      expect(hold.isSuccess, isTrue);
      expect(store.heldBytes, payload.length);

      // Retrying the reservation is a no-op, not a double reservation.
      final holdRetry = await store.hold(
        idempotencyKey: 'upload-1',
        chunkId: id,
        bytes: payload.length,
      );
      expect(holdRetry.isSuccess, isTrue);
      expect(store.heldBytes, payload.length);

      final put = await store.put(
        idempotencyKey: 'upload-1',
        chunkId: id,
        bytes: payload,
        expectedSha256: sha,
      );
      expect(put.isSuccess, isTrue);
      expect(put.sha256, sha);
      expect(put.bytes, payload.length);

      final commit = await store.commit(
        idempotencyKey: 'upload-1',
        chunkId: id,
        sha256: sha,
      );
      expect(commit.isSuccess, isTrue);
      expect(commit.bytes, payload.length);
      expect(store.usedBytes, payload.length);
      expect(store.chunkCount, 1);
      expect(store.heldBytes, 0);

      final commitRetry = await store.commit(
        idempotencyKey: 'upload-1',
        chunkId: id,
        sha256: sha,
      );
      expect(commitRetry.isSuccess, isTrue);
      expect(store.usedBytes, payload.length);
      expect(store.chunkCount, 1);

      expect(await store.read(id), payload);
    });

    test('staged bytes live in tmp/ and are promoted to the sharded path',
        () async {
      final id = hexId(0x21);
      final payload = utf8Bytes('shard me');

      await store.hold(
        idempotencyKey: 'shard',
        chunkId: id,
        bytes: payload.length,
      );
      await store.put(idempotencyKey: 'shard', chunkId: id, bytes: payload);

      final staged = await relativeFiles(Directory(p.join(dir.path, 'tmp')));
      expect(staged, hasLength(1));

      await store.commit(
        idempotencyKey: 'shard',
        chunkId: id,
        sha256: Cipher.sha256Hex(payload),
      );

      final expected = p.join(
        dir.path,
        'chunks',
        id.substring(0, 2),
        id.substring(2, 4),
        id,
      );
      expect(await File(expected).exists(), isTrue);
      expect(await relativeFiles(Directory(p.join(dir.path, 'tmp'))), isEmpty);
      expect(
        await relativeFiles(Directory(p.join(dir.path, 'chunks'))),
        [p.join(id.substring(0, 2), id.substring(2, 4), id)],
      );
    });

    test('open() rescans an existing directory', () async {
      final id = hexId(0x31);
      final payload = utf8Bytes('persisted chunk');
      await store.hold(
        idempotencyKey: 'persist',
        chunkId: id,
        bytes: payload.length,
      );
      await store.put(idempotencyKey: 'persist', chunkId: id, bytes: payload);
      await store.commit(
        idempotencyKey: 'persist',
        chunkId: id,
        sha256: Cipher.sha256Hex(payload),
      );

      final reopened = PoolNodeStore(dir: dir, quotaBytes: 4096);
      await reopened.open();
      expect(reopened.usedBytes, payload.length);
      expect(reopened.chunkCount, 1);
      expect(await reopened.read(id), payload);
    });

    test('put without a live hold is refused', () async {
      final id = hexId(0x41);
      final unknown = await store.put(
        idempotencyKey: 'never-held',
        chunkId: id,
        bytes: utf8Bytes('x'),
      );
      expect(unknown.outcome, PoolNodeOutcome.noHold);

      await store.hold(
        idempotencyKey: 'held-for-other',
        chunkId: hexId(0x42),
        bytes: 4,
      );
      final wrongChunk = await store.put(
        idempotencyKey: 'held-for-other',
        chunkId: id,
        bytes: utf8Bytes('x'),
      );
      expect(wrongChunk.outcome, PoolNodeOutcome.noHold);
      expect(store.chunkCount, 0);
    });

    test('expired hold is refused and swept with its staging file', () async {
      var now = DateTime(2026, 1, 1);
      final ttlDir = await newTempDir('ttl');
      addTearDown(() async {
        if (await ttlDir.exists()) await ttlDir.delete(recursive: true);
      });
      final ttlStore = PoolNodeStore(
        dir: ttlDir,
        quotaBytes: 1024,
        clock: () => now,
      );
      await ttlStore.open();

      final id = hexId(0x51);
      final payload = utf8Bytes('slow upload');
      await ttlStore.hold(idempotencyKey: 'slow', chunkId: id, bytes: 100);
      await ttlStore.put(idempotencyKey: 'slow', chunkId: id, bytes: payload);
      expect(ttlStore.heldBytes, 100);
      expect(
        await relativeFiles(Directory(p.join(ttlDir.path, 'tmp'))),
        hasLength(1),
      );

      now = now.add(PoolNodeStore.holdTtl + const Duration(seconds: 1));

      expect(ttlStore.heldBytes, 0); // expired holds never count
      final refused = await ttlStore.put(
        idempotencyKey: 'slow',
        chunkId: id,
        bytes: payload,
      );
      expect(refused.outcome, PoolNodeOutcome.noHold);

      ttlStore.sweep();
      expect(await relativeFiles(Directory(p.join(ttlDir.path, 'tmp'))), isEmpty);
      expect(ttlStore.chunkCount, 0);
      expect(ttlStore.usedBytes, 0);
    });

    test('hash mismatch on commit is refused and nothing is promoted',
        () async {
      final id = hexId(0x61);
      final payload = utf8Bytes('correct bytes');
      final wrongSha = 'f' * 64;

      await store.hold(
        idempotencyKey: 'hm',
        chunkId: id,
        bytes: payload.length,
      );

      final badPut = await store.put(
        idempotencyKey: 'hm',
        chunkId: id,
        bytes: payload,
        expectedSha256: wrongSha,
      );
      expect(badPut.outcome, PoolNodeOutcome.hashMismatch);

      final put = await store.put(
        idempotencyKey: 'hm',
        chunkId: id,
        bytes: payload,
        expectedSha256: Cipher.sha256Hex(payload),
      );
      expect(put.isSuccess, isTrue);

      final badCommit = await store.commit(
        idempotencyKey: 'hm',
        chunkId: id,
        sha256: wrongSha,
      );
      expect(badCommit.outcome, PoolNodeOutcome.hashMismatch);
      expect(await store.read(id), isNull);
      expect(store.chunkCount, 0);
      expect(store.usedBytes, 0);

      // The staged file stayed in tmp/ — a correct digest still commits.
      final goodCommit = await store.commit(
        idempotencyKey: 'hm',
        chunkId: id,
        sha256: Cipher.sha256Hex(payload),
      );
      expect(goodCommit.isSuccess, isTrue);
      expect(store.chunkCount, 1);
      expect(store.usedBytes, payload.length);
    });

    test('abort releases the hold so quota is free again', () async {
      store.setQuota(100);
      final id = hexId(0x71);
      final payload = utf8Bytes('abandoned upload');

      await store.hold(idempotencyKey: 'abort-me', chunkId: id, bytes: 100);
      expect(store.heldBytes, 100);
      final blocked = await store.hold(
        idempotencyKey: 'other',
        chunkId: hexId(0x72),
        bytes: 1,
      );
      expect(blocked.outcome, PoolNodeOutcome.noSpace);

      await store.put(
        idempotencyKey: 'abort-me',
        chunkId: id,
        bytes: payload,
      );
      expect(
        await relativeFiles(Directory(p.join(dir.path, 'tmp'))),
        hasLength(1),
      );

      expect(await store.abort('abort-me'), isTrue);
      expect(store.heldBytes, 0);
      expect(await relativeFiles(Directory(p.join(dir.path, 'tmp'))), isEmpty);

      final freed = await store.hold(
        idempotencyKey: 'other',
        chunkId: hexId(0x72),
        bytes: 100,
      );
      expect(freed.isSuccess, isTrue);

      final putAfterAbort = await store.put(
        idempotencyKey: 'abort-me',
        chunkId: id,
        bytes: payload,
      );
      expect(putAfterAbort.outcome, PoolNodeOutcome.noHold);

      // Idempotent: unknown keys are fine.
      expect(await store.abort('never-existed'), isTrue);
    });

    test('reusing a live idempotency key for another reservation conflicts',
        () async {
      final first = await store.hold(
        idempotencyKey: 'key-1',
        chunkId: hexId(0x81),
        bytes: 32,
      );
      expect(first.isSuccess, isTrue);

      final differentChunk = await store.hold(
        idempotencyKey: 'key-1',
        chunkId: hexId(0x82),
        bytes: 32,
      );
      expect(differentChunk.outcome, PoolNodeOutcome.conflict);

      final differentSize = await store.hold(
        idempotencyKey: 'key-1',
        chunkId: hexId(0x81),
        bytes: 64,
      );
      expect(differentSize.outcome, PoolNodeOutcome.conflict);
      expect(store.heldBytes, 32);
    });

    test('wipe deletes every chunk and returns the count', () async {
      final payloads = <String, List<int>>{
        hexId(0x91): utf8Bytes('first chunk'),
        hexId(0x92): utf8Bytes('second chunk'),
      };
      for (final entry in payloads.entries) {
        await store.hold(
          idempotencyKey: 'w-${entry.key}',
          chunkId: entry.key,
          bytes: entry.value.length,
        );
        await store.put(
          idempotencyKey: 'w-${entry.key}',
          chunkId: entry.key,
          bytes: entry.value,
        );
        await store.commit(
          idempotencyKey: 'w-${entry.key}',
          chunkId: entry.key,
          sha256: Cipher.sha256Hex(entry.value),
        );
      }
      expect(store.chunkCount, 2);
      expect(store.usedBytes, 23); // 'first chunk' + 'second chunk'

      final deleted = await store.wipe();
      expect(deleted, 2);
      expect(store.chunkCount, 0);
      expect(store.usedBytes, 0);
      for (final id in payloads.keys) {
        expect(await store.read(id), isNull);
      }
      expect(
        await relativeFiles(Directory(p.join(dir.path, 'chunks'))),
        isEmpty,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // HTTP routes (in-process shelf handler, no sockets)
  // ---------------------------------------------------------------------------
  group('pool node HTTP API', () {
    late Directory dir;
    late PoolNodeStore store;
    late Handler handler;

    setUp(() async {
      dir = await newTempDir('http');
      store = PoolNodeStore(dir: dir, quotaBytes: 4096);
      await store.open();
      handler = buildPoolNodeHandler(store: store, tokenHash: poolTokenHash);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('rejects missing and wrong tokens with 401', () async {
      final missing = await call(
        handler,
        'GET',
        '/node/v1/status',
        authenticated: false,
      );
      expect(missing.statusCode, 401);
      final missingJson = await jsonOf(missing);
      expect(missingJson['ok'], false);
      expect((missingJson['error'] as Map)['code'], 'UNAUTHORIZED');

      final wrong = await call(
        handler,
        'GET',
        '/node/v1/status',
        headers: {'x-pool-token': 'not-the-token'},
      );
      expect(wrong.statusCode, 401);

      final wrongLength = await call(
        handler,
        'POST',
        '/node/v1/hold',
        headers: {'x-pool-token': 'x'},
        body: jsonEncode({
          'idempotency_key': 'k',
          'chunk_id': hexId(1),
          'bytes': 1,
        }),
      );
      expect(wrongLength.statusCode, 401);

      final authorized = await call(handler, 'GET', '/node/v1/status');
      expect(authorized.statusCode, 200);
      final json = await jsonOf(authorized);
      expect(json['ok'], true);
      expect(json.keys.toList(), [
        'ok',
        'used_bytes',
        'quota_bytes',
        'held_bytes',
        'chunk_count',
        'disk_free_bytes',
      ]);
      expect(json['quota_bytes'], store.quotaBytes);
      expect(json['used_bytes'], 0);
      expect(json['held_bytes'], 0);
      expect(json['chunk_count'], 0);
      expect(json['disk_free_bytes'], isA<int>());
    });

    test('hold → put → commit → get → delete round trip', () async {
      final id = hexId(0xB1);
      final payload = utf8Bytes('round trip payload');
      final sha = Cipher.sha256Hex(payload);

      final hold = await call(
        handler,
        'POST',
        '/node/v1/hold',
        body: jsonEncode({
          'idempotency_key': 'up-1',
          'chunk_id': id,
          'bytes': payload.length,
        }),
      );
      expect(hold.statusCode, 200);
      expect((await jsonOf(hold))['ok'], true);
      expect(store.heldBytes, payload.length);

      final holdRetry = await call(
        handler,
        'POST',
        '/node/v1/hold',
        body: jsonEncode({
          'idempotency_key': 'up-1',
          'chunk_id': id,
          'bytes': payload.length,
        }),
      );
      expect(holdRetry.statusCode, 200);
      expect(store.heldBytes, payload.length);

      final put = await call(
        handler,
        'PUT',
        '/node/v1/chunk/$id',
        headers: {'x-idempotency-key': 'up-1', 'x-chunk-sha256': sha},
        body: payload,
      );
      expect(put.statusCode, 200);
      final putJson = await jsonOf(put);
      expect(putJson['sha256'], sha);
      expect(putJson['bytes'], payload.length);

      final commit = await call(
        handler,
        'POST',
        '/node/v1/commit',
        body: jsonEncode({
          'idempotency_key': 'up-1',
          'chunk_id': id,
          'sha256': sha,
        }),
      );
      expect(commit.statusCode, 200);
      final commitJson = await jsonOf(commit);
      expect(commitJson['sha256'], sha);
      expect(commitJson['bytes'], payload.length);
      expect(store.usedBytes, payload.length);

      final get = await call(handler, 'GET', '/node/v1/chunk/$id');
      expect(get.statusCode, 200);
      expect(get.headers['content-length'], '${payload.length}');
      expect(get.headers['x-chunk-sha256'], sha);
      expect(await get.read().expand((part) => part).toList(), payload);

      final delete = await call(handler, 'DELETE', '/node/v1/chunk/$id');
      expect(delete.statusCode, 200);
      expect((await jsonOf(delete))['ok'], true);

      final deleteAgain = await call(handler, 'DELETE', '/node/v1/chunk/$id');
      expect(deleteAgain.statusCode, 404);
      expect(store.usedBytes, 0);
      expect(store.chunkCount, 0);
    });

    test('missing chunk is 404 and quota refusal is 409 NO_SPACE', () async {
      final missing = await call(
        handler,
        'GET',
        '/node/v1/chunk/${hexId(0xC1)}',
      );
      expect(missing.statusCode, 404);
      expect((await jsonOf(missing))['ok'], false);

      store.setQuota(8);
      final refused = await call(
        handler,
        'POST',
        '/node/v1/hold',
        body: jsonEncode({
          'idempotency_key': 'too-big',
          'chunk_id': hexId(0xC2),
          'bytes': 9,
        }),
      );
      expect(refused.statusCode, 409);
      final refusedJson = await jsonOf(refused);
      expect(refusedJson['ok'], false);
      expect((refusedJson['error'] as Map)['code'], 'NO_SPACE');
    });

    test('invalid chunk ids are 400 and never reach the store', () async {
      final encodedTraversal = await call(
        handler,
        'PUT',
        '/node/v1/chunk/..%2F..%2Fetc%2Fpasswd',
        headers: {'x-idempotency-key': 'evil'},
        body: utf8Bytes('gotcha'),
      );
      expect(encodedTraversal.statusCode, 400);
      expect((await jsonOf(encodedTraversal))['ok'], false);

      final nonHex = await call(
        handler,
        'PUT',
        '/node/v1/chunk/not-a-hash',
        headers: {'x-idempotency-key': 'evil'},
        body: utf8Bytes('gotcha'),
      );
      expect(nonHex.statusCode, 400);

      // A literal traversal path is normalised away by the URI parser and
      // therefore never routes to the chunk handler at all.
      final rawTraversal = await call(
        handler,
        'GET',
        '/node/v1/chunk/../../etc/passwd',
      );
      expect(rawTraversal.statusCode, 404);

      expect(store.chunkCount, 0);
      expect(store.usedBytes, 0);
      expect(await relativeFiles(dir), isEmpty);
    });

    test('PUT requires X-Idempotency-Key and a matching hold', () async {
      final id = hexId(0xD1);
      final payload = utf8Bytes('bytes');

      final noKey = await call(
        handler,
        'PUT',
        '/node/v1/chunk/$id',
        body: payload,
      );
      expect(noKey.statusCode, 400);

      final noHold = await call(
        handler,
        'PUT',
        '/node/v1/chunk/$id',
        headers: {'x-idempotency-key': 'nope'},
        body: payload,
      );
      expect(noHold.statusCode, 409);
      expect(((await jsonOf(noHold))['error'] as Map)['code'], 'NO_HOLD');
    });

    test('hash mismatch on commit is 400 and nothing is stored', () async {
      final id = hexId(0xE1);
      final payload = utf8Bytes('integrity');
      await call(
        handler,
        'POST',
        '/node/v1/hold',
        body: jsonEncode({
          'idempotency_key': 'hm',
          'chunk_id': id,
          'bytes': payload.length,
        }),
      );
      await call(
        handler,
        'PUT',
        '/node/v1/chunk/$id',
        headers: {'x-idempotency-key': 'hm'},
        body: payload,
      );

      final bad = await call(
        handler,
        'POST',
        '/node/v1/commit',
        body: jsonEncode({
          'idempotency_key': 'hm',
          'chunk_id': id,
          'sha256': 'f' * 64,
        }),
      );
      expect(bad.statusCode, 400);
      expect(((await jsonOf(bad))['error'] as Map)['code'], 'HASH_MISMATCH');
      expect(store.chunkCount, 0);

      final get = await call(handler, 'GET', '/node/v1/chunk/$id');
      expect(get.statusCode, 404);
    });

    test('commit without staged bytes is 404', () async {
      final response = await call(
        handler,
        'POST',
        '/node/v1/commit',
        body: jsonEncode({
          'idempotency_key': 'nothing',
          'chunk_id': hexId(0xF1),
          'sha256': 'a' * 64,
        }),
      );
      expect(response.statusCode, 404);
    });

    test('abort always answers ok, even for unknown keys', () async {
      final unknown = await call(
        handler,
        'POST',
        '/node/v1/abort',
        body: jsonEncode({'idempotency_key': 'never-existed'}),
      );
      expect(unknown.statusCode, 200);
      expect((await jsonOf(unknown))['ok'], true);

      final id = hexId(0x101);
      await call(
        handler,
        'POST',
        '/node/v1/hold',
        body: jsonEncode({
          'idempotency_key': 'to-abort',
          'chunk_id': id,
          'bytes': 64,
        }),
      );
      expect(store.heldBytes, 64);
      final aborted = await call(
        handler,
        'POST',
        '/node/v1/abort',
        body: jsonEncode({'idempotency_key': 'to-abort'}),
      );
      expect(aborted.statusCode, 200);
      expect(store.heldBytes, 0);
    });

    test('wipe needs confirmation, then deletes everything', () async {
      final id = hexId(0x111);
      final payload = utf8Bytes('delete me');
      await call(
        handler,
        'POST',
        '/node/v1/hold',
        body: jsonEncode({
          'idempotency_key': 'w',
          'chunk_id': id,
          'bytes': payload.length,
        }),
      );
      await call(
        handler,
        'PUT',
        '/node/v1/chunk/$id',
        headers: {'x-idempotency-key': 'w'},
        body: payload,
      );
      await call(
        handler,
        'POST',
        '/node/v1/commit',
        body: jsonEncode({
          'idempotency_key': 'w',
          'chunk_id': id,
          'sha256': Cipher.sha256Hex(payload),
        }),
      );
      expect(store.chunkCount, 1);

      final unconfirmed = await call(
        handler,
        'POST',
        '/node/v1/wipe',
        body: jsonEncode({'confirm': 'nope'}),
      );
      expect(unconfirmed.statusCode, 403);
      expect(store.chunkCount, 1);

      final confirmed = await call(
        handler,
        'POST',
        '/node/v1/wipe',
        body: jsonEncode({'confirm': 'wipe'}),
      );
      expect(confirmed.statusCode, 200);
      final json = await jsonOf(confirmed);
      expect(json['ok'], true);
      expect(json['deleted'], 1);
      expect(store.chunkCount, 0);
      expect(store.usedBytes, 0);
      expect(await store.read(id), isNull);
    });

    test('malformed JSON body is a 400 in the shared envelope', () async {
      final response = await call(
        handler,
        'POST',
        '/node/v1/hold',
        body: 'not-json',
      );
      expect(response.statusCode, 400);
      final json = await jsonOf(response);
      expect(json['ok'], false);
      expect((json['error'] as Map)['code'], 'VALIDATION_ERROR');
      expect(store.heldBytes, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // Real socket end-to-end
  // ---------------------------------------------------------------------------
  group('PoolNodeServer', () {
    late Directory dir;
    late PoolNodeStore store;

    setUp(() async {
      dir = await newTempDir('socket');
      store = PoolNodeStore(dir: dir, quotaBytes: 4096);
      await store.open();
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('serves the node API over a real socket', () async {
      // flutter_test installs an HttpOverrides stub that answers every
      // request with 400; this test exercises a real socket, so real HTTP
      // is restored for its duration.
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() {
        HttpOverrides.global = previousOverrides;
      });

      final server = await PoolNodeServer.start(
        store: store,
        tokenHash: poolTokenHash,
        preferredPort: 5321,
      );
      addTearDown(() async {
        await server.stop();
      });

      expect(server.port, isNotNull);
      expect(server.isSecure, isFalse);
      expect(server.scheme, 'http');
      expect(server.baseUrl, startsWith('http://'));
      expect(server.baseUrl, endsWith(':${server.port}'));

      final client = HttpClient();
      try {
        final unauthorized = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/node/v1/status'),
        );
        final unauthorizedResponse = await unauthorized.close();
        expect(unauthorizedResponse.statusCode, 401);
        await unauthorizedResponse.transform(utf8.decoder).join();

        final request = await client.getUrl(
          Uri.parse('${server.baseUrl}/node/v1/status'),
        );
        request.headers.set('x-pool-token', poolToken);
        final response = await request.close();
        expect(response.statusCode, 200);
        final body = await response.transform(utf8.decoder).join();
        expect(jsonDecode(body)['ok'], true);
      } finally {
        client.close(force: true);
      }
    });
  });
}
