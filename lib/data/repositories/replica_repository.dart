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

  /// Chunk ids holding fewer than [targetReplicas] `STORED` copies — the
  /// re-replication work queue.
  List<String> underReplicated({int targetReplicas = 2}) {
    final rows = _db.raw.select(
      '''
      SELECT chunk_id FROM chunk_replicas
      WHERE state IN ('STORED','DEGRADED')
      GROUP BY chunk_id
      HAVING SUM(CASE WHEN state = 'STORED' THEN 1 ELSE 0 END) < ?
      ''',
      [targetReplicas],
    );
    return rows.map((r) => r['chunk_id'] as String).toList();
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
