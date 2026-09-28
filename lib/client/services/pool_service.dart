// Client slice of the v2.4.0 Pooled Data Cloud coordinator API
// (RESEARCH/CONSULT.md §1 registry + heartbeat, §4 summed totals, §5 chunk
// encryption).
//
// Every call goes through the existing [LocalVaultApi] Dio instance so pool
// traffic reuses the pinned-TLS channel, the typed `AppException` mapping
// (`LocalVaultApi.decodeData` / `.mapError`) and the paired-device bearer the
// protected routes require — with one deliberate exception: `POST
// /pool/heartbeat` authenticates with the contributor capability token in
// `X-Pool-Token` instead (see [PoolService.heartbeat]).
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../core/errors/app_exceptions.dart';
import '../../features/pool/pool_models.dart';
import '../api_client.dart';
import '../auth_interceptor.dart';

/// Headline pool health exactly as the coordinator speaks it
/// (`EMPTY | ONLINE | DEGRADED | AT_RISK | OFFLINE`), carried by
/// [PoolDiagnostics] because the `PoolStatus` UI model has no slot for it.
enum PoolHealthState {
  empty('EMPTY'),
  online('ONLINE'),
  degraded('DEGRADED'),
  atRisk('AT_RISK'),
  offline('OFFLINE');

  const PoolHealthState(this.label);

  /// Uppercase label the host puts on the wire.
  final String label;

  /// Tolerant parsing: unknown labels fall back to [online] so a newer host
  /// never renders as a phantom outage.
  static PoolHealthState fromLabel(String? raw) {
    final wanted = (raw ?? '').trim().toUpperCase();
    for (final health in PoolHealthState.values) {
      if (health.label == wanted) return health;
    }
    return PoolHealthState.online;
  }
}

/// Per-contributor extras the [PoolContributor] UI model does not carry.
class PoolContributorInfo {
  const PoolContributorInfo({
    required this.id,
    required this.rawStatus,
    this.deviceId,
    this.endpoint,
    this.lastError,
    this.freeBytes = 0,
  });

  factory PoolContributorInfo.fromJson(Map<String, dynamic> json) =>
      PoolContributorInfo(
        id: json['id'] as String? ?? '',
        rawStatus: json['status'] as String? ?? 'ALIVE',
        deviceId: json['device_id'] as String?,
        endpoint: json['endpoint'] as String?,
        lastError: json['last_error'] as String?,
        freeBytes: (json['free_bytes'] as num?)?.toInt() ?? 0,
      );

  final String id;

  /// `ALIVE | SUSPECT | DEAD | REVOKED | LEFT` as the host sent it.
  final String rawStatus;

  final String? deviceId;

  /// LAN URL of that contributor's storage node, when it reported one.
  final String? endpoint;

  /// Last placement/transport error recorded against this contributor
  /// ("connection refused", "no space"...), or null when healthy.
  final String? lastError;

  /// Free bytes the last heartbeat claimed (weighting only, CONSULT §3).
  final int freeBytes;

  /// Same lifecycle mapping the contributor list uses (SUSPECT/DEAD/REVOKED
  /// all land in [PoolContributorStatus.offline]).
  PoolContributorStatus get status => poolContributorStatusFromJson(rawStatus);

  bool get hasError => lastError != null && lastError!.isNotEmpty;
}

/// The server fields `PoolStatus` has no slot for, returned alongside it by
/// [PoolService.fetch] so the screen can render epoch/health/reserved bytes
/// without widening the shared UI model.
class PoolDiagnostics {
  const PoolDiagnostics({
    required this.epoch,
    required this.health,
    required this.reservedBytes,
    required this.availableQuota,
    required this.freeBytes,
    required this.chunkCount,
    required this.degradedChunks,
    this.generatedAt,
    this.contributors = const [],
  });

  factory PoolDiagnostics.fromJson(Map<String, dynamic> json) {
    final rawList = json['contributors'];
    return PoolDiagnostics(
      epoch: (json['epoch'] as num?)?.toInt() ?? 0,
      health: PoolHealthState.fromLabel(json['health'] as String?),
      reservedBytes: (json['reserved_bytes'] as num?)?.toInt() ?? 0,
      availableQuota: (json['available_quota'] as num?)?.toInt() ?? 0,
      freeBytes: (json['free_bytes'] as num?)?.toInt() ?? 0,
      chunkCount: (json['chunk_count'] as num?)?.toInt() ?? 0,
      degradedChunks: (json['degraded_chunks'] as num?)?.toInt() ?? 0,
      generatedAt: DateTime.tryParse(json['generated_at']?.toString() ?? ''),
      contributors: [
        if (rawList is List)
          for (final e in rawList)
            if (e is Map<String, dynamic>) PoolContributorInfo.fromJson(e),
      ],
    );
  }

  /// Placement epoch — bumped on membership change only (CONSULT §3).
  final int epoch;

  /// Single-word headline for the top of the pool screen.
  final PoolHealthState health;

  /// Bytes held by open two-phase reservations (CONSULT §2) — shown as
  /// "reserved" so a full-looking pool is explainable.
  final int reservedBytes;

  /// Sum of quota over contributors the host still counts.
  final int availableQuota;

  /// `total_quota - used_bytes - reserved_bytes`, floored at zero.
  final int freeBytes;

  /// Number of stored replica blobs.
  final int chunkCount;

  /// Chunks below the replication factor — never render as healthy (§7).
  final int degradedChunks;

  /// When the host derived this snapshot.
  final DateTime? generatedAt;

  final List<PoolContributorInfo> contributors;

  /// Diagnostics row for one contributor, or null when the id is unknown.
  PoolContributorInfo? infoFor(String contributorId) {
    for (final info in contributors) {
      if (info.id == contributorId) return info;
    }
    return null;
  }

  /// Convenience: something is under-replicated or a contributor is unhappy.
  bool get needsAttention =>
      degradedChunks > 0 || contributors.any((c) => c.hasError);
}

/// `POST /pool/register` response (the §1 handshake).
class PoolJoinResult {
  const PoolJoinResult({
    required this.contributorId,
    required this.token,
    required this.heartbeatSec,
    required this.epoch,
    this.expiresAt,
  });

  final String contributorId;

  /// 256-bit capability token, returned exactly once over pinned TLS.
  /// Persist it in the platform keystore only (CONSULT §1).
  final String token;

  /// Cadence the host expects heartbeats at (seconds).
  final int heartbeatSec;

  final int epoch;

  final DateTime? expiresAt;
}

/// Strips the paired-device bearer from the pool heartbeat.
///
/// `AuthInterceptor` attaches `Authorization: Bearer <access>` to every
/// request on the shared Dio, but `/pool/heartbeat` lives on the *public*
/// pipeline and authenticates with `X-Pool-Token` — a background contributor
/// agent must never send (or trigger a refresh of) the user session. This
/// interceptor is registered once per Dio, after [AuthInterceptor], so it
/// always wins the last word on that header.
class PoolAuthHeaderGuard extends Interceptor {
  const PoolAuthHeaderGuard();

  /// Route segment of the one request that must not carry a bearer token.
  static const String heartbeatPath = '/pool/heartbeat';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.path.contains(heartbeatPath)) {
      options.headers.remove('Authorization');
    }
    handler.next(options);
  }
}

/// Wraps every `/pool/...` coordinator route (v2.4.0 Pooled Data Cloud).
///
/// Mirrors the shape of [FileService]: one method per REST call, every
/// failure funneled through `LocalVaultApi.mapError` so callers only ever see
/// typed [AppException]s.
class PoolService {
  PoolService(this.api) {
    _installHeaderGuard(api.dio);
  }

  /// The existing client API — reused for its pinned-TLS adapter, its Dio
  /// instance and its error mapping.
  final LocalVaultApi api;

  Dio get _dio => api.dio;

  /// Chunk ids are content-addressed SHA-256 hex; validated before they are
  /// ever interpolated into a URL (CONSULT §6 control 5 — path traversal).
  static final RegExp chunkIdPattern = RegExp(r'^[0-9a-f]{64}$');

  static void _validateChunkId(String chunkId) {
    if (!chunkIdPattern.hasMatch(chunkId)) {
      throw const ValidationException(
          'chunk id must be 64 lowercase hex characters.');
    }
  }

  static void _validateContributorId(String contributorId) {
    if (contributorId.trim().isEmpty ||
        contributorId.contains('/') ||
        contributorId.contains('?')) {
      throw const ValidationException('contributor id is not valid.');
    }
  }

  /// Idempotent: adds [PoolAuthHeaderGuard] once per Dio instance.
  static void _installHeaderGuard(Dio dio) {
    final installed =
        dio.interceptors.whereType<PoolAuthHeaderGuard>().isNotEmpty;
    if (installed) return;
    dio.interceptors.add(const PoolAuthHeaderGuard());
  }

  // ---------------------------------------------------------------------------
  // Snapshot (CONSULT §4 — one derived number per response)
  // ---------------------------------------------------------------------------

  /// `GET /pool/status` → the UI snapshot plus the diagnostics [PoolStatus]
  /// has no fields for (epoch, health, reserved/available/free bytes,
  /// degraded-chunk count, per-contributor endpoint/last_error).
  Future<({PoolStatus status, PoolDiagnostics diagnostics})> fetch() async {
    try {
      final response = await _dio.get('/pool/status');
      final data = LocalVaultApi.decodeData(response);
      return (
        status: PoolStatus.fromJson(data),
        diagnostics: PoolDiagnostics.fromJson(data),
      );
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  /// The loader the pool screen wires up as `PoolStatusLoader`.
  Future<PoolStatus> fetchStatus() async => (await fetch()).status;

  // ---------------------------------------------------------------------------
  // Registry (CONSULT §1)
  // ---------------------------------------------------------------------------

  /// `POST /pool/register` — joins the pool and returns the capability token
  /// (plaintext once, over the pinned-TLS channel).
  Future<PoolJoinResult> register({
    required String name,
    required int quotaBytes,
    required String endpoint,
    String? fingerprint,
    required String deviceKind,
    String? nonce,
  }) async {
    if (quotaBytes <= 0) {
      throw const ValidationException('quota_bytes must be greater than zero.');
    }
    try {
      final response = await _dio.post('/pool/register', data: {
        'name': name,
        'quota_bytes': quotaBytes,
        'endpoint': endpoint,
        if (fingerprint != null && fingerprint.isNotEmpty)
          'fingerprint': fingerprint,
        'device_kind': deviceKind,
        if (nonce != null && nonce.isNotEmpty) 'nonce': nonce,
      });
      final data = LocalVaultApi.decodeData(response);
      return PoolJoinResult(
        contributorId: data['contributor_id'] as String,
        token: data['token'] as String,
        heartbeatSec: (data['heartbeat_sec'] as num?)?.toInt() ?? 60,
        epoch: (data['epoch'] as num?)?.toInt() ?? 0,
        expiresAt: DateTime.tryParse(data['expires_at']?.toString() ?? ''),
      );
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  /// Joins the pool, discarding the registration details. The contributor
  /// agent keeps them — use [register] when you need the token.
  Future<void> contribute({
    required String name,
    required int quotaBytes,
    required String endpoint,
    String? fingerprint,
    required String deviceKind,
  }) async {
    await register(
      name: name,
      quotaBytes: quotaBytes,
      endpoint: endpoint,
      fingerprint: fingerprint,
      deviceKind: deviceKind,
    );
  }

  /// `PATCH /pool/contributors/<id>` `{quota_bytes}`.
  Future<void> setQuota(String contributorId, int quotaBytes) async {
    _validateContributorId(contributorId);
    if (quotaBytes <= 0) {
      throw const ValidationException('quota_bytes must be greater than zero.');
    }
    try {
      final response = await _dio.patch(
        '/pool/contributors/$contributorId',
        data: {'quota_bytes': quotaBytes},
      );
      LocalVaultApi.decodeData(response);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  /// `POST /pool/contributors/<id>/revoke` — returns immediately with the
  /// re-replication backlog; repair drains in the background (§1).
  Future<void> revoke(String contributorId) async {
    _validateContributorId(contributorId);
    try {
      final response =
          await _dio.post('/pool/contributors/$contributorId/revoke');
      LocalVaultApi.decodeData(response);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  /// `POST /pool/leave` — this device's contribution stops counting at once
  /// (§4: totals are derived, so there is no subtract step to get wrong).
  Future<void> leave() async {
    try {
      final response = await _dio.post('/pool/leave');
      LocalVaultApi.decodeData(response);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  /// `POST /pool/heartbeat` — **different auth**: the contributor capability
  /// token in `X-Pool-Token`, no user bearer (see [PoolAuthHeaderGuard]).
  ///
  /// The body is the monotonic §4 usage report; the host drops any
  /// `report_seq` it has already seen, which is what stops `used_bytes`
  /// double-counting.
  Future<void> heartbeat({
    required String contributorId,
    required String token,
    required int reportSeq,
    required int usedBytes,
    required int freeBytes,
  }) async {
    _validateContributorId(contributorId);
    try {
      final response = await _dio.post(
        PoolAuthHeaderGuard.heartbeatPath,
        data: {
          'report_seq': reportSeq,
          'used_bytes': usedBytes,
          'free_bytes': freeBytes,
        },
        options: Options(headers: {
          'X-Pool-Token': token,
          // Belt and braces with PoolAuthHeaderGuard: mirror the pattern
          // LocalVaultApi.refreshAccessToken uses to keep the interceptor's
          // bearer off this route, and mark the request as already handled so
          // a 401 here never triggers a user-session refresh — the agent
          // recovers by re-registering instead.
          'Authorization': '',
          AuthInterceptor.retriedHeader: '1',
        }),
      );
      LocalVaultApi.decodeData(response);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Maintenance
  // ---------------------------------------------------------------------------

  /// `POST /pool/maintenance` — one bounded pass of the background jobs
  /// (liveness sweep, TTL sweeps, repair, spot-audit) plus its report.
  Future<Map<String, Object?>> maintenance() async {
    try {
      final response = await _dio.post('/pool/maintenance');
      return LocalVaultApi.decodeData(response);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Chunks (§3 placement / §5 encryption — bodies are ciphertext only)
  // ---------------------------------------------------------------------------

  /// `PUT /pool/chunks/<chunkId>` — raw ciphertext with the idempotency key
  /// of the logical write (§2) and the SHA-256 of the *plaintext*, which the
  /// host records and never trusts from a contributor (§6 control 1).
  Future<({bool degraded, int replicaCount})> putChunk({
    required String chunkId,
    required List<int> ciphertext,
    required String contentSha256,
    required String idempotencyKey,
  }) async {
    _validateChunkId(chunkId);
    if (ciphertext.isEmpty) {
      throw const ValidationException('Chunk body is empty.');
    }
    try {
      final response = await _dio.put(
        '/pool/chunks/$chunkId',
        data: Uint8List.fromList(ciphertext),
        options: Options(headers: {
          'content-type': 'application/octet-stream',
          'X-Idempotency-Key': idempotencyKey,
          'X-Content-Sha256': contentSha256,
        }),
      );
      final data = LocalVaultApi.decodeData(response);
      final replicas = data['replicas'];
      return (
        degraded: data['degraded'] as bool? ?? false,
        replicaCount: (data['replica_count'] as num?)?.toInt() ??
            (replicas is List ? replicas.length : 0),
      );
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  /// `GET /pool/chunks/<chunkId>` — verified ciphertext, or `null` when the
  /// host has no readable copy (404).
  Future<List<int>?> getChunk(String chunkId) async {
    _validateChunkId(chunkId);
    try {
      final response = await _dio.get(
        '/pool/chunks/$chunkId',
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null) return null;
      if (data is List<int>) return data;
      return List<int>.from(data as List);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      throw LocalVaultApi.mapError(e);
    }
  }

  /// `GET /pool/chunks/<chunkId>/locations` — readers ask the host for
  /// placement instead of recomputing it themselves (CONSULT §3).
  Future<List<String>> chunkLocations(String chunkId) async {
    _validateChunkId(chunkId);
    try {
      final response = await _dio.get('/pool/chunks/$chunkId/locations');
      final data = LocalVaultApi.decodeData(response);
      final raw = data['locations'];
      return [if (raw is List) for (final e in raw) e.toString()];
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }
}
