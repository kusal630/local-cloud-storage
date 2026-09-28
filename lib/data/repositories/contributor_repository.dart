import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

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
    String? endpoint,
    String? fingerprint,
    String deviceKind = 'phone',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      '''
      INSERT INTO contributors
        (id, device_id, name, status, quota_bytes, used_bytes, free_bytes,
         token_hash, scope, token_expires_at, last_report_seq,
         last_heartbeat_at, created_at, endpoint, fingerprint, device_kind)
      VALUES (?, ?, ?, 'ALIVE', ?, 0, 0, ?, ?, ?, 0, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        device_id = excluded.device_id,
        name = excluded.name,
        quota_bytes = excluded.quota_bytes,
        token_hash = excluded.token_hash,
        scope = excluded.scope,
        token_expires_at = excluded.token_expires_at,
        last_heartbeat_at = excluded.last_heartbeat_at,
        endpoint = excluded.endpoint,
        fingerprint = excluded.fingerprint,
        device_kind = excluded.device_kind,
        status = 'ALIVE',
        revoked_at = NULL,
        last_error = NULL
      ''',
      [
        id,
        deviceId,
        name,
        quotaBytes,
        tokenHash,
        scope,
        tokenExpiresAt,
        now,
        now,
        endpoint,
        fingerprint,
        deviceKind,
      ],
    );
    return getById(id);
  }

  /// Records the last transport/verification failure for a contributor so the
  /// pool screen can say *why* a row is unhappy instead of going silent.
  void setLastError(String id, String? message) {
    final text = (message == null || message.length > 300) ? null : message;
    _db.raw.execute(
      'UPDATE contributors SET last_error = ? WHERE id = ?',
      [text, id],
    );
  }

  /// Sets the address the coordinator calls this contributor at, plus (optionally)
  /// the TLS fingerprint it must pin to.
  ///
  /// The contributor is allowed to correct its own endpoint: a device's port
  /// can change on every restart, and it knows its own address better than
  /// anything the host could guess. `fingerprint` is validated by the caller
  /// before it reaches here — an unverifiable pin is worse than none.
  bool setEndpoint(String id, String endpoint, {String? fingerprint}) {
    if (fingerprint == null) {
      _db.raw.execute(
        'UPDATE contributors SET endpoint = ? WHERE id = ?',
        [endpoint, id],
      );
    } else {
      _db.raw.execute(
        'UPDATE contributors SET endpoint = ?, fingerprint = ? WHERE id = ?',
        [endpoint, fingerprint, id],
      );
    }
    return _db.raw.updatedRows == 1;
  }

  /// The contributor row for a device, if it has ever joined.
  ///
  /// Re-registration REUSES this id instead of minting a new row (D3): a
  /// fresh uuid per join would double-count that device's quota and leave a
  /// ghost row whose old token still authenticates.
  Contributor? getByDeviceId(String deviceId) {
    final rows = _db.raw.select(
      'SELECT * FROM contributors WHERE device_id = ? '
      'ORDER BY created_at DESC',
      [deviceId],
    );
    return rows.isEmpty ? null : Contributor.fromRow(rows.first);
  }

  /// See [ReservationRepository.adoptOrphanReplica]: the bytes are already on
  /// the node, so the ledger adopts the replica AND its `used_bytes` in one
  /// transaction instead of recording a copy nobody paid for.
  bool adoptOrphanReplica({
    required String chunkId,
    required String contributorId,
    required String sha256,
    required int bytes,
  }) =>
      _reservations.adoptOrphanReplica(
        chunkId: chunkId,
        contributorId: contributorId,
        sha256: sha256,
        bytes: bytes,
      );

  /// Clears `last_error` after a successful round trip.
  void clearLastError(String id) => setLastError(id, null);

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
        reported_used_bytes = ?, free_bytes = ?, last_report_seq = ?,
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

  /// Heartbeat age at which a contributor becomes `SUSPECT` (missed 3
  /// heartbeats at the 60 s cadence — CONSULT §1).
  static const Duration suspectAfter = Duration(seconds: 180);

  /// Heartbeat age at which a contributor becomes `DEAD` (NAT/sleep
  /// tolerance — CONSULT §1).
  static const Duration deadAfter = Duration(seconds: 600);

  /// Applies the §1 liveness thresholds in one pass and returns every
  /// contributor whose status actually changed. The host is the sole
  /// liveness authority: contributors never decide a peer is dead.
  ///
  /// Membership changes are what bump the placement epoch, so the caller
  /// uses this return value (debounced) rather than polling statuses.
  List<Contributor> sweepLiveness({DateTime? now}) {
    final clock = now ?? DateTime.now();
    final suspectCutoff =
        clock.subtract(suspectAfter).millisecondsSinceEpoch;
    final deadCutoff = clock.subtract(deadAfter).millisecondsSinceEpoch;
    final changed = <Contributor>[];

    final deadCandidates = _db.raw.select(
      "SELECT * FROM contributors WHERE status IN ('ALIVE','SUSPECT') "
      'AND last_heartbeat_at < ?',
      [deadCutoff],
    );
    for (final row in deadCandidates) {
      final id = row['id'] as String;
      if (markDead(id)) changed.add(getById(id));
    }

    final suspectCandidates = _db.raw.select(
      "SELECT * FROM contributors WHERE status = 'ALIVE' "
      'AND last_heartbeat_at >= ? AND last_heartbeat_at < ?',
      [deadCutoff, suspectCutoff],
    );
    for (final row in suspectCandidates) {
      final id = row['id'] as String;
      if (markSuspect(id)) changed.add(getById(id));
    }
    return changed;
  }

  /// Contributors that can still receive placements (alive or briefly
  /// suspect, registered with a reachable node endpoint).
  List<Contributor> placementCandidates() => list()
      .where((c) => c.countsTowardPool && c.isReachable)
      .toList(growable: false);

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

  /// Derives pool capacity in ONE query: total, used and still-reserved bytes
  /// over `ALIVE`+`SUSPECT` rows only (§4 — `DEAD`, `REVOKED` and `LEFT` never
  /// count, so leave needs no subtract step).
  ///
  /// Deliberately *not* wrapped in a transaction. A single SQLite statement is
  /// already atomic, so `BEGIN IMMEDIATE` bought no consistency — it only took
  /// the write lock on the most frequently called read in the app, putting
  /// every status poll in line behind chunk commits. What CONSULT §4 actually
  /// needs is one consistent view *across* reads, which the caller asks for
  /// with [VaultDatabase.withReadTransaction] instead.
  PoolTotals poolTotals() {
    {
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
    }
  }

  /// Wrapped pairing secrets (§5) — ciphertext only at rest.
  ContributorSecretRepository get secrets => _secrets;

  // --- Host-side chunk manifest (`pool_chunks`) -----------------------------

  /// Records (or refreshes) one row of the chunk manifest. Idempotent on the
  /// primary key so a repair re-run after a crash converges instead of
  /// duplicating.
  void recordChunk({
    required String chunkId,
    required int bytes,
    required String contentSha256,
    required String cipherSha256,
    String? fileId,
    int seq = 0,
    int replication = 2,
  }) {
    _db.raw.execute(
      '''
      INSERT INTO pool_chunks
        (chunk_id, file_id, seq, bytes, content_sha256, cipher_sha256,
         replication, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(chunk_id) DO UPDATE SET
        file_id = excluded.file_id,
        bytes = excluded.bytes,
        content_sha256 = excluded.content_sha256,
        cipher_sha256 = excluded.cipher_sha256,
        replication = excluded.replication
      ''',
      [
        chunkId,
        fileId,
        seq,
        bytes,
        contentSha256,
        cipherSha256,
        replication,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  /// The manifest row for [chunkId], if the host has written it before.
  PoolChunk? recordedChunk(String chunkId) {
    final rows = _db.raw.select(
      'SELECT * FROM pool_chunks WHERE chunk_id = ?',
      [chunkId],
    );
    return rows.isEmpty ? null : PoolChunk.fromRow(rows.first);
  }

  /// Every chunk of [fileId] in order — the reassembly path.
  ///
  /// Detached rows are excluded: they belong to a slot the file no longer
  /// has, and feeding them to a reader would corrupt the output.
  List<PoolChunk> chunksForFile(String fileId) {
    final rows = _db.raw.select(
      'SELECT * FROM pool_chunks WHERE file_id = ? AND detached_at IS NULL '
      'ORDER BY seq ASC',
      [fileId],
    );
    return rows.map(PoolChunk.fromRow).toList();
  }

  /// Chunks whose bytes may still be on a device but that no file owns any
  /// more — the delete-retry queue.
  List<String> detachedChunkIds({int limit = 32}) {
    final rows = _db.raw.select(
      'SELECT chunk_id FROM pool_chunks WHERE detached_at IS NOT NULL '
      'ORDER BY detached_at ASC LIMIT ?',
      [limit],
    );
    return rows.map((r) => r['chunk_id'] as String).toList();
  }

  /// Records what [fileId] is supposed to consist of. Written BEFORE the
  /// first chunk so an interrupted protect still leaves an honest
  /// "expected N, have M" record instead of a silently short file.
  void upsertFileMeta({
    required String fileId,
    required int chunkCount,
    required int byteLength,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      '''
      INSERT INTO pool_files
        (file_id, chunk_count, byte_length, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(file_id) DO UPDATE SET
        chunk_count = excluded.chunk_count,
        byte_length = excluded.byte_length,
        updated_at = excluded.updated_at
      ''',
      [fileId, chunkCount, byteLength, now, now],
    );
  }

  /// What [fileId] should consist of, or null when it is not protected.
  PoolFileMeta? fileMeta(String fileId) {
    final rows = _db.raw.select(
      'SELECT * FROM pool_files WHERE file_id = ?',
      [fileId],
    );
    return rows.isEmpty ? null : PoolFileMeta.fromRow(rows.first);
  }

  void deleteFileMeta(String fileId) {
    _db.raw.execute('DELETE FROM pool_files WHERE file_id = ?', [fileId]);
  }

  /// Every file the host has protected in the pool, oldest first.
  List<PoolFileMeta> listFiles() {
    final rows = _db.raw.select(
      'SELECT * FROM pool_files ORDER BY created_at ASC',
    );
    return rows.map(PoolFileMeta.fromRow).toList();
  }

  /// Every file the host has protected in the pool, in first-write order.
  List<String> protectedFileIds() =>
      listFiles().map((f) => f.fileId).toList();

  /// Unlinks a chunk from its file without touching the bytes on disk.
  ///
  /// Used when a file shrinks: the tail slots are no longer part of any file,
  /// so they must stop being reassembled — but the devices holding them still
  /// have to be asked to delete the bytes (see `PoolCoordinator.deleteChunk`).
  void detachChunk(String chunkId) {
    _db.raw.execute(
      'UPDATE pool_chunks SET file_id = NULL, detached_at = ? '
      'WHERE chunk_id = ? AND detached_at IS NULL',
      [DateTime.now().millisecondsSinceEpoch, chunkId],
    );
  }

  /// Drops one manifest row once no copy of it remains anywhere.
  void deleteChunkManifest(String chunkId) {
    _db.raw.execute('DELETE FROM pool_chunks WHERE chunk_id = ?', [chunkId]);
  }

  /// Removes manifest rows (used when the owning file is purged).
  void deleteChunksForFile(String fileId) {
    _db.raw.execute('DELETE FROM pool_chunks WHERE file_id = ?', [fileId]);
  }

  /// Number of chunk copies currently believed stored — feeds the pool
  /// headline's honesty line.
  int countReplicas() {
    final rows = _db.raw.select(
      "SELECT COUNT(*) AS n FROM chunk_replicas WHERE state = 'STORED'",
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Random `STORED` copies for spot-audits (§6 control 1 / Storj audits).
  List<ChunkReplica> sampleReplicas(int limit, Random random) {
    if (limit <= 0) return const [];
    final rows = _db.raw.select(
      "SELECT * FROM chunk_replicas WHERE state = 'STORED'",
    );
    if (rows.length <= limit) return rows.map(_replicaFromRow).toList();
    final indices = <int>{};
    while (indices.length < limit) {
      indices.add(random.nextInt(rows.length));
    }
    return indices.map((i) => _replicaFromRow(rows[i])).toList();
  }

  ChunkReplica _replicaFromRow(Row row) => ChunkReplica(
        chunkId: row['chunk_id'] as String,
        contributorId: row['contributor_id'] as String,
        state: ReplicaState.fromDb(row['state'] as String),
        sha256: row['sha256'] as String,
        bytes: row['bytes'] as int,
        updatedAt: row['updated_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      );

  /// Slides a contributor's token expiry forward — called on every accepted
  /// heartbeat so an active contributor never expires (§6 control 2: an idle
  /// one does, and must re-register).
  bool extendToken(String id, DateTime expiresAt) {
    _db.raw.execute(
      'UPDATE contributors SET token_expires_at = ? WHERE id = ? '
      "AND status <> 'REVOKED'",
      [expiresAt.millisecondsSinceEpoch, id],
    );
    return _db.raw.updatedRows == 1;
  }

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
  /// Releases one confirmed-deleted copy and returns the quota it held.
  bool releaseReplica(String chunkId, String contributorId) =>
      _replicas.releaseReplica(chunkId, contributorId);

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
