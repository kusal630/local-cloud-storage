import '../database/vault_database.dart';

/// Replay-protection nonce cache for pool `register`/`heartbeat`/`write`
/// requests (RESEARCH/CONSULT.md §1): 300 s TTL, ±120 s acceptance window,
/// ~1000-row LRU cap. The pinned-TLS channel already prevents off-path
/// replay — this only stops captured-request reuse.
class NonceRepository {
  NonceRepository(this._db);

  final VaultDatabase _db;

  /// How long a seen nonce is remembered (§1: 300 s).
  static const Duration defaultTtl = Duration(seconds: 300);

  /// Maximum cached rows; the oldest timestamps are evicted first (§1).
  static const int maxCached = 1000;

  /// Clock-skew acceptance window for a request's timestamp (§1: ±120 s).
  static const Duration maxSkew = Duration(seconds: 120);

  /// Records a nonce and returns true, or false when it was already seen
  /// (a replay — reject the request).
  bool insert(String nonce, {DateTime? at}) {
    final ts = (at ?? DateTime.now()).millisecondsSinceEpoch;
    _db.raw.execute(
      'INSERT INTO nonces (nonce, ts) VALUES (?, ?) '
      'ON CONFLICT(nonce) DO NOTHING',
      [nonce, ts],
    );
    return _db.raw.updatedRows == 1;
  }

  /// Whether a request timestamp [at] is fresh enough to accept (§1 window).
  static bool withinWindow(
    DateTime at, {
    Duration skew = maxSkew,
    DateTime? now,
  }) {
    final delta = (now ?? DateTime.now()).difference(at).abs();
    return delta <= skew;
  }

  /// Deletes nonces older than [ttl] and trims the cache to [rowCap]
  /// (LRU by timestamp). Returns the number of rows removed.
  int sweep({
    Duration ttl = defaultTtl,
    int rowCap = maxCached,
    DateTime? now,
  }) {
    final cutoff =
        (now ?? DateTime.now()).millisecondsSinceEpoch - ttl.inMilliseconds;
    return _db.withTransaction(() {
      _db.raw.execute('DELETE FROM nonces WHERE ts < ?', [cutoff]);
      var deleted = _db.raw.updatedRows;
      _db.raw.execute(
        'DELETE FROM nonces WHERE nonce IN '
        '(SELECT nonce FROM nonces ORDER BY ts DESC LIMIT -1 OFFSET ?)',
        [rowCap],
      );
      return deleted + _db.raw.updatedRows;
    });
  }
}
