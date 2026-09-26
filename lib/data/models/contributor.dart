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
  });

  final String id;
  final String deviceId;
  final String name;
  final ContributorStatus status;

  /// Quota cap this contributor allows the pool to place on it.
  final int quotaBytes;

  /// Bytes the host has accounted as stored (commit- or heartbeat-reported).
  final int usedBytes;

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

  /// True while the contributor counts toward pool totals (§4).
  bool get countsTowardPool =>
      status == ContributorStatus.alive || status == ContributorStatus.suspect;

  /// Maps a raw `contributors` row to a [Contributor].
  factory Contributor.fromRow(Row row) => Contributor(
        id: row['id'] as String,
        deviceId: row['device_id'] as String,
        name: row['name'] as String,
        status: ContributorStatus.fromDb(row['status'] as String),
        quotaBytes: row['quota_bytes'] as int,
        usedBytes: row['used_bytes'] as int,
        freeBytes: row['free_bytes'] as int,
        lastReportSeq: row['last_report_seq'] as int,
        lastHeartbeatAt: _dt(row['last_heartbeat_at'])!,
        createdAt: _dt(row['created_at'])!,
        tokenHash: row['token_hash'] as String?,
        scope: row['scope'] as String?,
        tokenExpiresAt: _dt(row['token_expires_at']),
        revokedAt: _dt(row['revoked_at']),
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
