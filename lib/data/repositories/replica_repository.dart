import 'package:sqlite3/sqlite3.dart';

import '../database/vault_database.dart';
import '../models/contributor.dart';

/// The authoritative recorded replica set for pooled chunks
/// (RESEARCH/CONSULT.md §3). Placement is both derivable (weighted HRW) and
/// recorded (this table): the table answers reads, HRW answers re-placement.
class ReplicaRepository {
  ReplicaRepository(this._db);

  final VaultDatabase _db;

  /// Records (or updates) one chunk copy on one contributor. Idempotent on
  /// the `(chunk_id, contributor_id)` primary key, so a re-replication job
  /// can rerun safely after a crash.
  void upsert(
    String chunkId,
    String contributorId,
    ReplicaState state,
    String sha256,
    int bytes, {
    DateTime? now,
  }) {
    final ts = (now ?? DateTime.now()).millisecondsSinceEpoch;
    _db.raw.execute(
      '''
      INSERT INTO chunk_replicas
        (chunk_id, contributor_id, state, sha256, bytes, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(chunk_id, contributor_id) DO UPDATE SET
        state = excluded.state,
        sha256 = excluded.sha256,
        bytes = excluded.bytes,
        updated_at = excluded.updated_at
      ''',
      [chunkId, contributorId, state.dbValue, sha256, bytes, ts],
    );
  }

  /// Returns the copies of [chunkId] (primary read path for locations).
  List<ChunkReplica> listForChunk(String chunkId) {
    final rows = _db.raw.select(
      'SELECT * FROM chunk_replicas WHERE chunk_id = ? ORDER BY contributor_id',
      [chunkId],
    );
    return rows.map(_fromRow).toList();
  }

  /// Returns every chunk copy believed to be stored on [contributorId].
  List<ChunkReplica> listForContributor(String contributorId) {
    final rows = _db.raw.select(
      'SELECT * FROM chunk_replicas WHERE contributor_id = ? ORDER BY chunk_id',
      [contributorId],
    );
    return rows.map(_fromRow).toList();
  }

  /// Chunk ids holding fewer than [targetReplicas] **usable** copies — the
  /// re-replication work queue.
  ///
  /// "Usable" is the whole point (D2): a copy on a `REVOKED`, `LEFT` or `DEAD`
  /// device still says `STORED`, but nobody can read it. Counting it would
  /// empty the queue exactly when repair matters most — right after a revoke,
  /// where the bytes were wiped and the surviving copy needs a sibling. A
  /// holder missing entirely (row gone) counts as unusable too.
  List<String> underReplicated({int targetReplicas = 2}) {
    final rows = _db.raw.select(
      '''
      SELECT cr.chunk_id FROM chunk_replicas cr
      LEFT JOIN contributors c ON c.id = cr.contributor_id
      WHERE cr.state IN ('STORED','DEGRADED')
      GROUP BY cr.chunk_id
      HAVING SUM(CASE WHEN cr.state = 'STORED'
                       AND c.status IN ('ALIVE','SUSPECT')
                      THEN 1 ELSE 0 END) < ?
      ''',
      [targetReplicas],
    );
    return rows.map((r) => r['chunk_id'] as String).toList();
  }

  /// Deletes a copy for real: the node confirmed the bytes are gone (or the
  /// holder left the pool), so the ledger drops the row and gives the quota
  /// back.
  ///
  /// Replica row + `used_bytes` move together in one transaction, and only a
  /// row that was actually `STORED` returns quota — releasing an already
  /// released copy cannot shrink usage twice.
  bool releaseReplica(String chunkId, String contributorId) {
    return _db.withTransaction(() {
      final rows = _db.raw.select(
        'SELECT state, bytes FROM chunk_replicas '
        'WHERE chunk_id = ? AND contributor_id = ?',
        [chunkId, contributorId],
      );
      if (rows.isEmpty) return false;
      final state = rows.first['state'] as String;
      if (state == ReplicaState.deleted.dbValue) return false;
      final bytes = rows.first['bytes'] as int;
      _db.raw.execute(
        "UPDATE chunk_replicas SET state = ?, updated_at = ? "
        'WHERE chunk_id = ? AND contributor_id = ?',
        [
          ReplicaState.deleted.dbValue,
          DateTime.now().millisecondsSinceEpoch,
          chunkId,
          contributorId,
        ],
      );
      // Any copy that was not already released was paid for when it was
      // committed — including one that has since been quarantined `CORRUPT`,
      // whose bytes are still sitting on that device until it is deleted.
      _db.raw.execute(
        'UPDATE contributors SET used_bytes = MAX(0, used_bytes - ?) '
        'WHERE id = ?',
        [bytes, contributorId],
      );
      return true;
    });
  }

  ChunkReplica _fromRow(Row row) => ChunkReplica(
        chunkId: row['chunk_id'] as String,
        contributorId: row['contributor_id'] as String,
        state: ReplicaState.fromDb(row['state'] as String),
        sha256: row['sha256'] as String,
        bytes: row['bytes'] as int,
        updatedAt: row['updated_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      );
}
