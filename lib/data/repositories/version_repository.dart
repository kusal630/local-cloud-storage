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
    // Staggered pruning (Syncthing/Nextcloud-style): many recent versions,
    // fewer old ones — newest 3 always, then daily for 30 days, then weekly.
    final all = listForFile(fileId);
    final keep = <String>{};
    final days = <String>{};
    final weeks = <String>{};
    final nowDt = DateTime.now();
    var kept = 0;
    for (var i = 0; i < all.length && kept < 50; i++) {
      final v = all[i];
      final age = nowDt.difference(v.createdAt);
      if (i < 3 || age < const Duration(hours: 24)) {
        keep.add(v.id);
        kept++;
      } else if (age < const Duration(days: 30)) {
        final day =
            '${v.createdAt.year}-${v.createdAt.month}-${v.createdAt.day}';
        if (days.add(day)) {
          keep.add(v.id);
          kept++;
        }
      } else {
        // ISO week bucket.
        final weekStart = v.createdAt
            .subtract(Duration(days: v.createdAt.weekday - 1));
        final week =
            '${weekStart.year}-${weekStart.month}-${weekStart.day}';
        if (weeks.add(week)) {
          keep.add(v.id);
          kept++;
        }
      }
    }
    if (keep.length < all.length) {
      for (final v in all) {
        if (!keep.contains(v.id)) {
          _db.raw.execute(
              'DELETE FROM file_versions WHERE id = ?', [v.id]);
        }
      }
    }
    return getVersion(fileId, next)!;
  }

  void deleteForFile(String fileId) {
    _db.raw.execute('DELETE FROM file_versions WHERE file_id = ?', [fileId]);
  }
}
