import 'package:sqlite3/sqlite3.dart';

import '../../core/errors/app_exceptions.dart';
import '../database/vault_database.dart';

/// A stored blob that can be referenced by one or more file rows.
class BlobRecord {
  const BlobRecord({
    required this.id,
    required this.size,
    required this.checksum,
    required this.relPath,
    this.mime,
  });

  final String id;
  final int size;
  final String checksum;
  final String relPath;
  final String? mime;
}

/// Manages blob metadata. Actual bytes live under `<vault>/blobs/<xx>/<yy>/<id>`.
class BlobRepository {
  BlobRepository(this._db);

  final VaultDatabase _db;

  BlobRecord create({
    required String id,
    required int size,
    required String checksum,
    required String relPath,
    String? mime,
  }) {
    _db.raw.execute(
      '''
      INSERT INTO blobs (id, size, checksum, mime, rel_path, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [id, size, checksum, mime, relPath, DateTime.now().millisecondsSinceEpoch],
    );
    return getById(id);
  }

  BlobRecord getById(String id) {
    final rows = _db.raw.select('SELECT * FROM blobs WHERE id = ?', [id]);
    if (rows.isEmpty) throw const NotFoundException('Blob not found.');
    return _fromRow(rows.first);
  }

  /// Finds an existing blob with the same checksum + size so uploads can be
  /// de-duplicated. Returns `null` when none exists.
  BlobRecord? findByChecksumAndSize(String checksum, int size) {
    final rows = _db.raw.select(
      'SELECT * FROM blobs WHERE checksum = ? AND size = ? LIMIT 1',
      [checksum, size],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  int referenceCount(String blobId) {
    final rows = _db.raw.select(
      'SELECT COUNT(*) AS c FROM files WHERE blob_id = ?',
      [blobId],
    );
    return rows.first['c'] as int;
  }

  /// Deletes the blob row only when no file row references it.
  bool deleteIfUnused(String blobId) {
    if (referenceCount(blobId) > 0) return false;
    _db.raw.execute('DELETE FROM blobs WHERE id = ?', [blobId]);
    return true;
  }

  static BlobRecord _fromRow(Row row) => BlobRecord(
        id: row['id'] as String,
        size: row['size'] as int,
        checksum: row['checksum'] as String,
        relPath: row['rel_path'] as String,
        mime: row['mime'] as String?,
      );
}