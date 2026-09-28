import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../core/errors/app_exceptions.dart';
import '../../data/datasources/vault.dart';
import '../../data/models/device.dart';
import '../middleware/api_responses.dart';
import '../pool/pool_coordinator.dart';

/// REST surface of the pooled data cloud (v2.4.0).
///
/// Two authentications, deliberately separate (CONSULT §1):
/// * **device routes** — registered on the protected router, authenticated by
///   the normal bearer token of a *paired device*. Joining the pool, changing
///   quotas, writing and reading chunks all require a paired device.
/// * **heartbeat** — registered on the public router but authenticates itself
///   with the contributor capability token in `X-Pool-Token`, so a
///   background contributor agent can report without holding a user session.
class PoolApiHandlers {
  PoolApiHandlers({required this.vault, required this.coordinator});

  final Vault vault;
  final PoolCoordinator coordinator;

  /// Hard ceiling on a single chunk body (5 MB chunk + encryption overhead).
  static const int maxChunkBytes = 16 * 1024 * 1024;

  // ---------------------------------------------------------------------------
  // Contributor-token route (public pipeline, self-authenticating)
  // ---------------------------------------------------------------------------

  /// `POST /api/v1/pool/heartbeat`
  ///
  /// Monotonic `report_seq` + a 300 s freshness window make this idempotent
  /// and replay-safe: an out-of-order report is dropped whole (CONSULT §4),
  /// which is what stops `used_bytes` double-counting.
  Future<Response> heartbeat(Request request) async {
    final token = request.headers['x-pool-token'];
    final contributor = coordinator.authenticateContributor(token);
    final body = await _jsonBody(request);
    final reportSeq = _int(body, 'report_seq') ?? 0;
    if (reportSeq <= 0) {
      throw const ValidationException('report_seq must be greater than zero.');
    }
    final applied = await coordinator.heartbeat(
      contributorId: contributor.id,
      reportSeq: reportSeq,
      usedBytes: _int(body, 'used_bytes') ?? contributor.usedBytes,
      freeBytes: _int(body, 'free_bytes') ?? contributor.freeBytes,
    );
    return ApiResponses.ok({
      'accepted': applied,
      'contributor_id': contributor.id,
      'epoch': coordinator.currentEpoch,
      'server_time': DateTime.now().toIso8601String(),
      'heartbeat_sec': PoolCoordinator.heartbeatInterval.inSeconds,
    });
  }

  // ---------------------------------------------------------------------------
  // Device routes (protected router)
  // ---------------------------------------------------------------------------

  /// Registers every `/api/v1/pool/...` device route on [router].
  void register(Router router) {
    router
      ..post('/api/v1/pool/register', register_)
      ..get('/api/v1/pool/status', status)
      ..get('/api/v1/pool/contributors', listContributors)
      ..patch('/api/v1/pool/contributors/<id>', updateContributor)
      ..post('/api/v1/pool/contributors/<id>/revoke', revokeContributor)
      ..post('/api/v1/pool/leave', leave)
      ..put('/api/v1/pool/chunks/<chunkId>', writeChunk)
      ..get('/api/v1/pool/chunks/<chunkId>', readChunk)
      ..get('/api/v1/pool/chunks/<chunkId>/locations', chunkLocations)
      ..post('/api/v1/pool/maintenance', maintenance);
  }

  /// `POST /api/v1/pool/register` — the §1 handshake. Only a *paired device*
  /// may join: pairing is the pool's trust root, so a stranger on the LAN
  /// can never donate space into (or snoop on) your cloud.
  Future<Response> register_(Request request) async {
    final device = _device(request);
    final body = await _jsonBody(request);
    final endpoint = body['endpoint']?.toString() ?? '';
    final registration = await coordinator.register(
      deviceId: device.id,
      name: (body['name']?.toString().trim().isEmpty ?? true)
          ? device.name
          : body['name'].toString().trim(),
      quotaBytes: _int(body, 'quota_bytes') ?? 0,
      endpoint: endpoint,
      fingerprint: body['fingerprint']?.toString(),
      deviceKind: body['device_kind']?.toString() ?? _guessKind(device.name),
      nonce: body['nonce']?.toString(),
    );
    return ApiResponses.created(registration.toJson());
  }

  /// `GET /api/v1/pool/status` — one derived snapshot (never an accumulated
  /// total), including the health headline and the effective pool size.
  Future<Response> status(Request request) async {
    final device = _device(request);
    // Looking at the pool is what drives liveness/repair/audit — cheap when
    // nothing is wrong, and it means a pool never silently rots while the
    // screen is open.
    unawaited(coordinator.maybeMaintenance());
    final snapshot = coordinator.snapshot(thisDeviceId: device.id);
    return ApiResponses.ok(snapshot.toJson(thisDeviceId: device.id));
  }

  Future<Response> listContributors(Request request) async {
    final device = _device(request);
    final snapshot = coordinator.snapshot(thisDeviceId: device.id);
    return ApiResponses.ok({
      'contributors': [
        for (final c in snapshot.contributors)
          PoolSnapshot.contributorJson(c, device.id),
      ],
      'epoch': snapshot.epoch,
    });
  }

  /// `PATCH /api/v1/pool/contributors/<id>` — body carries any of
  /// `{quota_bytes, endpoint, fingerprint}`; at least one is required.
  ///
  /// `endpoint`/`fingerprint` exist because a contributor's port changes on
  /// restart: without a way to correct it the pool would go DEGRADED for no
  /// reason the user could act on.
  Future<Response> updateContributor(Request request, String id) async {
    final body = await _jsonBody(request);
    final quota = _int(body, 'quota_bytes');
    final endpoint = body['endpoint']?.toString();
    final fingerprint = body['fingerprint']?.toString();
    if (quota == null && endpoint == null && fingerprint == null) {
      throw const ValidationException(
        'Provide at least one of quota_bytes, endpoint or fingerprint.',
      );
    }
    if (quota != null) coordinator.setQuota(id, quota);
    if (endpoint != null || fingerprint != null) {
      coordinator.setEndpoint(
        id,
        endpoint: endpoint ??
            vault.contributors.getById(id).endpoint ??
            (throw const ValidationException(
              'This contributor has no endpoint yet; provide one.',
            )),
        fingerprint: fingerprint,
      );
    }
    final row = vault.contributors.getById(id);
    return ApiResponses.ok({
      'id': id,
      'quota_bytes': row.quotaBytes,
      'endpoint': row.endpoint,
      'fingerprint': row.fingerprint,
    });
  }

  /// `POST /api/v1/pool/contributors/<id>/revoke` — returns immediately with
  /// the re-replication backlog; repair runs in the background so the UI can
  /// show "revoking… (re-replicating N chunks)" instead of blocking (§1).
  Future<Response> revokeContributor(Request request, String id) async {
    final held = vault.contributors.listReplicasByContributor(id);
    final report = await coordinator.revoke(id);
    return ApiResponses.ok({
      'id': id,
      'revoked': true,
      'chunks_to_repair': report.queued > 0 ? report.queued : held.length,
    });
  }

  /// `POST /api/v1/pool/leave` — this device's own contribution stops
  /// counting at once; its chunks re-replicate to the survivors first.
  Future<Response> leave(Request request) async {
    final device = _device(request);
    final mine = vault.contributors
        .list()
        .where((c) => c.deviceId == device.id)
        .toList(growable: false);
    if (mine.isEmpty) {
      throw const NotFoundException('This device is not contributing.');
    }
    final results = <Map<String, Object?>>[];
    for (final contributor in mine) {
      final report = await coordinator.leave(contributor.id);
      results.add({
        'id': contributor.id,
        'chunks_to_repair': report.queued,
      });
    }
    return ApiResponses.ok({'left': results});
  }

  /// `PUT /api/v1/pool/chunks/<chunkId>` — raw ciphertext body.
  ///
  /// Headers: `X-Idempotency-Key` (required, one per logical write) and
  /// `X-Content-Sha256` (SHA-256 of the *plaintext*, recorded by the host —
  /// §6 control 1: hashes are never trusted from a contributor).
  Future<Response> writeChunk(Request request, String chunkId) async {
    final key = request.headers['x-idempotency-key'];
    if (key == null || key.isEmpty) {
      throw const ValidationException('X-Idempotency-Key is required.');
    }
    final length = request.contentLength ?? 0;
    if (length > maxChunkBytes) {
      throw const ValidationException('Chunk exceeds the $maxChunkBytes byte limit.');
    }
    final bytes = await _readBody(request);
    if (bytes.isEmpty) {
      throw const ValidationException('Chunk body is empty.');
    }
    final contentSha = (request.headers['x-content-sha256'] ?? '').trim();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(contentSha)) {
      throw const ValidationException(
          'X-Content-Sha256 must be 64 lowercase hex characters.');
    }
    final result = await coordinator.writeChunk(
      chunkId: chunkId,
      ciphertext: bytes,
      contentSha256: contentSha,
      idempotencyKey: key,
    );
    return ApiResponses.ok({
      'chunk_id': chunkId,
      'replicas': result.replicaIds,
      'replica_count': result.replicaIds.length,
      'degraded': result.isDegradedAgainst(coordinator.replication),
      'bytes': result.bytes,
      'epoch': coordinator.currentEpoch,
    });
  }

  /// `GET /api/v1/pool/chunks/<chunkId>` — verified bytes, or 404.
  Future<Response> readChunk(Request request, String chunkId) async {
    final result = await coordinator.readChunk(chunkId);
    if (result == null) {
      throw const NotFoundException('Chunk not found or unreadable.');
    }
    return Response(200, body: result.bytes, headers: {
      'content-type': 'application/octet-stream',
      'content-length': '${result.bytes.length}',
      'x-chunk-sha256': result.sha256,
      'x-replica-count': '${result.replicaCount}',
      if (result.degraded) 'x-degraded': '1',
      if (result.quarantined.isNotEmpty)
        'x-quarantined': result.quarantined.join(','),
    });
  }

  /// `GET /api/v1/pool/chunks/<chunkId>/locations` — readers ask the host
  /// instead of recomputing placement (CONSULT §3).
  Future<Response> chunkLocations(Request request, String chunkId) async {
    // Validate before it reaches the coordinator: shelf_router percent-decodes
    // the parameter, so a single segment can still carry `../` (§6 control 5).
    PoolCoordinator.validateChunkId(chunkId);
    final locations = coordinator.locations(chunkId);
    return ApiResponses.ok({
      'chunk_id': chunkId,
      'locations': locations,
      'replica_count': locations.length,
      'degraded': locations.length < coordinator.replication,
      'epoch': coordinator.currentEpoch,
    });
  }

  /// `POST /api/v1/pool/maintenance` — one bounded pass of the background
  /// jobs (liveness sweep, TTL sweeps, repair, spot-audit). The server calls
  /// this on a timer; the pool screen offers it as "Check pool health".
  Future<Response> maintenance(Request request) async {
    final changed = await coordinator.sweepLiveness();
    final repair = await coordinator.repairStep();
    final audit = await coordinator.auditStep();
    final snapshot = coordinator.snapshot();
    return ApiResponses.ok({
      'liveness_changed': changed.length,
      'repair': {
        'repaired': repair.repaired,
        'queued': repair.queued,
        'failed': repair.failed,
      },
      'audit': {'quarantined': audit.quarantined},
      'health': snapshot.health.label,
      'epoch': snapshot.epoch,
      'total_quota': snapshot.totalQuota,
      'used_bytes': snapshot.usedBytes,
      'degraded_chunks': snapshot.degradedChunks,
    });
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Device _device(Request request) => request.context['device'] as Device;

  /// Drains the request body into memory with an enforced ceiling, so a
  /// hostile client cannot exhaust the host by streaming forever.
  static Future<List<int>> _readBody(Request request, [int limit = maxChunkBytes]) async {
    var total = 0;
    final parts = <List<int>>[];
    await for (final part in request.read()) {
      total += part.length;
      if (total > limit) {
        throw const ValidationException('Request body is too large.');
      }
      parts.add(part);
    }
    final out = Uint8List(total);
    var offset = 0;
    for (final part in parts) {
      out.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return out;
  }

  Future<Map<String, Object?>> _jsonBody(Request request) async {
    final raw = await request.readAsString();
    if (raw.isEmpty) return const {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const ValidationException('JSON body must be an object.');
    }
    return decoded;
  }

  static int? _int(Map<String, Object?> body, String key) {
    final value = body[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Cheap device-class guess for the leading glyph in the contributor list
  /// (the client may override it with an explicit `device_kind`).
  static String _guessKind(String name) {
    final n = name.toLowerCase();
    if (n.contains('tab')) return 'tablet';
    if (n.contains('laptop') || n.contains('pc') || n.contains('desktop')) {
      return 'laptop';
    }
    if (n.contains('pi') || n.contains('server') || n.contains('nas')) {
      return 'server';
    }
    return 'phone';
  }
}
