import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/core/utils/pool_cipher.dart';
import 'package:localvault/data/datasources/vault.dart';
import 'package:localvault/data/models/device.dart';
import 'package:localvault/server/middleware/api_responses.dart';
import 'package:localvault/server/pool/pool_coordinator.dart';
import 'package:localvault/server/routes/pool_router.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

/// HTTP-level contract of the pool API (`lib/server/routes/pool_router.dart`),
/// driven through the real `errorHandler()` middleware so the status codes a
/// client actually sees are what is asserted.
void main() {
  late Directory dir;
  late Vault vault;
  late PoolCoordinator coordinator;
  late PoolApiHandlers pool;
  late Handler deviceApi;
  late Handler contributorApi;

  const chunkId =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  final device = Device(
    id: 'device-1',
    name: 'Pixel 7',
    createdAt: DateTime(2026, 1, 1),
  );

  setUp(() async {
    dir = Directory(
        '${Directory.systemTemp.path}/lv_api_${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    vault = await Vault.create(dir);
    coordinator = PoolCoordinator(
      vault: vault,
      keyStore: FilePoolKeyStore(vaultDir: vault.vaultDir),
    );
    pool = PoolApiHandlers(vault: vault, coordinator: coordinator);

    final deviceRouter = Router();
    pool.register(deviceRouter);
    deviceApi = const Pipeline()
        .addMiddleware(errorHandler())
        .addHandler(deviceRouter.call);

    final contributorRouter = Router()
      ..post('/api/v1/pool/heartbeat', pool.heartbeat);
    contributorApi = const Pipeline()
        .addMiddleware(errorHandler())
        .addHandler(contributorRouter.call);
  });

  tearDown(() {
    coordinator.dispose();
    vault.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Request deviceRequest(
    String method,
    String path, {
    Object? body,
    Map<String, String> headers = const {},
  }) =>
      Request(
        method,
        Uri.parse('http://localhost$path'),
        body: body == null ? null : jsonEncode(body),
        headers: {
          'content-type': 'application/json',
          ...headers,
        },
        context: {'device': device},
      );

  Future<Map<String, dynamic>> decode(Response response) async {
    final text = await response.readAsString();
    final decoded = jsonDecode(text);
    expect(decoded, isA<Map<String, dynamic>>());
    return decoded as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> register({
    int quota = 10 << 30,
    String endpoint = 'http://192.168.1.50:5321',
  }) async {
    final response = await deviceApi(deviceRequest(
      'POST',
      '/api/v1/pool/register',
      body: {
        'name': 'Pixel 7',
        'quota_bytes': quota,
        'endpoint': endpoint,
        'device_kind': 'phone',
        'nonce': 'n-${DateTime.now().microsecondsSinceEpoch}',
      },
    ));
    // shelf bodies are single-use: read exactly once.
    final text = await response.readAsString();
    expect(response.statusCode, 201, reason: text);
    return jsonDecode(text) as Map<String, dynamic>;
  }

  group('device routes', () {
    test('status is a derived snapshot with an honest headline', () async {
      final body = await decode(await deviceApi(
          deviceRequest('GET', '/api/v1/pool/status')));
      expect(body['ok'], isTrue);
      expect(body['health'], 'EMPTY');
      expect(body['total_quota'], 0);
      expect(body['contributors'], isEmpty);
      expect(body['epoch'], isA<int>());
    });

    test('register returns the capability token exactly once', () async {
      final body = await register();
      expect(body['ok'], isTrue);
      expect(body['contributor_id'], isA<String>());
      expect(body['token'], isA<String>());
      expect(body['heartbeat_sec'], 60);
      expect(body['epoch'], isA<int>());

      final status =
          await decode(await deviceApi(deviceRequest('GET', '/api/v1/pool/status')));
      expect(status['health'], 'ONLINE');
      expect(status['total_quota'], 10 << 30);
      expect((status['contributors'] as List).length, 1);
    });

    test('register validates before it writes', () async {
      for (final body in [
        {'name': 'x', 'quota_bytes': 0, 'endpoint': 'http://a.test:1'},
        {'name': 'x', 'quota_bytes': 100, 'endpoint': 'ftp://a.test:1'},
        {'name': 'x', 'quota_bytes': 100, 'endpoint': ''},
      ]) {
        final response = await deviceApi(
            deviceRequest('POST', '/api/v1/pool/register', body: body));
        expect(response.statusCode, 400, reason: '$body must be rejected');
        expect(vault.contributors.list(), isEmpty);
      }
    });

    test('quota cannot be lowered below stored bytes and never goes negative',
        () async {
      final reg = await register(quota: 1000);
      final id = reg['contributor_id'] as String;
      vault.contributors.reserveChunk('k', chunkId, id, 800);
      vault.contributors.commitReservation('k', id, 'ab' * 32);

      final tooLow = await deviceApi(deviceRequest(
        'PATCH',
        '/api/v1/pool/contributors/$id',
        body: {'quota_bytes': 100},
      ));
      expect(tooLow.statusCode, 409);

      final negative = await deviceApi(deviceRequest(
        'PATCH',
        '/api/v1/pool/contributors/$id',
        body: {'quota_bytes': -5},
      ));
      expect(negative.statusCode, 400);

      final missing = await deviceApi(deviceRequest(
        'PATCH',
        '/api/v1/pool/contributors/$id',
        body: <String, Object?>{},
      ));
      expect(missing.statusCode, 400);

      final ok = await deviceApi(deviceRequest(
        'PATCH',
        '/api/v1/pool/contributors/$id',
        body: {'quota_bytes': 2000},
      ));
      expect(ok.statusCode, 200);
      expect(vault.contributors.getById(id).quotaBytes, 2000);
    });

    test('revoke reports the re-replication backlog immediately', () async {
      final reg = await register(quota: 1000);
      final id = reg['contributor_id'] as String;
      final body = await decode(await deviceApi(deviceRequest(
          'POST', '/api/v1/pool/contributors/$id/revoke')));
      expect(body['ok'], isTrue);
      expect(body['revoked'], isTrue);
      expect(body['chunks_to_repair'], 0);

      // The pool must stop counting it right away.
      final status =
          await decode(await deviceApi(deviceRequest('GET', '/api/v1/pool/status')));
      expect(status['total_quota'], 0);
      expect(status['health'], 'OFFLINE');
    });

    test('leaving a pool you never joined is a 404, not a silent success',
        () async {
      final response = await deviceApi(deviceRequest('POST', '/api/v1/pool/leave'));
      expect(response.statusCode, 404);
    });

    test('leave stops the contribution counting at once', () async {
      await register(quota: 7 << 30);
      final body =
          await decode(await deviceApi(deviceRequest('POST', '/api/v1/pool/leave')));
      expect(body['ok'], isTrue);
      expect((body['left'] as List).length, 1);

      final status =
          await decode(await deviceApi(deviceRequest('GET', '/api/v1/pool/status')));
      expect(status['total_quota'], 0);
      expect(status['offline_quota'], 7 << 30,
          reason: 'vanished capacity stays visible, never silently dropped');
    });

    test('chunk write requires an idempotency key and a content hash', () async {
      final noKey = await deviceApi(Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/pool/chunks/$chunkId'),
        body: [1, 2, 3],
        context: {'device': device},
      ));
      expect(noKey.statusCode, 400);

      final noHash = await deviceApi(Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/pool/chunks/$chunkId'),
        body: [1, 2, 3],
        headers: {'x-idempotency-key': 'key-1'},
        context: {'device': device},
      ));
      expect(noHash.statusCode, 400);
    });

    test('chunk ids are validated before any path is built (§6 control 5)',
        () async {
      // A percent-encoded slash decodes before shelf_router matches, so the
      // traversal shape never even reaches a handler: it 404s at routing.
      final traversal = await deviceApi(deviceRequest(
          'GET', '/api/v1/pool/chunks/..%2F..%2Fetc%2Fpasswd/locations'));
      expect([400, 404], contains(traversal.statusCode),
          reason: 'a traversal id must never resolve to a successful read');

      // `..` is normalised away by the router too (it 404s, never 200s).
      final dotted = await deviceApi(
          deviceRequest('GET', '/api/v1/pool/chunks/%2e%2e/locations'));
      expect([400, 404], contains(dotted.statusCode));

      // Everything that does survive routing has to be caught by the validator:
      // wrong length, uppercase, and right-length-but-not-hex.
      for (final bad in ['not-hex', 'AB', '${'0' * 63}F', 'g'.padRight(64, 'g')]) {
        final response = await deviceApi(deviceRequest(
            'GET', '/api/v1/pool/chunks/$bad/locations'));
        expect(response.statusCode, 400, reason: 'chunk id "$bad"');
      }
      final missing = await deviceApi(
          deviceRequest('GET', '/api/v1/pool/chunks/$chunkId/locations'));
      expect(missing.statusCode, 200);
      final body = await decode(missing);
      expect(body['locations'], isEmpty);
      expect(body['degraded'], isTrue);
    });

    test('maintenance reports a health headline', () async {
      await register();
      final body = await decode(
          await deviceApi(deviceRequest('POST', '/api/v1/pool/maintenance')));
      expect(body['ok'], isTrue);
      expect(body['health'], 'ONLINE');
      expect(body['epoch'], isA<int>());
    });
  });

  group('contributor-token route (§1)', () {
    test('rejects a missing or wrong token with 401', () async {
      for (final headers in <Map<String, String>>[
        const {},
        const {'x-pool-token': 'wrong'},
      ]) {
        final response = await contributorApi(Request(
          'POST',
          Uri.parse('http://localhost/api/v1/pool/heartbeat'),
          body: jsonEncode({'report_seq': 1, 'used_bytes': 0, 'free_bytes': 1}),
          headers: {'content-type': 'application/json', ...headers},
        ));
        expect(response.statusCode, 401);
        final body = await decode(response);
        expect(body['ok'], isFalse);
        expect(body['error']['code'], 'UNAUTHORIZED');
      }
    });

    test('accepts a monotonic report and rejects a stale one', () async {
      final reg = await register(quota: 1000);
      final token = reg['token'] as String;
      final id = reg['contributor_id'] as String;

      Future<Response> beat(int seq, {int used = 0}) async => contributorApi(Request(
            'POST',
            Uri.parse('http://localhost/api/v1/pool/heartbeat'),
            body: jsonEncode(
                {'report_seq': seq, 'used_bytes': used, 'free_bytes': 500}),
            headers: {
              'content-type': 'application/json',
              'x-pool-token': token,
            },
          ));

      final first = await decode(await beat(5, used: 250));
      expect(first['ok'], isTrue);
      expect(first['accepted'], isTrue);
      expect(vault.contributors.getById(id).reportedUsedBytes, 250);
      expect(vault.contributors.getById(id).usedBytes, 0,
          reason: 'the ledger stays host-owned even over HTTP (D5)');

      final stale = await decode(await beat(4, used: 999));
      expect(stale['ok'], isTrue);
      expect(stale['accepted'], isFalse,
          reason: 'a stale report must be dropped, not merged');
      expect(vault.contributors.getById(id).reportedUsedBytes, 250);

      final zero = await decode(await beat(0));
      expect(zero['ok'], isFalse);
      expect(zero['error']['code'], 'VALIDATION_ERROR');
    });

    test('a revoked contributor cannot heartbeat any more', () async {
      final reg = await register();
      final token = reg['token'] as String;
      final id = reg['contributor_id'] as String;
      await deviceApi(deviceRequest('POST', '/api/v1/pool/contributors/$id/revoke'));

      final response = await contributorApi(Request(
        'POST',
        Uri.parse('http://localhost/api/v1/pool/heartbeat'),
        body: jsonEncode({'report_seq': 9, 'used_bytes': 0, 'free_bytes': 1}),
        headers: {'content-type': 'application/json', 'x-pool-token': token},
      ));
      expect(response.statusCode, 401);
    });
  });
}
