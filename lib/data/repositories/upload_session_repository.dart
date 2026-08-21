import 'package:sqlite3/sqlite3.dart';

import '../../core/errors/app_exceptions.dart';
import '../database/vault_database.dart';
import '../models/upload_session.dart';

/// Manages in-flight chunked uploads persisted in the database so they can be
/// resumed after a disconnect.
class UploadSessionRepository {
  UploadSessionRepository(this._db);

  final VaultDatabase _db;

  static const String statusActive = 'active';
  static const String statusCompleted = 'completed';
  static const String statusAborted = 'aborted';

  UploadSession _fromRow(Row row) => UploadSession(
        id: row['id'] as String,
        parentId: row['parent_id'] as String,
        name: row['name'] as String,
        size: row['size'] as int,
        expectedChecksum: row['expected_checksum'] as String,
        received: row['received'] as int,
        status: row['status'] as String,
        mime: row['mime'] as String?,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      );

  UploadSession create({
    required String id,
    required String parentId,
    required String name,
    required int size,
    required String expectedChecksum,
    required String tmpPath,
    String? mime,
    String? deviceId,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      '''
      INSERT INTO upload_sessions
        (id, parent_id, name, size, expected_checksum, tmp_path,
         received, chunk_count, mime, device_id, status, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?, ?, ?)
      ''',
      [id, parentId, name, size, expectedChecksum, tmpPath, mime, deviceId, statusActive, now, now],
    );
    return getById(id);
  }

  UploadSession getById(String id) {
    final rows = _db.raw.select(
      'SELECT * FROM upload_sessions WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) throw const NotFoundException('Upload session not found.');
    return _fromRow(rows.first);
  }

  UploadSession appendChunk(String id, int received) {
    _db.raw.execute(
      '''
      UPDATE upload_sessions SET
        received = ?,
        chunk_count = chunk_count + 1,
        updated_at = ?
      WHERE id = ?
      ''',
      [received, DateTime.now().millisecondsSinceEpoch, id],
    );
    return getById(id);
  }

  void setStatus(String id, String status) {
    _db.raw.execute(
      '''
      UPDATE upload_sessions SET status = ?, updated_at = ? WHERE id = ?
      ''',
      [status, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  List<UploadSession> listActive() {
    final rows = _db.raw.select(
      '''
      SELECT * FROM upload_sessions
      WHERE status = ?
      ORDER BY created_at DESC
      ''',
      [statusActive],
    );
    return rows.map(_fromRow).toList();
  }

  void deleteById(String id) {
    _db.raw.execute('DELETE FROM upload_sessions WHERE id = ?', [id]);
  }
}