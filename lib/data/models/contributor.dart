import 'package:sqlite3/sqlite3.dart';

/// Liveness / authorization state of a pooled-storage contributor.
///
/// The host is the sole liveness authority. Legal forward transitions are
/// `ALIVE → SUSPECT → DEAD → REVOKED`; `SUSPECT`/`DEAD → ALIVE` happens on a
/// fresh heartbeat, `LEFT` is a voluntary leave.
enum ContributorStatus {
  alive('ALIVE'),
  suspect('SUSPECT'),
  dead('DEAD'),
  revoked('REVOKED'),
  left('LEFT');

  const ContributorStatus(this.dbValue);

  /// Value stored in `contributors.status`.
  final String dbValue;

  /// Parses a stored status; unknown values map to [fallback].
  static ContributorStatus fromDb(
    String value, {
    ContributorStatus fallback = ContributorStatus.dead,
  }) =>
      ContributorStatus.values.firstWhere((s) => s.dbValue == value,
          orElse: () => fallback);
}

/// A device donating quota-capped free disk to the shared pool.
class Contributor {
  const Contributor({
    required this.id,
    required this.deviceId,
    required this.name,
    required this.status,
    required this.quotaBytes,
    required this.usedBytes,
    required this.freeBytes,
    required this.lastReportSeq,
    required this.lastHeartbeatAt,
    required this.createdAt,
    this.tokenHash,
    this.scope,
    this.tokenExpiresAt,
    this.revokedAt,
    this.endpoint,
    this.fingerprint,
    this.deviceKind = 'phone',
    this.lastError,
    this.reportedUsedBytes = 0,
  });

  final String id;
  final String deviceId;
  final String name;
  final ContributorStatus status;

  /// Quota cap this contributor allows the pool to place on it.
  final int quotaBytes;

  /// Bytes the host's ledger has accounted as stored.
  ///
  /// Owned by the host: only a chunk commit (or the matching rollback/GC)
  /// changes it, so pool totals can never be talked up by a heartbeat.
  final int usedBytes;

  /// What the contributor *claims* is on its own disk, from its heartbeat.
  /// Diagnostic only — a sustained gap between this and [usedBytes] means a
  /// node is storing bytes the pool does not know about (or vice versa) and
  /// is surfaced as such instead of being averaged into the headline.
  final int reportedUsedBytes;

  /// Last heartbeat-reported free space (weighting only, never admission).
  final int freeBytes;
  final int lastReportSeq;
  final DateTime lastHeartbeatAt;
  final DateTime createdAt;

  /// SHA-256 of the contributor's capability token — never the token itself.
  final String? tokenHash;
  final String? scope;
  final DateTime? tokenExpiresAt;
  final DateTime? revokedAt;

  /// Base URL of this contributor's storage node (`https://192.168.1.5:5321`).
  final String? endpoint;

  /// Pinned SHA-256 fingerprint of the node's TLS certificate.
  final String? fingerprint;

  /// Coarse device class for the UI glyph: `phone` / `laptop` / `tablet` /
  /// `server`.
  final String deviceKind;

  /// Last transport/verification error seen for this contributor — surfaced
  /// as the row's honest "why" instead of a silent stale total.
  final String? lastError;

  /// True while the contributor counts toward pool totals (§4).
  bool get countsTowardPool =>
      status == ContributorStatus.alive || status == ContributorStatus.suspect;

  /// True when the coordinator has everything it needs to talk to the node.
  bool get isReachable =>
      (endpoint ?? '').isNotEmpty && status != ContributorStatus.revoked;

  /// Maps a raw `contributors` row to a [Contributor].
  factory Contributor.fromRow(Row row) => Contributor(
        id: row['id'] as String,
        deviceId: row['device_id'] as String,
        name: row['name'] as String,
        status: ContributorStatus.fromDb(row['status'] as String),
        quotaBytes: row['quota_bytes'] as int,
        usedBytes: row['used_bytes'] as int,
        reportedUsedBytes: row['reported_used_bytes'] as int? ?? 0,
        freeBytes: row['free_bytes'] as int,
        lastReportSeq: row['last_report_seq'] as int,
        lastHeartbeatAt: _dt(row['last_heartbeat_at'])!,
        createdAt: _dt(row['created_at'])!,
        tokenHash: row['token_hash'] as String?,
        scope: row['scope'] as String?,
        tokenExpiresAt: _dt(row['token_expires_at']),
        revokedAt: _dt(row['revoked_at']),
        endpoint: row['endpoint'] as String?,
        fingerprint: row['fingerprint'] as String?,
        deviceKind: (row['device_kind'] as String?) ?? 'phone',
        lastError: row['last_error'] as String?,
      );

  static DateTime? _dt(Object? epochMs) => epochMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(epochMs as int);
}

/// Lifecycle of a chunk reservation (§2 of RESEARCH/CONSULT.md).
enum ReservationState {
  reserved('RESERVED'),
  committed('COMMITTED'),
  rolledBack('ROLLED_BACK');

  const ReservationState(this.dbValue);

  /// Value stored in `reservations.state`.
  final String dbValue;

  /// Parses a stored state; unknown values map to [fallback].
  static ReservationState fromDb(
    String value, {
    ReservationState fallback = ReservationState.rolledBack,
  }) =>
      ReservationState.values.firstWhere((s) => s.dbValue == value,
          orElse: () => fallback);
}

/// A quota hold placed on one contributor before a chunk write starts.
class Reservation {
  const Reservation({
    required this.idempotencyKey,
    required this.chunkId,
    required this.contributorId,
    required this.bytes,
    required this.state,
    required this.createdAt,
    required this.expiresAt,
  });

  final String idempotencyKey;
  final String chunkId;
  final String contributorId;
  final int bytes;
  final ReservationState state;
  final DateTime createdAt;
  final DateTime expiresAt;
}

/// Recorded placement of one chunk copy on one contributor (§3).
///
/// `CORRUPT` is the read-verification quarantine state (§6 control 1).
enum ReplicaState {
  storing('STORING'),
  stored('STORED'),
  degraded('DEGRADED'),
  deleted('DELETED'),
  corrupt('CORRUPT');

  const ReplicaState(this.dbValue);

  /// Value stored in `chunk_replicas.state`.
  final String dbValue;

  /// Parses a stored state; unknown values map to [fallback].
  static ReplicaState fromDb(
    String value, {
    ReplicaState fallback = ReplicaState.degraded,
  }) =>
      ReplicaState.values.firstWhere((s) => s.dbValue == value,
          orElse: () => fallback);
}

/// One row of the authoritative replica set for a chunk.
class ChunkReplica {
  const ChunkReplica({
    required this.chunkId,
    required this.contributorId,
    required this.state,
    required this.sha256,
    required this.bytes,
    this.updatedAt,
  });

  final String chunkId;
  final String contributorId;
  final ReplicaState state;

  /// Host-recorded SHA-256 — never trusted from the contributor.
  final String sha256;
  final int bytes;
  final DateTime? updatedAt;
}

/// One row of the host-side chunk manifest (`pool_chunks`).
///
/// Two different hashes, deliberately (CONSULT §5, §6 control 1):
/// * [contentSha256] — SHA-256 of the **plaintext**: the content id and the
///   value re-checked after decryption. Never supplied by a contributor.
/// * [cipherSha256] — SHA-256 of the **stored blob**, computed by the host
///   from bytes it encrypted itself and recorded here at commit time, so a
///   read can detect bit-rot or tampering before trusting the ciphertext.
class PoolChunk {
  const PoolChunk({
    required this.chunkId,
    required this.seq,
    required this.bytes,
    required this.contentSha256,
    required this.cipherSha256,
    required this.replication,
    required this.createdAt,
    this.fileId,
  });

  final String chunkId;
  final String? fileId;
  final int seq;
  final int bytes;
  final String contentSha256;
  final String cipherSha256;
  final int replication;
  final DateTime createdAt;

  factory PoolChunk.fromRow(Row row) => PoolChunk(
        chunkId: row['chunk_id'] as String,
        fileId: row['file_id'] as String?,
        seq: row['seq'] as int,
        bytes: row['bytes'] as int,
        contentSha256: row['content_sha256'] as String,
        cipherSha256: row['cipher_sha256'] as String,
        replication: row['replication'] as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      );
}

/// What a protected file is supposed to consist of.
///
/// `pool_chunks` records what *landed*; this records what was *asked for*.
/// Comparing the two is how a reader knows a file is whole instead of
/// assuming that every row it can see is every row there is.
class PoolFileMeta {
  const PoolFileMeta({
    required this.fileId,
    required this.chunkCount,
    required this.byteLength,
    required this.createdAt,
    required this.updatedAt,
  });

  final String fileId;
  final int chunkCount;
  final int byteLength;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory PoolFileMeta.fromRow(Row row) => PoolFileMeta(
        fileId: row['file_id'] as String,
        chunkCount: row['chunk_count'] as int,
        byteLength: row['byte_length'] as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      );
}

/// Derived pool capacity snapshot (§4 — never stored, always summed).
///
/// `used + reserved` can exceed `totalQuota` only through a bug: reservations
/// are admitted against the same quota the numbers below are summed from.
class PoolTotals {
  const PoolTotals({
    required this.totalQuota,
    required this.usedBytes,
    required this.reservedBytes,
  });

  /// Sum of `quota_bytes` over `ALIVE` + `SUSPECT` contributors.
  final int totalQuota;

  /// Sum of `used_bytes` over the same rows.
  final int usedBytes;

  /// Sum of unexpired `RESERVED` bytes over the same rows.
  final int reservedBytes;

  /// Bytes still claimable by new reservations.
  int get freeBytes =>
      totalQuota - usedBytes - reservedBytes < 0
          ? 0
          : totalQuota - usedBytes - reservedBytes;
}
