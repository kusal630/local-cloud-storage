import '../../core/errors/app_exceptions.dart';
import '../database/vault_database.dart';
import '../models/contributor.dart';
import 'contributor_secret_repository.dart';
import 'nonce_repository.dart';
import 'replica_repository.dart';
import 'reservation_repository.dart';

/// Host-side registry, liveness tracker and pool accountant for the v2.4.0
/// pooled data cloud (RESEARCH/CONSULT.md §1-§4).
///
/// The host is the sole liveness authority and never stores a pool total:
/// [poolTotals] derives every figure with one query inside one transaction,
/// so the donut and the number can never disagree.
class ContributorRepository {
  ContributorRepository(this._db)
      : _reservations = ReservationRepository(_db),
        _replicas = ReplicaRepository(_db),
        _nonces = NonceRepository(_db),
        _secrets = ContributorSecretRepository(_db);

  final VaultDatabase _db;
  final ReservationRepository _reservations;
  final ReplicaRepository _replicas;
  final NonceRepository _nonces;
  final ContributorSecretRepository _secrets;

  /// Heartbeat reports older than this are dropped whole (§4).
  static const Duration maxReportAge = Duration(seconds: 300);

  /// Registers (upserts) a contributor over the pinned-TLS channel, issuing
  /// or replacing its capability-token metadata. Counters (`used_bytes`,
  /// `last_report_seq`) survive re-registration and the row wakes to `ALIVE`.
  Contributor register({
    required String id,
    required String deviceId,
    required String name,
    required int quotaBytes,
    String? tokenHash,
    String? scope,
    int? tokenExpiresAt,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      '''
      INSERT INTO contributors
        (id, device_id, name, status, quota_bytes, used_bytes, free_bytes,
         token_hash, scope, token_expires_at, last_report_seq,
         last_heartbeat_at, created_at)
      VALUES (?, ?, ?, 'ALIVE', ?, 0, 0, ?, ?, ?, 0, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        device_id = excluded.device_id,
        name = excluded.name,
        quota_bytes = excluded.quota_bytes,
        token_hash = excluded.token_hash,
        scope = excluded.scope,
        token_expires_at = excluded.token_expires_at,
        last_heartbeat_at = excluded.last_heartbeat_at,
        status = 'ALIVE',
        revoked_at = NULL
      ''',
      [id, deviceId, name, quotaBytes, tokenHash, scope, tokenExpiresAt, now, now],
    );
    return getById(id);
  }

  /// Returns one contributor or throws [NotFoundException].
  Contributor getById(String id) {
    final rows = _db.raw.select('SELECT * FROM contributors WHERE id = ?', [id]);
    if (rows.isEmpty) throw const NotFoundException('Contributor not found.');
    return Contributor.fromRow(rows.first);
  }

  /// Lists contributors, optionally filtered by status, oldest first.
  List<Contributor> list({ContributorStatus? status}) {
    final rows = status == null
        ? _db.raw.select('SELECT * FROM contributors ORDER BY created_at ASC')
        : _db.raw.select(
            'SELECT * FROM contributors WHERE status = ? ORDER BY created_at ASC',
            [status.dbValue],
          );
    return rows.map(Contributor.fromRow).toList();
  }

  /// Applies a heartbeat usage report: accepted only when [reportSeq] is
  /// strictly greater than the last applied one and the report is at most
  /// [maxReportAge] old. Stale/out-of-order reports are dropped whole, which
  /// is what stops `used_bytes` double-counting (§4). A fresh report also
  /// wakes `SUSPECT`/`DEAD` back to `ALIVE`; `REVOKED` never comes back.
  bool heartbeat({
    required String contributorId,
    required int reportSeq,
    required int usedBytes,
    required int freeBytes,
    DateTime? at,
  }) {
    final reportedAt = at ?? DateTime.now();
    if (DateTime.now().difference(reportedAt) > maxReportAge) return false;
    _db.raw.execute(
      '''
      UPDATE contributors SET
        used_bytes = ?, free_bytes = ?, last_report_seq = ?,
        last_heartbeat_at = ?,
        status = CASE WHEN status IN ('SUSPECT','DEAD') THEN 'ALIVE'
                      ELSE status END
      WHERE id = ? AND status <> 'REVOKED' AND ? > last_report_seq
      ''',
      [usedBytes, freeBytes, reportSeq, reportedAt.millisecondsSinceEpoch,
       contributorId, reportSeq],
    );
    return _db.raw.updatedRows == 1;
  }

  /// `ALIVE → SUSPECT` (missed heartbeats). False when not applicable.
  bool markSuspect(String id) =>
      _setStatus(id, 'SUSPECT', "AND status = 'ALIVE'");

  /// `ALIVE|SUSPECT → DEAD` (missed ≥ 600 s). False when not applicable.
  bool markDead(String id) =>
      _setStatus(id, 'DEAD', "AND status IN ('ALIVE','SUSPECT')");

  /// Voluntary leave: the contributor stops counting toward the pool at once.
  bool markLeft(String id) =>
      _setStatus(id, 'LEFT', "AND status NOT IN ('LEFT','REVOKED')");

  /// Revokes the contributor and rolls back its in-flight reservations in ONE
  /// transaction; queued chunk re-replication is the caller's job (§1).
  bool revoke(String id) {
    return _db.withTransaction(() {
      if (!_setStatus(id, 'REVOKED', "AND status <> 'REVOKED'")) return false;
      _db.raw.execute(
        "UPDATE reservations SET state = 'ROLLED_BACK' "
        "WHERE contributor_id = ? AND state = 'RESERVED'",
        [id],
      );
      return true;
    });
  }

  bool _setStatus(String id, String status, String guard) {
    _db.raw.execute(
      'UPDATE contributors SET status = ?, revoked_at = ? WHERE id = ? $guard',
      [status,
       status == 'REVOKED' ? DateTime.now().millisecondsSinceEpoch : null,
       id],
    );
    return _db.raw.updatedRows == 1;
  }

  /// Sets a contributor's quota cap (a membership change: bump the placement
  /// epoch on the caller's side).
  bool setQuota(String id, int quotaBytes) {
    _db.raw.execute('UPDATE contributors SET quota_bytes = ? WHERE id = ?',
        [quotaBytes, id]);
    return _db.raw.updatedRows == 1;
  }

  /// Derives pool capacity in ONE query inside ONE transaction: total, used
  /// and still-reserved bytes over `ALIVE`+`SUSPECT` rows only (§4 — `DEAD`,
  /// `REVOKED` and `LEFT` never count, so leave needs no subtract step).
  PoolTotals poolTotals() {
    return _db.withTransaction(() {
      final rows = _db.raw.select('''
        SELECT
          (SELECT COALESCE(SUM(quota_bytes),0) FROM contributors
            WHERE status IN ('ALIVE','SUSPECT')) AS total_quota,
          (SELECT COALESCE(SUM(used_bytes),0) FROM contributors
            WHERE status IN ('ALIVE','SUSPECT')) AS used_bytes,
          (SELECT COALESCE(SUM(r.bytes),0) FROM reservations r
             JOIN contributors c ON c.id = r.contributor_id
            WHERE r.state = 'RESERVED' AND r.expires_at > ?
              AND c.status IN ('ALIVE','SUSPECT')) AS reserved_bytes
      ''', [DateTime.now().millisecondsSinceEpoch]);
      final row = rows.first;
      return PoolTotals(
        totalQuota: row['total_quota'] as int,
        usedBytes: row['used_bytes'] as int,
        reservedBytes: row['reserved_bytes'] as int,
      );
    });
  }

  /// Wrapped pairing secrets (§5) — ciphertext only at rest.
  ContributorSecretRepository get secrets => _secrets;

  // --- Reservations / replicas / nonces: everything via `contributors`. ---

  /// Reserves [bytes] against a contributor's quota; null means no room.
  Reservation? reserveChunk(String idempotencyKey, String chunkId,
          String contributorId, int bytes,
          {Duration ttl = ReservationRepository.defaultTtl}) =>
      _reservations.reserveChunk(idempotencyKey, chunkId, contributorId, bytes,
          ttl: ttl);

  /// Commits a reservation and records its `STORED` replica (false if none).
  bool commitReservation(
          String idempotencyKey, String contributorId, String sha256) =>
      _reservations.commitReservation(idempotencyKey, contributorId, sha256);

  /// Releases an open reservation (false if it was not open).
  bool rollbackReservation(String idempotencyKey, String contributorId) =>
      _reservations.rollbackReservation(idempotencyKey, contributorId);

  /// Deletes TTL-lapsed reservations; returns rows freed (run every 30 s).
  int sweepExpiredReservations() => _reservations.sweepExpiredReservations();

  /// Records/updates one chunk copy (idempotent on its primary key).
  void upsertReplica(String chunkId, String contributorId, ReplicaState state,
          String sha256, int bytes) =>
      _replicas.upsert(chunkId, contributorId, state, sha256, bytes);

  /// Returns every chunk copy (read path for replica locations).
  List<ChunkReplica> listReplicas(String chunkId) =>
      _replicas.listForChunk(chunkId);

  /// Returns the chunk copies believed stored on [contributorId].
  List<ChunkReplica> listReplicasByContributor(String contributorId) =>
      _replicas.listForContributor(contributorId);

  /// Chunks with fewer than [targetReplicas] `STORED` copies (repair queue).
  List<String> underReplicatedChunks({int targetReplicas = 2}) =>
      _replicas.underReplicated(targetReplicas: targetReplicas);

  /// Records a replay-protection nonce; false means it was already seen.
  bool insertNonce(String nonce, {DateTime? at}) =>
      _nonces.insert(nonce, at: at);

  /// Sweeps expired/overflowing nonces; returns rows removed.
  int sweepNonces() => _nonces.sweep();
}
