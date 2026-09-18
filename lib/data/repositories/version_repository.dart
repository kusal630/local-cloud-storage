import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../database/vault_database.dart';
import '../models/file_version.dart';

/// Stores archived content revisions of files.
class VersionRepository {
  VersionRepository(this._db);

  final VaultDatabase _db;

  FileVersion _fromRow(Row row) => FileVersion(
        id: row['id'] as String,
        fileId: row['file_id'] as String,
        version: row['version'] as int,
        blobId: row['blob_id'] as String?,
        size: row['size'] as int,
        checksum: row['checksum'] as String?,
        mime: row['mime'] as String?,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      );

  List<FileVersion> listForFile(String fileId) {
    final rows = _db.raw.select(
      'SELECT * FROM file_versions WHERE file_id = ? ORDER BY version DESC',
      [fileId],
    );
    return rows.map(_fromRow).toList();
  }

  FileVersion? getVersion(String fileId, int version) {
    final rows = _db.raw.select(
      'SELECT * FROM file_versions WHERE file_id = ? AND version = ?',
      [fileId, version],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Archives the current content pointer of a file as a new version.
  FileVersion snapshot({
    required String fileId,
    String? blobId,
    required int size,
    String? checksum,
    String? mime,
  }) {
    final rows = _db.raw.select(
      'SELECT MAX(version) AS v FROM file_versions WHERE file_id = ?',
      [fileId],
    );
    final next = ((rows.first['v'] as int?) ?? 0) + 1;
    final id = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      '''
      INSERT INTO file_versions
        (id, file_id, version, blob_id, size, checksum, mime, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [id, fileId, next, blobId, size, checksum, mime, now],
    );
    // Keep history bounded: newest 20 per file.
    _db.raw.execute(
      '''
      DELETE FROM file_versions
      WHERE file_id = ?
        AND id NOT IN (
          SELECT id FROM file_versions
          WHERE file_id = ? ORDER BY version DESC LIMIT 20
        )
      ''',
      [fileId, fileId],
    );
    return getVersion(fileId, next)!;
  }

  void deleteForFile(String fileId) {
    _db.raw.execute('DELETE FROM file_versions WHERE file_id = ?', [fileId]);
  }
}
