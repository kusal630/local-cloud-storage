import 'package:sqlite3/sqlite3.dart';

import '../../core/errors/app_exceptions.dart';
import '../database/vault_database.dart';
import '../models/contributor.dart';
import 'replica_repository.dart';

/// Two-phase quota reservations (RESEARCH/CONSULT.md §2).
///
/// Effective usage is ALWAYS derived — open `RESERVED` rows plus `STORED`
/// replicas — never accumulated, so a crash can never leak quota.
class ReservationRepository {
  ReservationRepository(this._db) : _replicas = ReplicaRepository(_db);

  final VaultDatabase _db;
  final ReplicaRepository _replicas;

  /// Reservation TTL: longer than the slowest realistic chunk upload.
  static const Duration defaultTtl = Duration(seconds: 600);

  Reservation _fromRow(Row row) => Reservation(
        idempotencyKey: row['idempotency_key'] as String,
        chunkId: row['chunk_id'] as String,
        contributorId: row['contributor_id'] as String,
        bytes: row['bytes'] as int,
        state: ReservationState.fromDb(row['state'] as String),
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(row['expires_at'] as int),
      );

  /// Returns the reservation for the composite idempotency key, if any.
  Reservation? getReservation(String idempotencyKey, String contributorId) {
    final rows = _db.raw.select(
      'SELECT * FROM reservations '
      'WHERE idempotency_key = ? AND contributor_id = ?',
      [idempotencyKey, contributorId],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Lists reservations, optionally filtered by contributor and/or state.
  List<Reservation> list({
    String? contributorId,
    ReservationState? state,
  }) {
    final where = <String>[];
    final args = <Object?>[];
    if (contributorId != null) {
      where.add('contributor_id = ?');
      args.add(contributorId);
    }
    if (state != null) {
      where.add('state = ?');
      args.add(state.dbValue);
    }
    final sql = 'SELECT * FROM reservations'
        '${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}'
        ' ORDER BY created_at ASC';
    return _db.raw.select(sql, args).map(_fromRow).toList();
  }

  /// Reserves [bytes] against a contributor's quota inside one
  /// `BEGIN IMMEDIATE` transaction using a single conditional
  /// `INSERT … SELECT … WHERE` — the oversubscription invariant, with no
  /// read-modify-write: two racers for the last bytes admit exactly one.
  ///
  /// Returns the reservation (the existing row on an idempotent retry) or
  /// `null` when the contributor has no room left. Throws when
  /// [contributorId] is unknown or not `ALIVE`.
  Reservation? reserveChunk(
    String idempotencyKey,
    String chunkId,
    String contributorId,
    int bytes, {
    Duration ttl = defaultTtl,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db.withTransaction(() {
      _db.raw.execute(
        '''
        INSERT OR IGNORE INTO reservations
          (idempotency_key, chunk_id, contributor_id, bytes, state,
           created_at, expires_at)
        SELECT ?, ?, ?, ?, 'RESERVED', ?, ?
        WHERE
            (SELECT COALESCE(SUM(bytes),0) FROM reservations
              WHERE contributor_id = ? AND state = 'RESERVED'
                AND expires_at > ?)
          + (SELECT COALESCE(SUM(bytes),0) FROM chunk_replicas
              WHERE contributor_id = ? AND state = 'STORED')
          + ? <= (SELECT quota_bytes FROM contributors
                   WHERE id = ? AND status = 'ALIVE')
        ''',
        [
          idempotencyKey,
          chunkId,
          contributorId,
          bytes,
          now,
          now + ttl.inMilliseconds,
          contributorId,
          now,
          contributorId,
          bytes,
          contributorId,
        ],
      );
      if (_db.raw.updatedRows == 1) {
        return getReservation(idempotencyKey, contributorId);
      }
      // No row inserted: an idempotent retry or no room left.
      final existing = getReservation(idempotencyKey, contributorId);
      if (existing != null) return existing;
      return _noRoom(contributorId);
    });
  }

  /// Distinguishes "quota full" (a normal outcome: null) from a contributor
  /// that cannot take writes at all (a caller error: throws).
  Reservation? _noRoom(String contributorId) {
    final rows = _db.raw.select(
      'SELECT status FROM contributors WHERE id = ?',
      [contributorId],
    );
    if (rows.isEmpty) throw const NotFoundException('Contributor not found.');
    final status = rows.first['status'] as String;
    if (status != 'ALIVE') {
      throw ConflictException('Contributor is $status and cannot accept writes.');
    }
    return null;
  }

  /// Marks the reservation `COMMITTED`, records the `STORED` replica and adds
  /// its bytes to `used_bytes` — all in one transaction. Returns false when
  /// no open reservation matches (committed, rolled back or swept already).
  bool commitReservation(
    String idempotencyKey,
    String contributorId,
    String sha256,
  ) {
    return _db.withTransaction(() {
      final rows = _db.raw.select(
        "SELECT * FROM reservations WHERE idempotency_key = ? "
        "AND contributor_id = ? AND state = 'RESERVED'",
        [idempotencyKey, contributorId],
      );
      if (rows.isEmpty) return false;
      final reservation = _fromRow(rows.first);
      _db.raw.execute(
        "UPDATE reservations SET state = 'COMMITTED' "
        "WHERE idempotency_key = ? AND contributor_id = ? "
        "AND state = 'RESERVED'",
        [idempotencyKey, contributorId],
      );
      _replicas.upsert(
        reservation.chunkId,
        contributorId,
        ReplicaState.stored,
        sha256,
        reservation.bytes,
      );
      _db.raw.execute(
        'UPDATE contributors SET used_bytes = used_bytes + ? WHERE id = ?',
        [reservation.bytes, contributorId],
      );
      return true;
    });
  }

  /// Releases a quota hold on write failure/timeout. Returns false when the
  /// reservation was not open.
  bool rollbackReservation(String idempotencyKey, String contributorId) {
    _db.raw.execute(
      "UPDATE reservations SET state = 'ROLLED_BACK' "
      'WHERE idempotency_key = ? AND contributor_id = ? '
      "AND state = 'RESERVED'",
      [idempotencyKey, contributorId],
    );
    return _db.raw.updatedRows == 1;
  }

  /// Deletes `RESERVED` rows whose TTL lapsed (run every 30 s) so a crashed
  /// client never leaks quota for longer than its TTL. Returns rows freed.
  int sweepExpiredReservations({DateTime? now}) {
    _db.raw.execute(
      "DELETE FROM reservations WHERE state = 'RESERVED' AND expires_at < ?",
      [(now ?? DateTime.now()).millisecondsSinceEpoch],
    );
    return _db.raw.updatedRows;
  }
}
