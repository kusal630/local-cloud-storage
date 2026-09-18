import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../../core/errors/app_exceptions.dart';
import '../database/vault_database.dart';
import '../models/file_comment.dart';

/// Comments attached to files/folders.
class CommentRepository {
  CommentRepository(this._db);

  final VaultDatabase _db;

  FileComment _fromRow(Row row) => FileComment(
        id: row['id'] as String,
        fileId: row['file_id'] as String,
        deviceId: row['device_id'] as String?,
        author: (row['author'] as String?) ?? 'owner',
        body: row['body'] as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      );

  List<FileComment> listForFile(String fileId, {int limit = 100}) {
    final rows = _db.raw.select(
      'SELECT * FROM comments WHERE file_id = ? ORDER BY created_at DESC LIMIT ?',
      [fileId, limit.clamp(1, 200)],
    );
    return rows.map(_fromRow).toList();
  }

  FileComment add({
    required String fileId,
    String? deviceId,
    required String author,
    required String body,
  }) {
    final text = body.trim();
    if (text.isEmpty || text.length > 2000) {
      throw const ValidationException(
          'Comment must be 1..2000 characters.');
    }
    final id = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      '''
      INSERT INTO comments (id, file_id, device_id, author, body, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [id, fileId, deviceId, author, text, now],
    );
    final rows = _db.raw.select('SELECT * FROM comments WHERE id = ?', [id]);
    return _fromRow(rows.first);
  }

  void delete(String id) {
    _db.raw.execute('DELETE FROM comments WHERE id = ?', [id]);
  }

  void deleteForFile(String fileId) {
    _db.raw.execute('DELETE FROM comments WHERE file_id = ?', [fileId]);
  }
}
