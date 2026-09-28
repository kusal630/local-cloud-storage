// Unit tests for the v2.4.0 Pooled Data Cloud client slice:
// `PoolService` (coordinator API) and `ContributorAgent` (this device
// contributes storage).
//
// There is no network here: every request is answered by a fake
// [HttpClientAdapter], and the agent's persistence goes through an in-memory
// [PoolAgentStorage] instead of the secure-storage / shared-preferences
// plugins.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/client/api_client.dart';
import 'package:localvault/client/auth_interceptor.dart';
import 'package:localvault/client/services/contributor_agent.dart';
import 'package:localvault/client/services/pool_service.dart';
import 'package:localvault/client/session_store.dart';
import 'package:localvault/core/errors/app_exceptions.dart';
import 'package:localvault/features/pool/pool_models.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// One request the service made, captured before it left the process.
class RecordedCall {
  RecordedCall(this.options, this.body);

  final RequestOptions options;
  final Uint8List body;

  /// Case-insensitive header lookup (Dio's own map already is, this keeps
  /// the assertions readable).
  String? header(String name) {
    final direct = options.headers[name];
    if (direct != null) return direct.toString();
    for (final entry in options.headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) {
        return entry.value?.toString();
      }
    }
    return null;
  }

  String get method => options.method;

  String get path => options.uri.path;

  /// JSON request body, when the call sent one.
  Map<String, dynamic>? get bodyJson {
    final data = options.data;
    return data is Map<String, dynamic> ? data : null;
  }
}

ResponseBody jsonResponse(int status, Map<String, Object?> payload) {
  return ResponseBody.fromString(
    jsonEncode(payload),
    status,
    headers: {
      'content-type': ['application/json; charset=utf-8'],
    },
  );
}

/// In-process [HttpClientAdapter] — records every call and answers from a
/// programmable responder (default: `{"ok": true}`).
class FakePoolAdapter implements HttpClientAdapter {
  final List<RecordedCall> calls = [];

  ResponseBody Function(RequestOptions options, Uint8List body)? onCall;

  RecordedCall get onlyCall {
    if (calls.length != 1) {
      throw StateError('expected exactly one call, saw ${calls.length}');
    }
    return calls.first;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final raw = <int>[];
    if (requestStream != null) {
      await for (final part in requestStream) {
        raw.addAll(part);
      }
    }
    final call = RecordedCall(options, Uint8List.fromList(raw));
    calls.add(call);
    final respond = onCall;
    if (respond == null) return jsonResponse(200, {'ok': true});
    return respond(options, call.body);
  }

  @override
  void close({bool force = false}) {}
}

/// In-memory stand-in for [SecurePoolAgentStorage].
class InMemoryPoolAgentStorage implements PoolAgentStorage {
  PoolAgentRecord? record;
  int writes = 0;

  @override
  Future<PoolAgentRecord?> read() async => record;

  @override
  Future<void> write(PoolAgentRecord next) async {
    record = next;
    writes += 1;
  }

  @override
  Future<void> clear() async {
    record = null;
  }
}

LocalVaultApi buildApi(FakePoolAdapter adapter) {
  final api = LocalVaultApi(session: SessionStore());
  api.configure('http://coordinator.test');
  api.dio.httpClientAdapter = adapter;
  return api;
}

/// Simulates a logged-in paired device: the AuthInterceptor caches a bearer.
void primeAccessToken(LocalVaultApi api, String token) {
  for (final interceptor in api.dio.interceptors) {
    if (interceptor is AuthInterceptor) interceptor.primeToken(token);
  }
}

const String validChunkId =
    'a3f1c2d4e5b60718293a4b5c6d7e8f90'
    '123456789abcdef0123456789abcdef0';
const String validContentSha =
    '00112233445566778899aabbccddeeff'
    '00112233445566778899aabbccddeeff';

Map<String, Object?> statusPayload() => {
      'ok': true,
      'total_quota': 1000,
      'used_bytes': 400,
      'reserved_bytes': 50,
      'available_quota': 800,
      'offline_quota': 200,
      'free_bytes': 550,
      'epoch': 7,
      'health': 'DEGRADED',
      'chunk_count': 12,
      'degraded_chunks': 2,
      'quota_exceeded': false,
      'generated_at': '2026-09-27T10:00:00.000',
      'contributors': [
        {
          'id': 'c-live',
          'device_id': 'd-1',
          'name': 'Pixel 7',
          'status': 'ALIVE',
          'quota_bytes': 800,
          'used_bytes': 400,
          'free_bytes': 400,
          'device_kind': 'phone',
          'is_this_device': true,
          'last_seen': '2026-09-27T09:59:30.000',
          'endpoint': 'http://192.168.1.10:5321',
          'last_error': null,
        },
        {
          'id': 'c-suspect',
          'device_id': 'd-2',
          'name': 'Old Laptop',
          'status': 'SUSPECT',
          'quota_bytes': 200,
          'used_bytes': 0,
          'free_bytes': 200,
          'device_kind': 'laptop',
          'is_this_device': false,
          'last_seen': '2026-09-27T09:44:00.000',
          'endpoint': 'http://192.168.1.22:5321',
          'last_error': 'connection refused',
        },
      ],
    };

// ---------------------------------------------------------------------------
// PoolService — status mapping
// ---------------------------------------------------------------------------

void main() {
  group('PoolService.fetch', () {
    test('maps the status JSON into PoolStatus', () async {
      final adapter = FakePoolAdapter()
        ..onCall = (options, body) => jsonResponse(200, statusPayload());
      final pool = PoolService(buildApi(adapter));

      final status = await pool.fetchStatus();

      expect(status.totalQuota, 1000);
      expect(status.usedBytes, 400);
      expect(status.quotaExceeded, isFalse);
      expect(status.contributors, hasLength(2));

      final live = status.contributors.first;
      expect(live.id, 'c-live');
      expect(live.name, 'Pixel 7');
      expect(live.quotaBytes, 800);
      expect(live.usedBytes, 400);
      expect(live.isThisDevice, isTrue);
      expect(live.deviceKind, 'phone');
      expect(live.status, PoolContributorStatus.online);
      expect(live.lastSeen, isA<DateTime>());

      // CONSULT §1 liveness: SUSPECT is *not* healthy, and the screen must
      // keep it out of placement — it lands in `offline`.
      final suspect = status.contributors[1];
      expect(suspect.status, PoolContributorStatus.offline);
      expect(suspect.isOffline, isTrue);

      expect(status.offlineQuota, 200);
      expect(status.viewState, PoolViewState.degraded);
    });

    test('exposes the fields PoolStatus has no slot for as diagnostics',
        () async {
      final adapter = FakePoolAdapter()
        ..onCall = (options, body) => jsonResponse(200, statusPayload());
      final pool = PoolService(buildApi(adapter));

      final result = await pool.fetch();

      expect(result.status.totalQuota, 1000);
      final diag = result.diagnostics;
      expect(diag.epoch, 7);
      expect(diag.health, PoolHealthState.degraded);
      expect(diag.health.label, 'DEGRADED');
      expect(diag.reservedBytes, 50);
      expect(diag.availableQuota, 800);
      expect(diag.freeBytes, 550);
      expect(diag.chunkCount, 12);
      expect(diag.degradedChunks, 2);
      expect(diag.generatedAt, isA<DateTime>());
      expect(diag.infoFor('c-suspect')!.endpoint, 'http://192.168.1.22:5321');
      expect(diag.infoFor('c-suspect')!.lastError, 'connection refused');
      expect(diag.infoFor('c-suspect')!.status, PoolContributorStatus.offline);
      expect(diag.infoFor('nope'), isNull);
      expect(diag.needsAttention, isTrue);
    });

    test('device routes still carry the paired-device bearer token', () async {
      final adapter = FakePoolAdapter()
        ..onCall = (options, body) => jsonResponse(200, statusPayload());
      final api = buildApi(adapter);
      primeAccessToken(api, 'user-access-token');
      final pool = PoolService(api);

      await pool.fetchStatus();

      expect(adapter.onlyCall.header('Authorization'),
          'Bearer user-access-token');
    });
  });

  // ---------------------------------------------------------------------------
  // PoolService — heartbeat (different auth: X-Pool-Token, no bearer)
  // ---------------------------------------------------------------------------

  group('PoolService.heartbeat', () {
    test('sends X-Pool-Token and never an Authorization bearer', () async {
      final adapter = FakePoolAdapter()
        ..onCall = (options, body) => jsonResponse(200, {
              'ok': true,
              'accepted': true,
              'epoch': 4,
              'server_time': '2026-09-27T10:01:00.000',
              'heartbeat_sec': 60,
            });
      final api = buildApi(adapter);
      // The app is logged in, so the AuthInterceptor *would* attach a bearer
      // to every request on this Dio — including the heartbeat.
      primeAccessToken(api, 'user-access-token');
      final pool = PoolService(api);

      await pool.heartbeat(
        contributorId: 'c-live',
        token: 'pool-capability-token',
        reportSeq: 3,
        usedBytes: 4096,
        freeBytes: 1024,
      );

      final call = adapter.onlyCall;
      expect(call.method, 'POST');
      expect(call.path, endsWith('/pool/heartbeat'));
      expect(call.header('X-Pool-Token'), 'pool-capability-token');
      expect(call.bodyJson, {
        'report_seq': 3,
        'used_bytes': 4096,
        'free_bytes': 1024,
      });
      // The whole point of the route's separate auth: no user bearer, and no
      // session-refresh retry cycle either.
      final auth = call.header('Authorization');
      expect(auth, anyOf(isNull, isEmpty),
          reason: 'heartbeat must not carry a bearer token, got "$auth"');
      expect(call.header('X-LocalVault-Retried'), '1');
    });
  });

  // ---------------------------------------------------------------------------
  // PoolService — chunks
  // ---------------------------------------------------------------------------

  group('PoolService chunks', () {
    test('rejects an invalid chunk id before any request is made', () async {
      final adapter = FakePoolAdapter();
      final pool = PoolService(buildApi(adapter));

      await expectLater(
        pool.putChunk(
          chunkId: '../../etc/passwd',
          ciphertext: const [1, 2, 3],
          contentSha256: validContentSha,
          idempotencyKey: 'key-1',
        ),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        pool.putChunk(
          chunkId: validChunkId.toUpperCase(),
          ciphertext: const [1, 2, 3],
          contentSha256: validContentSha,
          idempotencyKey: 'key-1',
        ),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        pool.getChunk('short'),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        pool.chunkLocations('short'),
        throwsA(isA<ValidationException>()),
      );

      expect(adapter.calls, isEmpty,
          reason: 'an invalid id must never reach the wire');
    });

    test('sends ciphertext raw with the idempotency + sha256 headers',
        () async {
      final adapter = FakePoolAdapter()
        ..onCall = (options, body) => jsonResponse(200, {
              'ok': true,
              'chunk_id': validChunkId,
              'replicas': ['c-live'],
              'replica_count': 1,
              'degraded': true,
              'bytes': 3,
              'epoch': 7,
            });
      final pool = PoolService(buildApi(adapter));

      final result = await pool.putChunk(
        chunkId: validChunkId,
        ciphertext: const [9, 8, 7],
        contentSha256: validContentSha,
        idempotencyKey: 'upload-42',
      );

      expect(result.degraded, isTrue);
      expect(result.replicaCount, 1);
      final call = adapter.onlyCall;
      expect(call.method, 'PUT');
      expect(call.path, endsWith('/pool/chunks/$validChunkId'));
      expect(call.header('X-Idempotency-Key'), 'upload-42');
      expect(call.header('X-Content-Sha256'), validContentSha);
      expect(call.header('content-type'), contains('application/octet-stream'));
      expect(call.body, const [9, 8, 7]);
    });

    test('maps a 409 NO_SPACE into a typed, helpful exception', () async {
      final adapter = FakePoolAdapter()
        ..onCall = (options, body) => jsonResponse(409, {
              'ok': false,
              'error': {
                'code': 'NO_SPACE',
                'message':
                    'Pool full — no contributor has room for 1024 bytes. '
                        'Free space, raise a quota, or add a device.',
              },
            });
      final pool = PoolService(buildApi(adapter));

      Object? thrown;
      try {
        await pool.putChunk(
          chunkId: validChunkId,
          ciphertext: const [1],
          contentSha256: validContentSha,
          idempotencyKey: 'key-2',
        );
      } catch (e) {
        thrown = e;
      }

      expect(thrown, isA<AppException>());
      expect(thrown, anyOf(isA<ConflictException>(), isA<ApiException>()));
      final error = thrown;
      expect((error as AppException).message, contains('Pool full'));
      if (error is ApiException) {
        expect(error.statusCode, 409);
      }
      expect(error.toString(), contains('quota'));
    });
  });

  // ---------------------------------------------------------------------------
  // ContributorAgent — monotonic report_seq restored from storage
  // ---------------------------------------------------------------------------

  group('ContributorAgent heartbeat', () {
    late Directory nodeDir;
    late FakePoolAdapter adapter;
    late PoolService pool;

    setUp(() async {
      nodeDir = await Directory.systemTemp.createTemp('localvault_agent_');
      adapter = FakePoolAdapter()
        ..onCall = (options, body) => jsonResponse(200, {
              'ok': true,
              'accepted': true,
              'contributor_id': 'c-live',
              'epoch': 4,
              'server_time': '2026-09-27T10:01:00.000',
              'heartbeat_sec': 60,
            });
      pool = PoolService(buildApi(adapter));
    });

    tearDown(() async {
      if (await nodeDir.exists()) await nodeDir.delete(recursive: true);
    });

    test('report_seq increments across ticks and is restored from storage',
        () async {
      final storage = InMemoryPoolAgentStorage()
        ..record = const PoolAgentRecord(
          contributorId: 'c-live',
          token: 'pool-capability-token',
          quotaBytes: 8192,
          reportSeq: 7,
        );
      final agent = ContributorAgent(
        pool: pool,
        nodeDir: nodeDir,
        storage: storage,
      );

      await agent.heartbeatTick();
      expect(adapter.calls, hasLength(1));
      expect(adapter.calls.single.bodyJson!['report_seq'], 8);
      expect(adapter.calls.single.header('X-Pool-Token'),
          'pool-capability-token');
      expect(storage.record!.reportSeq, 8,
          reason: 'the sequence is persisted before the send (CONSULT §4)');

      await agent.heartbeatTick();
      expect(adapter.calls.last.bodyJson!['report_seq'], 9);
      expect(storage.record!.reportSeq, 9);
      expect(agent.contributorId, 'c-live');

      // A restart must resume the same sequence instead of rewinding it —
      // otherwise the host would drop our reports as stale.
      final restarted = ContributorAgent(
        pool: pool,
        nodeDir: nodeDir,
        storage: storage,
      );
      await restarted.heartbeatTick();
      expect(adapter.calls.last.bodyJson!['report_seq'], 10);
      expect(storage.record!.reportSeq, 10);

      expect(agent.isContributing, isFalse,
          reason: 'no storage node was started, only a heartbeat');

      await agent.dispose();
      await restarted.dispose();
    });

    test('does nothing without a persisted membership', () async {
      final agent = ContributorAgent(
        pool: pool,
        nodeDir: nodeDir,
        storage: InMemoryPoolAgentStorage(),
      );

      await agent.heartbeatTick();

      expect(adapter.calls, isEmpty);
      expect(agent.contributorId, isNull);
      expect(agent.state, PoolAgentState.idle);

      await agent.dispose();
    });

    test('dispose() stops the agent for good', () async {
      final storage = InMemoryPoolAgentStorage()
        ..record = const PoolAgentRecord(
          contributorId: 'c-live',
          token: 'pool-capability-token',
          quotaBytes: 8192,
          reportSeq: 1,
        );
      final agent = ContributorAgent(
        pool: pool,
        nodeDir: nodeDir,
        storage: storage,
      );
      await agent.heartbeatTick();
      expect(adapter.calls, hasLength(1));

      await agent.dispose();
      await agent.heartbeatTick();

      expect(adapter.calls, hasLength(1),
          reason: 'a disposed agent must never send again');
      expect(agent.state, PoolAgentState.idle);
      await expectLater(agent.stateChanges.isEmpty, completion(isTrue));
    });
  });
}
